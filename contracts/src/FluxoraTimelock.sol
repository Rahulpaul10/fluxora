// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title FLUXORA governance timelock
/// @notice Dedicated TimelockController artifact; operations expire 14 days after becoming ready.
/// @dev Delays are measured in seconds. The temporary bootstrap admin should renounce its role after governance setup.
/// @custom:upgrade-strategy Direct, non-upgradeable deployment (no proxy).
/// @dev Code changes require a replacement deployment and migration.
contract FluxoraTimelock is TimelockController {
    uint256 public constant GRACE_PERIOD = 14 days;

    error OperationExpired(bytes32 id);

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    {}

    /// @notice Whether a scheduled, unexecuted operation is past its execution grace period.
    /// @dev The last second of the grace period remains executable; unset and done operations never expire.
    function isOperationExpired(bytes32 id) public view returns (bool) {
        uint256 timestamp = getTimestamp(id);
        return timestamp > DONE_TIMESTAMP && block.timestamp > timestamp
            && block.timestamp - timestamp > GRACE_PERIOD;
    }

    /// @dev Expired operations remain pending and cancellable, but are never ready for execution.
    ///      OpenZeppelin 5.6.1's non-virtual isOperationReady routes through this override.
    function getOperationState(bytes32 id) public view override returns (OperationState) {
        OperationState currentState = super.getOperationState(id);
        if (currentState == OperationState.Ready && isOperationExpired(id)) {
            return OperationState.Waiting;
        }
        return currentState;
    }

    /// @dev Enforces expiry with a contextual error before the inherited execution checks.
    function execute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt)
        public payable override
    {
        bytes32 id = hashOperation(target, value, payload, predecessor, salt);
        if (isOperationExpired(id)) revert OperationExpired(id);
        super.execute(target, value, payload, predecessor, salt);
    }

    /// @dev Enforces expiry for direct batch execution as well as governor execution.
    function executeBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads,
        bytes32 predecessor, bytes32 salt)
        public payable override
    {
        bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);
        if (isOperationExpired(id)) revert OperationExpired(id);
        super.executeBatch(targets, values, payloads, predecessor, salt);
    }
}
