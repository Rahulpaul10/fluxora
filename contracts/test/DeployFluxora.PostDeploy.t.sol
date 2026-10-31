// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployFluxora} from "../script/DeployFluxora.s.sol";
import {FluxoraToken} from "../src/FluxoraToken.sol";
import {FluxoraTimelock} from "../src/FluxoraTimelock.sol";
import {FluxoraGovernance} from "../src/FluxoraGovernance.sol";
import {FluxoraPayments} from "../src/FluxoraPayments.sol";
import {FluxoraStaking} from "../src/FluxoraStaking.sol";
import {DeployFluxoraBase} from "./DeployFluxora.Base.t.sol";

/// @dev Code that `vm.mockFunction` swaps in: denies every role and reports a wrong timelock.
contract Sabotage {
    address public constant OTHER_TIMELOCK = address(0xBADBAD);

    function hasRole(bytes32, address) external pure returns (bool) {
        return false;
    }

    function timelock() external pure returns (address) {
        return OTHER_TIMELOCK;
    }
}

/// @dev Post-deploy wiring assertion scenarios (run serially by DeployFluxoraTest).
///      The wiring is sabotaged with `vm.mockCall` on the deterministic addresses the script is about to create
///      (derived from the broadcaster's nonce), so the in-script `_assertDeployment` must trip.
abstract contract DeployFluxoraPostDeployScenarios is DeployFluxoraBase {
    Sabotage internal sabotage;

    /// Addresses the next `script.run()` will create: the broadcaster sends 3 creations, 3 role grants, then 2 creations.
    /// `vm.mockFunction` cannot be undone, so every sabotage scenario moves the broadcaster to its own nonce
    /// range (`salt` 1..) and therefore deploys at fresh addresses that no earlier mock can affect.
    function _predict(uint64 salt) internal returns (Deployed memory d) {
        sabotage = new Sabotage();
        address b = _broadcaster();
        if (salt != 0) vm.setNonce(b, salt * 1000);
        uint256 n = vm.getNonce(b);
        d.token = FluxoraToken(vm.computeCreateAddress(b, n));
        d.timelock = FluxoraTimelock(payable(vm.computeCreateAddress(b, n + 1)));
        d.governor = FluxoraGovernance(payable(vm.computeCreateAddress(b, n + 2)));
        d.payments = FluxoraPayments(vm.computeCreateAddress(b, n + 6));
        d.staking = FluxoraStaking(vm.computeCreateAddress(b, n + 7));
    }

    /// `vm.mockCall` would etch code at the not-yet-created address and make the script's CREATE collide,
    /// so reroute the call with `vm.mockFunction` instead (it does not touch the account).
    function _mockHasRole(address target, bytes32 role, address account) internal {
        vm.mockFunction(
            target, address(sabotage), abi.encodeWithSignature("hasRole(bytes32,address)", role, account)
        );
    }

    /// The assertion fires after all five contracts were created (so the creations are recorded in the reverted frame).
    function _expectPostDeployRevert(bytes memory expected) internal {
        assertEq(_expectRunRevert(expected), 5, "assertion should trip after the 5 contracts were created");
    }

    function _missing(address target, bytes32 role, address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(DeployFluxora.MissingDeploymentRole.selector, target, role, account);
    }

    function scenario_MissingProposerRole() public {
        _reset();
        Deployed memory d = _predict(1);
        _mockHasRole(address(d.timelock), PROPOSER_ROLE, address(d.governor));
        _expectPostDeployRevert(_missing(address(d.timelock), PROPOSER_ROLE, address(d.governor)));
    }

    function scenario_MissingCancellerRole() public {
        _reset();
        Deployed memory d = _predict(2);
        _mockHasRole(address(d.timelock), CANCELLER_ROLE, address(d.governor));
        _expectPostDeployRevert(_missing(address(d.timelock), CANCELLER_ROLE, address(d.governor)));
    }

    function scenario_MissingOpenExecutorRole() public {
        _reset();
        Deployed memory d = _predict(3);
        _mockHasRole(address(d.timelock), EXECUTOR_ROLE, address(0));
        _expectPostDeployRevert(_missing(address(d.timelock), EXECUTOR_ROLE, address(0)));
    }

    function scenario_MissingPaymentsAdminRole() public {
        _reset();
        Deployed memory d = _predict(4);
        _mockHasRole(address(d.payments), ADMIN_ROLE, address(d.timelock));
        _expectPostDeployRevert(_missing(address(d.payments), ADMIN_ROLE, address(d.timelock)));
    }

    function scenario_MissingStakingAdminRole() public {
        _reset();
        Deployed memory d = _predict(5);
        _mockHasRole(address(d.staking), ADMIN_ROLE, address(d.timelock));
        _expectPostDeployRevert(_missing(address(d.staking), ADMIN_ROLE, address(d.timelock)));
    }

    function scenario_UnexpectedGovernorTimelock() public {
        _reset();
        Deployed memory d = _predict(6);
        address other = sabotage.OTHER_TIMELOCK();
        vm.mockFunction(address(d.governor), address(sabotage), abi.encodeWithSignature("timelock()"));
        _expectPostDeployRevert(
            abi.encodeWithSelector(
                DeployFluxora.UnexpectedGovernorTimelock.selector, address(d.governor), other, address(d.timelock)
            )
        );
    }

    function scenario_PredictedAddressesMatchRealDeployment() public {
        _reset();
        Deployed memory predicted = _predict(0);
        (Deployed memory real,) = _deploy();
        assertEq(address(real.token), address(predicted.token));
        assertEq(address(real.timelock), address(predicted.timelock));
        assertEq(address(real.governor), address(predicted.governor));
        assertEq(address(real.payments), address(predicted.payments));
        assertEq(address(real.staking), address(predicted.staking));
    }
}
