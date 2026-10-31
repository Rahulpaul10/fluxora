// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DeployFluxora} from "../script/DeployFluxora.s.sol";
import {FLUXORA_INITIAL_SUPPLY} from "../src/FluxoraToken.sol";
import {DeployFluxoraBase} from "./DeployFluxora.Base.t.sol";

/// @dev Pre-broadcast configuration validation scenarios (run serially by DeployFluxoraTest).
///      Every invalid value must revert before ANY contract is created; every boundary value must deploy.
abstract contract DeployFluxoraConfigScenarios is DeployFluxoraBase {
    function scenario_ProposalThresholdTooHigh() public {
        _reset();
        uint256 max = FLUXORA_INITIAL_SUPPLY;
        _expectBadUint(
            "PROPOSAL_THRESHOLD", max + 1,
            abi.encodeWithSelector(DeployFluxora.ProposalThresholdTooHigh.selector, max + 1, max)
        );
        _expectBadUint(
            "PROPOSAL_THRESHOLD", type(uint256).max,
            abi.encodeWithSelector(DeployFluxora.ProposalThresholdTooHigh.selector, type(uint256).max, max)
        );
        // boundaries: exactly INITIAL_SUPPLY, and zero
        assertEq(_deployWithUint("PROPOSAL_THRESHOLD", max).governor.proposalThreshold(), max);
        assertEq(_deployWithUint("PROPOSAL_THRESHOLD", 0).governor.proposalThreshold(), 0);
    }

    function scenario_InvalidQuorumPercent() public {
        _reset();
        _expectBadUint("QUORUM_PERCENT", 0, abi.encodeWithSelector(DeployFluxora.InvalidQuorumPercent.selector, 0, 1, 100));
        _expectBadUint("QUORUM_PERCENT", 101, abi.encodeWithSelector(DeployFluxora.InvalidQuorumPercent.selector, 101, 1, 100));
        _expectBadUint(
            "QUORUM_PERCENT", type(uint256).max,
            abi.encodeWithSelector(DeployFluxora.InvalidQuorumPercent.selector, type(uint256).max, 1, 100)
        );
        assertEq(_deployWithUint("QUORUM_PERCENT", 1).governor.quorumNumerator(), 1);
        assertEq(_deployWithUint("QUORUM_PERCENT", 100).governor.quorumNumerator(), 100);
    }

    function scenario_VotingPeriodTooShort() public {
        _reset();
        _expectBadUint("VOTING_PERIOD", 0, abi.encodeWithSelector(DeployFluxora.VotingPeriodTooShort.selector, 0, 1 hours));
        _expectBadUint(
            "VOTING_PERIOD", 1 hours - 1,
            abi.encodeWithSelector(DeployFluxora.VotingPeriodTooShort.selector, 1 hours - 1, 1 hours)
        );
        assertEq(_deployWithUint("VOTING_PERIOD", 1 hours).governor.votingPeriod(), 1 hours);
        assertEq(_deployWithUint("VOTING_PERIOD", type(uint32).max).governor.votingPeriod(), type(uint32).max);
    }

    function scenario_VotingPeriodAboveUint32Reverts() public {
        _reset();
        uint256 v = uint256(type(uint32).max) + 1;
        _expectBadUint(
            "VOTING_PERIOD", v, abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 32, v)
        );
    }

    function scenario_TimelockDelayTooShort() public {
        _reset();
        _expectBadUint("TIMELOCK_DELAY", 0, abi.encodeWithSelector(DeployFluxora.TimelockDelayTooShort.selector, 0, 1 hours));
        _expectBadUint(
            "TIMELOCK_DELAY", 1 hours - 1,
            abi.encodeWithSelector(DeployFluxora.TimelockDelayTooShort.selector, 1 hours - 1, 1 hours)
        );
        assertEq(_deployWithUint("TIMELOCK_DELAY", 1 hours).timelock.getMinDelay(), 1 hours);
    }

    function scenario_InvalidRewardsDuration() public {
        _reset();
        bytes4 sel = DeployFluxora.InvalidRewardsDuration.selector;
        _expectBadUint("STAKING_REWARDS_DURATION", 0, abi.encodeWithSelector(sel, 0, 7 days, 365 days));
        _expectBadUint(
            "STAKING_REWARDS_DURATION", 7 days - 1, abi.encodeWithSelector(sel, 7 days - 1, 7 days, 365 days)
        );
        _expectBadUint(
            "STAKING_REWARDS_DURATION", 365 days + 1, abi.encodeWithSelector(sel, 365 days + 1, 7 days, 365 days)
        );
        assertEq(_deployWithUint("STAKING_REWARDS_DURATION", 7 days).staking.rewardsDuration(), 7 days);
        assertEq(_deployWithUint("STAKING_REWARDS_DURATION", 365 days).staking.rewardsDuration(), 365 days);
    }

    function scenario_ZeroAddressRolesAndEurcWithoutCodeAreInvalid() public {
        _reset();
        bytes memory err = abi.encodeWithSelector(DeployFluxora.InvalidConfiguration.selector);
        string[3] memory names = ["FLUX_INITIAL_HOLDER", "REWARDS_DISTRIBUTOR", "PAUSER"];
        for (uint256 i; i < 3; ++i) {
            _setAddr(names[i], address(0));
            _expectPreBroadcastRevert(err);
            _unsetEnv(names[i]);
        }
        _setAddr("EURC_ADDRESS", makeAddr("eoaEurc"));
        _expectPreBroadcastRevert(err);
        _unsetEnv("EURC_ADDRESS");
    }

    function scenario_ConfigErrorsArePrioritisedOverUsdcChecks() public {
        _reset();
        vm.etch(USDC, "");
        _setUint("QUORUM_PERCENT", 0);
        _expectPreBroadcastRevert(abi.encodeWithSelector(DeployFluxora.InvalidQuorumPercent.selector, 0, 1, 100));
        _unsetEnv("QUORUM_PERCENT");
        _expectPreBroadcastRevert(abi.encodeWithSelector(DeployFluxora.UsdcHasNoCode.selector, USDC));
    }
}
