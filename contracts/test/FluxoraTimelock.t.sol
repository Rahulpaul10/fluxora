// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {FluxoraTimelock} from "../src/FluxoraTimelock.sol";
import {FluxoraPayments} from "../src/FluxoraPayments.sol";
import {FluxoraGovernanceTestBase} from "./FluxoraGovernance.Base.t.sol";

contract FluxoraTimelockTest is FluxoraGovernanceTestBase {
    bytes32 internal constant SALT = keccak256("salt");

    function _call(uint256 bps) internal view returns (bytes memory) {
        return abi.encodeCall(FluxoraPayments.setFeeBps, (bps));
    }

    function _scheduleSingle(uint256 bps, bytes32 salt) internal returns (bytes32 id, uint256 ready) {
        bytes memory data = _call(bps);
        id = timelock.hashOperation(address(payments), 0, data, bytes32(0), salt);
        vm.prank(address(governor));
        timelock.schedule(address(payments), 0, data, bytes32(0), salt, MIN_DELAY);
        ready = block.timestamp + MIN_DELAY;
    }

    function _batch(uint256 bps)
        internal view returns (address[] memory t, uint256[] memory v, bytes[] memory c)
    {
        t = new address[](1);
        v = new uint256[](1);
        c = new bytes[](1);
        t[0] = address(payments);
        c[0] = _call(bps);
    }

    function _scheduleBatch(uint256 bps, bytes32 salt) internal returns (bytes32 id, uint256 ready) {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _batch(bps);
        id = timelock.hashOperationBatch(t, v, c, bytes32(0), salt);
        vm.prank(address(governor));
        timelock.scheduleBatch(t, v, c, bytes32(0), salt, MIN_DELAY);
        ready = block.timestamp + MIN_DELAY;
    }

    // ------------------------------------------------------------ wiring
    function test_RolesAndDelay() public view {
        assertEq(timelock.getMinDelay(), MIN_DELAY);
        assertEq(timelock.GRACE_PERIOD(), 14 days);
        assertTrue(timelock.hasRole(PROPOSER_ROLE, address(governor)));
        assertTrue(timelock.hasRole(CANCELLER_ROLE, address(governor)));
        assertTrue(timelock.hasRole(EXECUTOR_ROLE, address(0)));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(timelock.hasRole(PROPOSER_ROLE, address(this)));
    }

    function test_RevertScheduleByNonProposer() public {
        bytes memory data = _call(1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, PROPOSER_ROLE));
        timelock.schedule(address(payments), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    function test_RevertScheduleBelowMinDelay() public {
        bytes memory data = _call(1);
        vm.prank(address(governor));
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, 1 days, MIN_DELAY));
        timelock.schedule(address(payments), 0, data, bytes32(0), SALT, 1 days);
    }

    function test_RevertUpdateDelayDirectly() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, stranger));
        timelock.updateDelay(0);
    }

    function test_ScheduleEmitsAndSetsReadyTimestamp() public {
        bytes memory data = _call(25);
        bytes32 id = timelock.hashOperation(address(payments), 0, data, bytes32(0), SALT);
        vm.expectEmit(true, true, false, true, address(timelock));
        emit TimelockController.CallScheduled(id, 0, address(payments), 0, data, bytes32(0), MIN_DELAY);
        vm.prank(address(governor));
        timelock.schedule(address(payments), 0, data, bytes32(0), SALT, MIN_DELAY);
        assertEq(timelock.getTimestamp(id), block.timestamp + MIN_DELAY);
        assertTrue(timelock.isOperationPending(id));
        assertFalse(timelock.isOperationReady(id));
    }

    // ------------------------------------------------------------ execute: readiness + grace boundaries
    function test_ExecuteAtExactlyReadyTimestamp() public {
        (bytes32 id, uint256 ready) = _scheduleSingle(25, SALT);
        vm.warp(ready - 1);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        timelock.execute(address(payments), 0, _call(25), bytes32(0), SALT);
        vm.warp(ready);
        assertTrue(timelock.isOperationReady(id));
        vm.expectEmit(true, true, false, true, address(timelock));
        emit TimelockController.CallExecuted(id, 0, address(payments), 0, _call(25));
        vm.prank(stranger); // open executor role
        timelock.execute(address(payments), 0, _call(25), bytes32(0), SALT);
        assertEq(payments.feeBps(), 25);
        assertTrue(timelock.isOperationDone(id));
    }

    function test_ExecuteAtReadyPlus14DaysWorks() public {
        (bytes32 id, uint256 ready) = _scheduleSingle(30, SALT);
        vm.warp(ready + GRACE);
        assertFalse(timelock.isOperationExpired(id));
        assertTrue(timelock.isOperationReady(id));
        timelock.execute(address(payments), 0, _call(30), bytes32(0), SALT);
        assertEq(payments.feeBps(), 30);
    }

    function test_ExecuteOneSecondAfterGraceRevertsOperationExpired() public {
        (bytes32 id, uint256 ready) = _scheduleSingle(30, SALT);
        vm.warp(ready + GRACE + 1);
        assertTrue(timelock.isOperationExpired(id));
        vm.expectRevert(abi.encodeWithSelector(FluxoraTimelock.OperationExpired.selector, id));
        timelock.execute(address(payments), 0, _call(30), bytes32(0), SALT);
        assertEq(payments.feeBps(), 0);
    }

    function test_ExecuteBatchAtReadyPlus14DaysWorks() public {
        (bytes32 id, uint256 ready) = _scheduleBatch(35, SALT);
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _batch(35);
        vm.warp(ready + GRACE);
        assertFalse(timelock.isOperationExpired(id));
        timelock.executeBatch(t, v, c, bytes32(0), SALT);
        assertEq(payments.feeBps(), 35);
    }

    function test_ExecuteBatchOneSecondAfterGraceRevertsOperationExpired() public {
        (bytes32 id, uint256 ready) = _scheduleBatch(35, SALT);
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _batch(35);
        vm.warp(ready + GRACE + 1);
        vm.expectRevert(abi.encodeWithSelector(FluxoraTimelock.OperationExpired.selector, id));
        timelock.executeBatch(t, v, c, bytes32(0), SALT);
        assertEq(payments.feeBps(), 0);
    }

    function test_ExpiredOperationFarInTheFutureStillReverts() public {
        (bytes32 id, uint256 ready) = _scheduleSingle(30, SALT);
        vm.warp(ready + 365 days);
        vm.expectRevert(abi.encodeWithSelector(FluxoraTimelock.OperationExpired.selector, id));
        timelock.execute(address(payments), 0, _call(30), bytes32(0), SALT);
    }

    // ------------------------------------------------------------ expiry views
    function test_IsOperationExpiredBoundaries() public {
        (bytes32 id, uint256 ready) = _scheduleSingle(30, SALT);
        assertFalse(timelock.isOperationExpired(id)); // before ready
        vm.warp(ready);
        assertFalse(timelock.isOperationExpired(id));
        vm.warp(ready + GRACE);
        assertFalse(timelock.isOperationExpired(id));
        vm.warp(ready + GRACE + 1);
        assertTrue(timelock.isOperationExpired(id));
    }

    function test_ExpiredOperationReportsWaitingNotReadyButStillPending() public {
        (bytes32 id, uint256 ready) = _scheduleSingle(30, SALT);
        vm.warp(ready + GRACE + 1);
        assertEq(uint8(timelock.getOperationState(id)), uint8(TimelockController.OperationState.Waiting));
        assertFalse(timelock.isOperationReady(id));
        assertTrue(timelock.isOperationPending(id));
        assertFalse(timelock.isOperationDone(id));
        assertTrue(timelock.isOperation(id));
    }

    function test_UnsetAndDoneOperationsNeverExpire() public {
        bytes32 unknown = keccak256("unknown");
        assertFalse(timelock.isOperationExpired(unknown));
        (bytes32 id, uint256 ready) = _scheduleSingle(30, SALT);
        vm.warp(ready);
        timelock.execute(address(payments), 0, _call(30), bytes32(0), SALT);
        vm.warp(ready + 100 days);
        assertFalse(timelock.isOperationExpired(id));
        assertTrue(timelock.isOperationDone(id));
        assertEq(uint8(timelock.getOperationState(id)), uint8(TimelockController.OperationState.Done));
    }

    function test_RevertExecuteUnscheduled() public {
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        timelock.execute(address(payments), 0, _call(1), bytes32(0), SALT);
    }

    function test_RevertExecuteTwice() public {
        (, uint256 ready) = _scheduleSingle(30, SALT);
        vm.warp(ready);
        timelock.execute(address(payments), 0, _call(30), bytes32(0), SALT);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        timelock.execute(address(payments), 0, _call(30), bytes32(0), SALT);
    }

    // ------------------------------------------------------------ cancel
    function test_ExpiredOperationCanStillBeCancelled() public {
        (bytes32 id, uint256 ready) = _scheduleSingle(30, SALT);
        vm.warp(ready + GRACE + 1);
        vm.expectEmit(true, false, false, true, address(timelock));
        emit TimelockController.Cancelled(id);
        vm.prank(address(governor));
        timelock.cancel(id);
        assertFalse(timelock.isOperation(id));
        assertFalse(timelock.isOperationExpired(id));
        // the slot is free again: the same operation can be re-scheduled and executed
        (bytes32 id2, uint256 ready2) = _scheduleSingle(30, SALT);
        assertEq(id2, id);
        vm.warp(ready2);
        timelock.execute(address(payments), 0, _call(30), bytes32(0), SALT);
        assertEq(payments.feeBps(), 30);
    }

    function test_RevertCancelByNonCanceller() public {
        (bytes32 id,) = _scheduleSingle(30, SALT);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, CANCELLER_ROLE));
        timelock.cancel(id);
    }

    function test_RevertCancelUnknownOperation() public {
        vm.prank(address(governor));
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        timelock.cancel(keccak256("nope"));
    }

    // ------------------------------------------------------------ fuzz
    function testFuzz_ExecutableIffWithinGraceWindow(uint256 offset) public {
        offset = bound(offset, 0, 60 days);
        (bytes32 id, uint256 ready) = _scheduleSingle(10, SALT);
        vm.warp(ready + offset);
        if (offset <= GRACE) {
            assertFalse(timelock.isOperationExpired(id));
            timelock.execute(address(payments), 0, _call(10), bytes32(0), SALT);
            assertEq(payments.feeBps(), 10);
        } else {
            assertTrue(timelock.isOperationExpired(id));
            vm.expectRevert(abi.encodeWithSelector(FluxoraTimelock.OperationExpired.selector, id));
            timelock.execute(address(payments), 0, _call(10), bytes32(0), SALT);
        }
    }
}
