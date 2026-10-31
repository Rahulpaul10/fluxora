// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GovernorVotesQuorumFraction} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {FluxoraGovernance} from "../src/FluxoraGovernance.sol";
import {FluxoraTimelock} from "../src/FluxoraTimelock.sol";
import {FluxoraPayments} from "../src/FluxoraPayments.sol";
import {MockBlockClockVotes} from "./helpers/MockERC20.sol";
import {FluxoraGovernanceTestBase} from "./FluxoraGovernance.Base.t.sol";

contract FluxoraGovernanceTest is FluxoraGovernanceTestBase {
    // ------------------------------------------------------------ configuration
    function test_ConfigurationAndTimestampClock() public view {
        assertEq(governor.name(), "FluxoraGovernance");
        assertEq(governor.votingDelay(), VOTING_DELAY);
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), THRESHOLD);
        assertEq(governor.quorumNumerator(), QUORUM_PCT);
        assertEq(governor.quorumDenominator(), 100);
        assertEq(address(governor.token()), address(flux));
        assertEq(governor.timelock(), address(timelock));
        assertEq(governor.clock(), uint48(block.timestamp));
        assertEq(governor.CLOCK_MODE(), "mode=timestamp");
        assertEq(flux.CLOCK_MODE(), "mode=timestamp");
    }

    function test_QuorumIsFourPercentOfPastSupply() public view {
        assertEq(governor.quorum(block.timestamp - 1), 40_000_000e18);
    }

    function test_RevertConstructorInvalidTimelock() public {
        vm.expectRevert(abi.encodeWithSelector(FluxoraGovernance.InvalidTimelock.selector, address(0)));
        new FluxoraGovernance(IVotes(address(flux)), TimelockController(payable(address(0))), 1, 1, 0, 4);
        vm.expectRevert(abi.encodeWithSelector(FluxoraGovernance.InvalidTimelock.selector, stranger));
        new FluxoraGovernance(IVotes(address(flux)), TimelockController(payable(stranger)), 1, 1, 0, 4);
    }

    function test_RevertConstructorTokenWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(FluxoraGovernance.InvalidVotingToken.selector, stranger));
        new FluxoraGovernance(IVotes(stranger), timelock, 1, 1, 0, 4);
        vm.expectRevert(abi.encodeWithSelector(FluxoraGovernance.InvalidVotingToken.selector, address(0)));
        new FluxoraGovernance(IVotes(address(0)), timelock, 1, 1, 0, 4);
    }

    function test_RevertConstructorBlockNumberClockToken() public {
        MockBlockClockVotes bad = new MockBlockClockVotes();
        string memory mode = bad.CLOCK_MODE();
        assertEq(mode, "mode=blocknumber&from=default");
        vm.expectRevert(
            abi.encodeWithSelector(FluxoraGovernance.UnsupportedClockMode.selector, address(bad), mode)
        );
        new FluxoraGovernance(IVotes(address(bad)), timelock, 1, 1, 0, 4);
    }

    function test_RevertConstructorBadQuorumAndPeriod() public {
        vm.expectRevert(
            abi.encodeWithSelector(GovernorVotesQuorumFraction.GovernorInvalidQuorumFraction.selector, 101, 100)
        );
        new FluxoraGovernance(IVotes(address(flux)), timelock, 1, 1, 0, 101);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidVotingPeriod.selector, 0));
        new FluxoraGovernance(IVotes(address(flux)), timelock, 1, 0, 0, 4);
    }

    // ------------------------------------------------------------ full lifecycle
    function test_FullLifecycleChangesFeeThroughTimelock() public {
        string memory desc = "Set payments fee to 50 bps";
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh) = _feeProposal(50, desc);
        uint256 proposalStart = block.timestamp;

        vm.prank(whale);
        uint256 id = governor.propose(t, v, c, desc);
        assertEq(id, governor.hashProposal(t, v, c, dh));
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));
        assertEq(governor.proposalSnapshot(id), proposalStart + VOTING_DELAY);
        assertEq(governor.proposalDeadline(id), proposalStart + VOTING_DELAY + VOTING_PERIOD);
        assertEq(governor.proposalProposer(id), whale);
        assertTrue(governor.proposalNeedsQueuing(id));

        // still Pending exactly at the snapshot, Active one second later
        vm.warp(governor.proposalSnapshot(id));
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));
        _toActive(id);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active));

        vm.expectEmit(true, false, false, true, address(governor));
        emit IGovernor.VoteCast(whale, id, 1, 900_000_000e18, "");
        _vote(id, whale, 1);
        assertTrue(governor.hasVoted(id, whale));
        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(id);
        assertEq(forVotes, 900_000_000e18);
        assertEq(against, 0);
        assertEq(abstain, 0);

        // Active through the deadline second, over one second later
        vm.warp(governor.proposalDeadline(id));
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active));
        _toEnded(id);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));

        uint256 eta = block.timestamp + MIN_DELAY;
        vm.expectEmit(false, false, false, true, address(governor));
        emit IGovernor.ProposalQueued(id, eta);
        governor.queue(t, v, c, dh);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Queued));
        assertEq(governor.proposalEta(id), eta);
        assertEq(payments.feeBps(), 0); // nothing applied yet

        // too early: timelock refuses
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        governor.execute(t, v, c, dh);

        vm.warp(eta);
        vm.expectEmit(false, false, false, true, address(governor));
        emit IGovernor.ProposalExecuted(id);
        vm.prank(stranger); // execution is open to anyone
        governor.execute(t, v, c, dh);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Executed));
        assertEq(payments.feeBps(), 50);
        assertEq(payments.feeRecipient(), collector);

        vm.expectPartialRevert(IGovernor.GovernorUnexpectedProposalState.selector);
        governor.execute(t, v, c, dh);
    }

    function test_MultiActionProposalExecutesAtomically() public {
        address[] memory t = new address[](2);
        uint256[] memory v = new uint256[](2);
        bytes[] memory c = new bytes[](2);
        t[0] = address(payments);
        t[1] = address(payments);
        c[0] = abi.encodeCall(FluxoraPayments.setFeeRecipient, (stranger));
        c[1] = abi.encodeCall(FluxoraPayments.setFeeBps, (100));
        string memory desc = "recipient + fee";
        vm.prank(whale);
        uint256 id = governor.propose(t, v, c, desc);
        _toActive(id);
        _vote(id, whale, 1);
        _toEnded(id);
        governor.queue(t, v, c, keccak256(bytes(desc)));
        vm.warp(governor.proposalEta(id));
        governor.execute(t, v, c, keccak256(bytes(desc)));
        assertEq(payments.feeRecipient(), stranger);
        assertEq(payments.feeBps(), 100);
    }

    function test_FailingActionRevertsExecutionAndStaysQueued() public {
        (uint256 id,) = _proposeVoteQueueFee(101, "invalid fee"); // > MAX_FEE_BPS
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh) = _feeProposal(101, "invalid fee");
        vm.warp(governor.proposalEta(id));
        vm.expectRevert(abi.encodeWithSelector(FluxoraPayments.InvalidFeeBps.selector, 101));
        governor.execute(t, v, c, dh);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Queued));
        assertEq(payments.feeBps(), 0);
    }

    // ------------------------------------------------------------ threshold
    function test_RevertProposeBelowThreshold() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c,) = _feeProposal(1, "x");
        vm.prank(small);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector, small, THRESHOLD - 1e18, THRESHOLD
            )
        );
        governor.propose(t, v, c, "x");
    }

    function test_ProposeAtExactlyThresholdSucceeds() public {
        vm.prank(treasury);
        flux.transfer(small, 1e18); // now exactly THRESHOLD
        vm.warp(block.timestamp + 1);
        (address[] memory t, uint256[] memory v, bytes[] memory c,) = _feeProposal(1, "x");
        vm.prank(small);
        uint256 id = governor.propose(t, v, c, "x");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));
    }

    function test_RevertProposeWithUndelegatedTokens() public {
        vm.prank(treasury);
        flux.transfer(stranger, 5_000_000e18); // never delegated
        vm.warp(block.timestamp + 1);
        (address[] memory t, uint256[] memory v, bytes[] memory c,) = _feeProposal(1, "x");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInsufficientProposerVotes.selector, stranger, 0, THRESHOLD));
        governor.propose(t, v, c, "x");
    }

    function test_RevertProposeSameTimestampAsDelegation() public {
        vm.prank(treasury);
        flux.transfer(stranger, 5_000_000e18);
        _selfDelegate(stranger);
        (address[] memory t, uint256[] memory v, bytes[] memory c,) = _feeProposal(1, "x");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInsufficientProposerVotes.selector, stranger, 0, THRESHOLD));
        governor.propose(t, v, c, "x");
    }

    function test_RevertProposeDuplicateAndInvalidLength() public {
        _proposeFee(1, "dup");
        (address[] memory t, uint256[] memory v, bytes[] memory c,) = _feeProposal(1, "dup");
        vm.prank(whale);
        vm.expectPartialRevert(IGovernor.GovernorUnexpectedProposalState.selector);
        governor.propose(t, v, c, "dup");
        bytes[] memory none = new bytes[](0);
        vm.prank(whale);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidProposalLength.selector, 1, 0, 1));
        governor.propose(t, v, none, "bad");
    }

    // ------------------------------------------------------------ voting + quorum
    function test_QuorumNotReachedMeansDefeated() public {
        uint256 id = _proposeFee(50, "low turnout");
        _toActive(id);
        _vote(id, voterA, 1); // 30M < 40M quorum
        _toEnded(id);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh) = _feeProposal(50, "low turnout");
        vm.expectPartialRevert(IGovernor.GovernorUnexpectedProposalState.selector);
        governor.queue(t, v, c, dh);
    }

    function test_AbstainCountsTowardsQuorum() public {
        uint256 id = _proposeFee(50, "abstain");
        _toActive(id);
        _vote(id, voterA, 1); // 30M for
        _vote(id, voterB, 2); // 20M abstain -> 50M participation >= 40M
        _toEnded(id);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_AgainstVotesDoNotCountTowardsQuorum() public {
        uint256 id = _proposeFee(50, "against");
        _toActive(id);
        _vote(id, voterA, 1); // 30M for
        _vote(id, voterB, 0); // 20M against: for(30) > against(20) but quorum counts only for+abstain
        _toEnded(id);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_MajorityAgainstDefeatsProposal() public {
        uint256 id = _proposeFee(50, "majority against");
        _toActive(id);
        _vote(id, whale, 0);
        _vote(id, voterA, 1);
        _toEnded(id);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_TiedVoteIsDefeated() public {
        // stranger holds exactly voterA's 30M and votes against: for == against, quorum met via abstain
        vm.prank(treasury);
        flux.transfer(stranger, 30_000_000e18);
        _selfDelegate(stranger);
        uint256 id = _proposeFee(50, "tie");
        _toActive(id);
        _vote(id, voterA, 1); // 30M for
        _vote(id, stranger, 0); // 30M against
        _vote(id, voterB, 2); // 20M abstain
        _toEnded(id);
        (uint256 against, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, against);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_RevertDoubleVote() public {
        uint256 id = _proposeFee(50, "double");
        _toActive(id);
        _vote(id, voterA, 1);
        vm.prank(voterA);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorAlreadyCastVote.selector, voterA));
        governor.castVote(id, 1);
    }

    function test_RevertVoteWhilePendingOrAfterEnd() public {
        uint256 id = _proposeFee(50, "timing");
        vm.prank(voterA);
        vm.expectPartialRevert(IGovernor.GovernorUnexpectedProposalState.selector);
        governor.castVote(id, 1);
        _toEnded(id);
        vm.prank(voterA);
        vm.expectPartialRevert(IGovernor.GovernorUnexpectedProposalState.selector);
        governor.castVote(id, 1);
    }

    function test_RevertVoteInvalidSupportValue() public {
        uint256 id = _proposeFee(50, "bad vote");
        _toActive(id);
        vm.prank(voterA);
        vm.expectRevert(IGovernor.GovernorInvalidVoteType.selector);
        governor.castVote(id, 3);
    }

    function test_VotingPowerFixedAtSnapshot() public {
        uint256 id = _proposeFee(50, "snapshot");
        // tokens acquired after proposal creation (before the snapshot second) give no weight at snapshot
        vm.prank(treasury);
        flux.transfer(stranger, 40_000_000e18);
        _selfDelegate(stranger);
        _toActive(id);
        _vote(id, stranger, 1);
        (, uint256 forVotes,) = governor.proposalVotes(id);
        // delegation happened at t0+0 < snapshot (t0+1d): that power IS counted
        assertEq(forVotes, 40_000_000e18);

        // tokens moved after snapshot do not change the weight of an existing vote or of a late voter
        vm.prank(treasury);
        flux.transfer(voterB, 5_000_000e18);
        _vote(id, voterB, 1);
        (, forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, 40_000_000e18 + 20_000_000e18);
    }

    function test_VoteCastWithReason() public {
        uint256 id = _proposeFee(50, "reason");
        _toActive(id);
        vm.expectEmit(true, false, false, true, address(governor));
        emit IGovernor.VoteCast(voterA, id, 1, 30_000_000e18, "because");
        vm.prank(voterA);
        governor.castVoteWithReason(id, 1, "because");
    }

    // ------------------------------------------------------------ cancel / queue guards
    function test_ProposerCancelsWhilePending() public {
        uint256 id = _proposeFee(50, "cancel me");
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh) = _feeProposal(50, "cancel me");
        vm.expectEmit(false, false, false, true, address(governor));
        emit IGovernor.ProposalCanceled(id);
        vm.prank(whale);
        governor.cancel(t, v, c, dh);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test_RevertCancelByNonProposerOrWhenActive() public {
        uint256 id = _proposeFee(50, "cancel guards");
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh) = _feeProposal(50, "cancel guards");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, id, stranger));
        governor.cancel(t, v, c, dh);
        _toActive(id);
        vm.prank(whale);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, id, whale));
        governor.cancel(t, v, c, dh);
    }

    function test_RevertExecuteBeforeQueue() public {
        string memory desc = "skip queue";
        uint256 id = _proposeFee(50, desc);
        _toActive(id);
        _vote(id, whale, 1);
        _toEnded(id);
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh) = _feeProposal(50, desc);
        // Succeeded but not queued -> execute must not go through
        vm.expectRevert();
        governor.execute(t, v, c, dh);
        assertEq(payments.feeBps(), 0);
    }

    function test_RevertQueueTwice() public {
        (uint256 id,) = _proposeVoteQueueFee(50, "queue twice");
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh) = _feeProposal(50, "queue twice");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Queued));
        vm.expectPartialRevert(IGovernor.GovernorUnexpectedProposalState.selector);
        governor.queue(t, v, c, dh);
    }

    function test_RevertStateOfUnknownProposal() public {
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, 123));
        governor.state(123);
    }

    // ------------------------------------------------------------ governance-only paths
    function test_GovernorCannotBypassTimelockAdmin() public {
        vm.prank(whale);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, whale, bytes32(0))
        );
        payments.setFeeBps(1);
        vm.prank(address(governor));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(governor), bytes32(0))
        );
        payments.setFeeBps(1);
    }

    function test_RevertUpdateTimelockDirectly() public {
        FluxoraTimelock other = _newTimelock();
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, address(this)));
        governor.updateTimelock(other);
    }

    function test_RevertUpdateTimelockInvalidTarget() public {
        vm.expectRevert(abi.encodeWithSelector(FluxoraGovernance.InvalidTimelock.selector, address(0)));
        governor.updateTimelock(TimelockController(payable(address(0))));
        vm.expectRevert(abi.encodeWithSelector(FluxoraGovernance.InvalidTimelock.selector, stranger));
        governor.updateTimelock(TimelockController(payable(stranger)));
    }

    function test_RevertGovernanceSettersDirectly() public {
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, address(this)));
        governor.setVotingPeriod(1 days);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, address(this)));
        governor.setProposalThreshold(0);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, address(this)));
        governor.updateQuorumNumerator(1);
    }

    function _newTimelock() internal returns (FluxoraTimelock) {
        address[] memory none = new address[](0);
        return new FluxoraTimelock(MIN_DELAY, none, none, address(this));
    }

    function test_GovernanceUpdatesTimelockViaProposal() public {
        FluxoraTimelock other = _newTimelock();
        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = address(governor);
        c[0] = abi.encodeCall(FluxoraGovernance.updateTimelock, (TimelockController(payable(address(other)))));
        string memory desc = "migrate timelock";
        bytes32 dh = keccak256(bytes(desc));
        vm.prank(whale);
        uint256 id = governor.propose(t, v, c, desc);
        _toActive(id);
        _vote(id, whale, 1);
        _toEnded(id);
        governor.queue(t, v, c, dh);
        vm.warp(governor.proposalEta(id));
        vm.expectEmit(false, false, false, true, address(governor));
        emit GovernorTimelockControl.TimelockChange(address(timelock), address(other));
        governor.execute(t, v, c, dh);
        assertEq(governor.timelock(), address(other));
    }

    function test_GovernanceUpdatesVotingPeriodViaProposal() public {
        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = address(governor);
        c[0] = abi.encodeCall(GovernorSettings.setVotingPeriod, (uint32(7 days)));
        string memory desc = "longer voting";
        bytes32 dh = keccak256(bytes(desc));
        vm.prank(whale);
        uint256 id = governor.propose(t, v, c, desc);
        _toActive(id);
        _vote(id, whale, 1);
        _toEnded(id);
        governor.queue(t, v, c, dh);
        vm.warp(governor.proposalEta(id));
        governor.execute(t, v, c, dh);
        assertEq(governor.votingPeriod(), 7 days);
    }

    // ------------------------------------------------------------ expiry through governor
    function test_GovernorExecutesAtExactlyEtaPlusGrace() public {
        (uint256 id, uint256 eta) = _proposeVoteQueueFee(40, "last second");
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh) = _feeProposal(40, "last second");
        vm.warp(eta + GRACE);
        governor.execute(t, v, c, dh);
        assertEq(payments.feeBps(), 40);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Executed));
    }

    function test_GovernorExecuteRevertsOperationExpiredOneSecondLate() public {
        (uint256 id, uint256 eta) = _proposeVoteQueueFee(40, "too late");
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh) = _feeProposal(40, "too late");
        bytes32 opId = _timelockId(t, v, c, dh);
        vm.warp(eta + GRACE + 1);
        assertTrue(timelock.isOperationExpired(opId));
        vm.expectRevert(abi.encodeWithSelector(FluxoraTimelock.OperationExpired.selector, opId));
        governor.execute(t, v, c, dh);
        assertEq(payments.feeBps(), 0);
        // still reported as Queued (documented behaviour), never executable again
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Queued));
    }
}
