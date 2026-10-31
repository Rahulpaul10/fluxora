// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {FluxoraToken} from "../src/FluxoraToken.sol";
import {FluxoraTimelock} from "../src/FluxoraTimelock.sol";
import {FluxoraGovernance} from "../src/FluxoraGovernance.sol";
import {FluxoraPayments} from "../src/FluxoraPayments.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

abstract contract FluxoraGovernanceTestBase is Test {
    FluxoraToken internal flux;
    FluxoraTimelock internal timelock;
    FluxoraGovernance internal governor;
    FluxoraPayments internal payments;
    MockERC20 internal usdc;

    address internal treasury = makeAddr("treasury");
    address internal pauser = makeAddr("pauser");
    address internal collector = makeAddr("collector");
    address internal whale = makeAddr("whale"); // 900M, proposer + majority
    address internal voterA = makeAddr("voterA"); // 30M (3%)
    address internal voterB = makeAddr("voterB"); // 20M (2%)
    address internal small = makeAddr("small"); // below proposal threshold
    address internal stranger = makeAddr("stranger");

    uint48 internal constant VOTING_DELAY = 1 days;
    uint32 internal constant VOTING_PERIOD = 3 days;
    uint256 internal constant THRESHOLD = 1_000_000e18;
    uint256 internal constant QUORUM_PCT = 4;
    uint256 internal constant MIN_DELAY = 2 days;
    uint256 internal constant GRACE = 14 days;

    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        flux = new FluxoraToken(treasury);
        address[] memory none = new address[](0);
        timelock = new FluxoraTimelock(MIN_DELAY, none, none, address(this));
        governor = new FluxoraGovernance(
            IVotes(address(flux)), timelock, VOTING_DELAY, VOTING_PERIOD, THRESHOLD, QUORUM_PCT
        );
        timelock.grantRole(PROPOSER_ROLE, address(governor));
        timelock.grantRole(CANCELLER_ROLE, address(governor));
        timelock.grantRole(EXECUTOR_ROLE, address(0));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        payments = new FluxoraPayments(address(this), pauser, tokens);
        payments.setFeeRecipient(collector);
        payments.grantRole(payments.DEFAULT_ADMIN_ROLE(), address(timelock));
        payments.renounceRole(payments.DEFAULT_ADMIN_ROLE(), address(this));

        vm.startPrank(treasury);
        flux.transfer(whale, 900_000_000e18);
        flux.transfer(voterA, 30_000_000e18);
        flux.transfer(voterB, 20_000_000e18);
        flux.transfer(small, THRESHOLD - 1e18);
        vm.stopPrank();
        _selfDelegate(whale);
        _selfDelegate(voterA);
        _selfDelegate(voterB);
        _selfDelegate(small);
        vm.warp(block.timestamp + 1);
    }

    function _selfDelegate(address who) internal {
        vm.prank(who);
        flux.delegate(who);
    }

    // ------------------------------------------------------------ proposal helpers
    function _feeProposal(uint256 bps, string memory desc)
        internal view
        returns (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh)
    {
        t = new address[](1);
        v = new uint256[](1);
        c = new bytes[](1);
        t[0] = address(payments);
        c[0] = abi.encodeCall(FluxoraPayments.setFeeBps, (bps));
        dh = keccak256(bytes(desc));
    }

    function _proposeFee(uint256 bps, string memory desc) internal returns (uint256 id) {
        (address[] memory t, uint256[] memory v, bytes[] memory c,) = _feeProposal(bps, desc);
        vm.prank(whale);
        id = governor.propose(t, v, c, desc);
    }

    function _vote(uint256 id, address who, uint8 support) internal {
        vm.prank(who);
        governor.castVote(id, support);
    }

    function _toActive(uint256 id) internal {
        vm.warp(governor.proposalSnapshot(id) + 1);
    }

    function _toEnded(uint256 id) internal {
        vm.warp(governor.proposalDeadline(id) + 1);
    }

    /// propose -> vote (whale for) -> ends -> queue; returns the id and queue eta.
    function _proposeVoteQueueFee(uint256 bps, string memory desc) internal returns (uint256 id, uint256 eta) {
        id = _proposeVoteQueue(bps, desc);
        eta = governor.proposalEta(id);
    }

    function _proposeVoteQueue(uint256 bps, string memory desc) internal returns (uint256 id) {
        id = _proposeFee(bps, desc);
        _toActive(id);
        _vote(id, whale, 1);
        _toEnded(id);
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh) = _feeProposal(bps, desc);
        governor.queue(t, v, c, dh);
    }

    /// Operation id under which the governor schedules a proposal in the timelock.
    function _timelockId(address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh)
        internal view returns (bytes32)
    {
        return timelock.hashOperationBatch(t, v, c, bytes32(0), bytes32(bytes20(address(governor))) ^ dh);
    }
}
