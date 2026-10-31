// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FluxoraStaking} from "../src/FluxoraStaking.sol";
import {FluxoraToken} from "../src/FluxoraToken.sol";

abstract contract FluxoraStakingTestBase is Test {
    FluxoraToken internal flux;
    FluxoraStaking internal staking;
    address internal treasury = makeAddr("treasury");
    address internal admin = makeAddr("admin");
    address internal distributor = makeAddr("distributor");
    address internal pauser = makeAddr("pauser");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant DURATION = 30 days;
    uint256 internal constant RATE = 1e18; // tokens-wei per second
    uint256 internal constant REWARD = DURATION * RATE;
    uint256 internal constant STAKE = 100e18;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        flux = new FluxoraToken(treasury);
        staking = new FluxoraStaking(IERC20(address(flux)), admin, distributor, pauser, DURATION);
        vm.startPrank(treasury);
        flux.transfer(alice, 1_000_000e18);
        flux.transfer(bob, 1_000_000e18);
        flux.transfer(distributor, 100_000_000e18);
        vm.stopPrank();
        _approve(alice);
        _approve(bob);
        _approve(distributor);
    }

    function _approve(address who) internal {
        vm.prank(who);
        flux.approve(address(staking), type(uint256).max);
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        staking.stake(amount);
    }

    function _notify(uint256 reward) internal {
        vm.prank(distributor);
        staking.notifyRewardAmount(reward);
    }

    function _unauth(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
    }
}
