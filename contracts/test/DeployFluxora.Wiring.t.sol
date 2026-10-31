// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployFluxora} from "../script/DeployFluxora.s.sol";
import {FluxoraPayments} from "../src/FluxoraPayments.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {DeployFluxoraBase} from "./DeployFluxora.Base.t.sol";

/// @dev Happy-path wiring, chain guard and USDC sanity-check scenarios (run serially by DeployFluxoraTest).
abstract contract DeployFluxoraWiringScenarios is DeployFluxoraBase {
    // ------------------------------------------------------------ happy path wiring
    function scenario_DeploysAndWiresEverything() public {
        _reset();
        (Deployed memory d, address b) = _deploy();
        assertNotEq(b, address(0));

        assertEq(d.token.totalSupply(), 1_000_000_000e18);
        assertEq(d.token.balanceOf(b), 1_000_000_000e18); // default initial holder = broadcaster

        assertEq(d.timelock.getMinDelay(), 2 days);
        assertTrue(d.timelock.hasRole(PROPOSER_ROLE, address(d.governor)));
        assertTrue(d.timelock.hasRole(CANCELLER_ROLE, address(d.governor)));
        assertTrue(d.timelock.hasRole(EXECUTOR_ROLE, address(0)));
        assertTrue(d.timelock.hasRole(d.timelock.DEFAULT_ADMIN_ROLE(), address(d.timelock)));

        assertEq(address(d.governor.token()), address(d.token));
        assertEq(d.governor.timelock(), address(d.timelock));
        assertEq(d.governor.votingDelay(), 1 days);
        assertEq(d.governor.votingPeriod(), 3 days);
        assertEq(d.governor.proposalThreshold(), 1_000_000e18);
        assertEq(d.governor.quorumNumerator(), 4);

        assertTrue(d.payments.hasRole(d.payments.DEFAULT_ADMIN_ROLE(), address(d.timelock)));
        assertTrue(d.payments.hasRole(PAUSER_ROLE, b));
        assertTrue(d.payments.supportedTokens(USDC));
        assertTrue(d.payments.supportedTokens(address(d.token)));
        assertEq(d.payments.feeBps(), 0);

        assertEq(address(d.staking.stakingToken()), address(d.token));
        assertTrue(d.staking.hasRole(d.staking.DEFAULT_ADMIN_ROLE(), address(d.timelock)));
        assertTrue(d.staking.hasRole(DISTRIBUTOR_ROLE, b));
        assertTrue(d.staking.hasRole(PAUSER_ROLE, b));
        assertEq(d.staking.rewardsDuration(), 30 days);

        // broadcaster keeps no timelock role (only open execution)
        assertFalse(d.timelock.hasRole(d.timelock.DEFAULT_ADMIN_ROLE(), b));
        assertFalse(d.timelock.hasRole(PROPOSER_ROLE, b));
        assertFalse(d.timelock.hasRole(CANCELLER_ROLE, b));
        assertFalse(d.timelock.hasRole(EXECUTOR_ROLE, b)); // only open (address(0)) execution
        // broadcaster / script have no admin on payments or staking
        assertFalse(d.payments.hasRole(d.payments.DEFAULT_ADMIN_ROLE(), b));
        assertFalse(d.staking.hasRole(d.staking.DEFAULT_ADMIN_ROLE(), b));
        assertFalse(d.timelock.hasRole(d.timelock.DEFAULT_ADMIN_ROLE(), address(script)));
        assertFalse(d.payments.hasRole(d.payments.DEFAULT_ADMIN_ROLE(), address(script)));
        // admin only reachable through the timelock
        vm.prank(b);
        vm.expectRevert();
        d.payments.setFeeBps(0);
        vm.prank(address(d.timelock));
        d.payments.setFeeRecipient(address(0xFEE));
        assertEq(d.payments.feeRecipient(), address(0xFEE));
        // end to end governance at the deployed payments
        vm.prank(b);
        d.token.delegate(b);
        vm.warp(block.timestamp + 1);
        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = address(d.payments);
        c[0] = abi.encodeCall(FluxoraPayments.setFeeRecipient, (address(0xFEE)));
        vm.prank(b);
        uint256 id = d.governor.propose(t, v, c, "set fee recipient");
        vm.warp(d.governor.proposalSnapshot(id) + 1);
        vm.prank(b);
        d.governor.castVote(id, 1);
        vm.warp(d.governor.proposalDeadline(id) + 1);
        bytes32 dh = keccak256(bytes("set fee recipient"));
        d.governor.queue(t, v, c, dh);
        vm.warp(d.governor.proposalEta(id));
        d.governor.execute(t, v, c, dh);
        assertEq(d.payments.feeRecipient(), address(0xFEE));
    }

    function scenario_SucceedsOnTestnetChainId() public {
        _reset();
        vm.chainId(5042002);
        (Deployed memory d,) = _deploy();
        assertEq(d.token.totalSupply(), 1_000_000_000e18);
    }

    function scenario_EnvOverridesAreApplied() public {
        _reset();
        address holder = makeAddr("holder");
        address distributor = makeAddr("distributor");
        address pauser = makeAddr("pauser");
        MockERC20 eurc = new MockERC20("Euro Coin", "EURC", 6);
        _setAddr("FLUX_INITIAL_HOLDER", holder);
        _setAddr("REWARDS_DISTRIBUTOR", distributor);
        _setAddr("PAUSER", pauser);
        _setAddr("EURC_ADDRESS", address(eurc));
        _setUint("TIMELOCK_DELAY", 3 days);
        _setUint("VOTING_DELAY", 2 days);
        _setUint("VOTING_PERIOD", 5 days);
        _setUint("PROPOSAL_THRESHOLD", 5e18);
        _setUint("QUORUM_PERCENT", 10);
        _setUint("STAKING_REWARDS_DURATION", 60 days);
        (Deployed memory d,) = _deploy();
        assertEq(d.token.balanceOf(holder), 1_000_000_000e18);
        assertEq(d.timelock.getMinDelay(), 3 days);
        assertEq(d.governor.votingDelay(), 2 days);
        assertEq(d.governor.votingPeriod(), 5 days);
        assertEq(d.governor.proposalThreshold(), 5e18);
        assertEq(d.governor.quorumNumerator(), 10);
        assertEq(d.staking.rewardsDuration(), 60 days);
        assertTrue(d.staking.hasRole(DISTRIBUTOR_ROLE, distributor));
        assertTrue(d.staking.hasRole(PAUSER_ROLE, pauser));
        assertTrue(d.payments.hasRole(PAUSER_ROLE, pauser));
        assertTrue(d.payments.supportedTokens(address(eurc)));
        assertTrue(d.payments.supportedTokens(USDC));
    }

    // ------------------------------------------------------------ chain guard
    function scenario_RevertsOnWrongChainId() public {
        _reset();
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployFluxora.UnsupportedChain.selector, 1));
        script.run();
        vm.chainId(5043);
        vm.expectRevert(abi.encodeWithSelector(DeployFluxora.UnsupportedChain.selector, 5043));
        script.run();
    }

    // ------------------------------------------------------------ USDC sanity checks (custom errors)
    bytes4 internal constant SYMBOL_SEL = bytes4(keccak256("symbol()"));
    bytes4 internal constant DECIMALS_SEL = bytes4(keccak256("decimals()"));

    function scenario_UsdcWrongSymbol() public {
        _reset();
        _etchUsdc("USDT", 4, 6);
        _expectPreBroadcastRevert(abi.encodeWithSelector(DeployFluxora.UnexpectedUsdcSymbol.selector, USDC, "USDT", "USDC"));
    }

    function scenario_UsdcWrongSymbolCase() public {
        _reset();
        _etchUsdc("usdc", 4, 6);
        _expectPreBroadcastRevert(abi.encodeWithSelector(DeployFluxora.UnexpectedUsdcSymbol.selector, USDC, "usdc", "USDC"));
    }

    function scenario_UsdcWrongDecimals() public {
        _reset();
        _etchUsdc("USDC", 4, 18);
        _expectPreBroadcastRevert(abi.encodeWithSelector(DeployFluxora.UnexpectedUsdcDecimals.selector, USDC, 18, 6));
    }

    function scenario_UsdcDecimalsAboveUint8IsNotTruncated() public {
        _reset();
        vm.mockCall(USDC, abi.encodeWithSelector(DECIMALS_SEL), abi.encode(uint256(256 + 6)));
        _expectPreBroadcastRevert(abi.encodeWithSelector(DeployFluxora.UnexpectedUsdcDecimals.selector, USDC, 262, 6));
    }

    function scenario_UsdcHasNoCode() public {
        _reset();
        vm.etch(USDC, "");
        _expectPreBroadcastRevert(abi.encodeWithSelector(DeployFluxora.UsdcHasNoCode.selector, USDC));
    }

    function scenario_UsdcSymbolReturnsNothing() public {
        _reset();
        vm.etch(USDC, hex"00"); // STOP: staticcall succeeds with empty returndata
        _expectPreBroadcastRevert(
            abi.encodeWithSelector(DeployFluxora.InvalidUsdcMetadata.selector, USDC, SYMBOL_SEL, bytes(""))
        );
    }

    function scenario_UsdcSymbolCallReverts() public {
        _reset();
        vm.etch(USDC, hex"5f5ffd"); // PUSH0 PUSH0 REVERT
        _expectPreBroadcastRevert(
            abi.encodeWithSelector(DeployFluxora.InvalidUsdcMetadata.selector, USDC, SYMBOL_SEL, bytes(""))
        );
    }

    function scenario_UsdcSymbolNonCanonicalEncoding() public {
        _reset();
        bytes memory raw = bytes.concat(abi.encode("USDC"), bytes32(0)); // decodes, but has trailing bytes
        vm.mockCall(USDC, abi.encodeWithSelector(SYMBOL_SEL), raw);
        _expectPreBroadcastRevert(
            abi.encodeWithSelector(DeployFluxora.InvalidUsdcMetadata.selector, USDC, SYMBOL_SEL, raw)
        );
    }

    function scenario_UsdcDecimalsMalformed() public {
        _reset();
        bytes memory shortData = hex"06"; // not 32 bytes
        vm.mockCall(USDC, abi.encodeWithSelector(DECIMALS_SEL), shortData);
        _expectPreBroadcastRevert(
            abi.encodeWithSelector(DeployFluxora.InvalidUsdcMetadata.selector, USDC, DECIMALS_SEL, shortData)
        );
        vm.clearMockedCalls();
        bytes memory longData = abi.encode(uint256(6), uint256(6)); // 64 bytes
        vm.mockCall(USDC, abi.encodeWithSelector(DECIMALS_SEL), longData);
        _expectPreBroadcastRevert(
            abi.encodeWithSelector(DeployFluxora.InvalidUsdcMetadata.selector, USDC, DECIMALS_SEL, longData)
        );
    }

    function scenario_UsdcDecimalsCallReverts() public {
        _reset();
        vm.mockCallRevert(USDC, abi.encodeWithSelector(DECIMALS_SEL), bytes("nope"));
        _expectPreBroadcastRevert(
            abi.encodeWithSelector(DeployFluxora.InvalidUsdcMetadata.selector, USDC, DECIMALS_SEL, bytes("nope"))
        );
    }
}
