// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title FLUXORA timestamp governance
/// @notice FLUX holders delegate votes, propose, vote, and execute through the timelock.
/// @dev Delay and period are seconds. The supplied token must expose the timestamp ERC-6372 clock.
/// @custom:upgrade-strategy Direct, non-upgradeable deployment (no proxy).
/// @dev Code changes require a replacement deployment and migration; updateTimelock only swaps a dependency.
contract FluxoraGovernance is Governor, GovernorSettings, GovernorCountingSimple, GovernorVotes,
    GovernorVotesQuorumFraction, GovernorTimelockControl
{
    /// @notice The supplied voting token has no deployed code.
    error InvalidVotingToken(address token);
    /// @notice The voting token's clock mode is incompatible with timestamp governance.
    error UnsupportedClockMode(address token, string mode);
    error InvalidTimelock(address timelockAddress);

    constructor(IVotes token_, TimelockController timelock_, uint48 votingDelay_, uint32 votingPeriod_,
        uint256 proposalThreshold_, uint256 quorumPercent_)
        Governor("FluxoraGovernance")
        GovernorSettings(votingDelay_, votingPeriod_, proposalThreshold_)
        GovernorVotes(_requireVotingTokenCode(token_))
        GovernorVotesQuorumFraction(quorumPercent_)
        GovernorTimelockControl(timelock_)
    {
        _validateTimelock(timelock_);
        if (address(token_).code.length == 0) {
            revert InvalidVotingToken(address(token_));
        }
        string memory mode = token().CLOCK_MODE();
        if (keccak256(bytes(mode)) != keccak256(bytes("mode=timestamp"))) {
            revert UnsupportedClockMode(address(token_), mode);
        }
    }

    function _requireVotingTokenCode(IVotes token_) private view returns (IVotes) {
        if (address(token_).code.length == 0) {
            revert InvalidVotingToken(address(token_));
        }
        return token_;
    }

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function quorum(uint256 timepoint)
        public view override(Governor, GovernorVotesQuorumFraction) returns (uint256)
    {
        return super.quorum(timepoint);
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    /// @notice Proposals past the timelock grace window remain Queued but can no longer be executed.
    /// @dev FluxoraTimelock reverts OperationExpired; this override only resolves inheritance.
    function state(uint256 proposalId)
        public view override(Governor, GovernorTimelockControl) returns (ProposalState)
    {
        return super.state(proposalId);
    }

    /// @dev The inherited implementation retains onlyGovernance authorization.
    function updateTimelock(TimelockController newTimelock) public override {
        _validateTimelock(newTimelock);
        super.updateTimelock(newTimelock);
    }

    function _validateTimelock(TimelockController timelock_) internal view {
        if (address(timelock_) == address(0) || address(timelock_).code.length == 0) {
            revert InvalidTimelock(address(timelock_));
        }
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public view override(Governor, GovernorTimelockControl) returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(uint256 proposalId, address[] memory targets, uint256[] memory values,
        bytes[] memory calldatas, bytes32 descriptionHash)
        internal override(Governor, GovernorTimelockControl) returns (uint48)
    {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(uint256 proposalId, address[] memory targets, uint256[] memory values,
        bytes[] memory calldatas, bytes32 descriptionHash)
        internal override(Governor, GovernorTimelockControl)
    {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(address[] memory targets, uint256[] memory values, bytes[] memory calldatas,
        bytes32 descriptionHash)
        internal override(Governor, GovernorTimelockControl) returns (uint256)
    {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
