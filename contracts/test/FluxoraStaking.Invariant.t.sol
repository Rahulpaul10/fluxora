// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FluxoraStaking} from "../src/FluxoraStaking.sol";
import {FluxoraToken} from "../src/FluxoraToken.sol";

contract StakingHandler is Test {
    FluxoraStaking public staking;
    FluxoraToken public flux;
    address public distributor;
    address public pauser;
    address[] public actors;

    uint256 public ghostNotified;
    uint256 public ghostClaimed;
    uint256 public ghostStaked; // sum of principal deposited minus withdrawn
    bool public principalWithdrawFailed;
    bool public pausedWithdrawFailed;

    constructor(FluxoraStaking s, FluxoraToken f, address treasury, address distributor_, address pauser_) {
        staking = s;
        flux = f;
        distributor = distributor_;
        pauser = pauser_;
        for (uint256 i; i < 3; ++i) {
            address a = address(uint160(0xB000 + i));
            actors.push(a);
            vm.prank(treasury);
            f.transfer(a, 10_000_000e18);
            vm.prank(a);
            f.approve(address(s), type(uint256).max);
        }
        vm.prank(treasury);
        f.transfer(distributor_, 500_000_000e18);
        vm.prank(distributor_);
        f.approve(address(s), type(uint256).max);
    }

    function actorCount() external view returns (uint256) { return actors.length; }

    function stake(uint256 seed, uint256 amount) external {
        if (staking.paused()) return;
        address a = actors[seed % actors.length];
        amount = bound(amount, 1, flux.balanceOf(a));
        vm.prank(a);
        staking.stake(amount);
        ghostStaked += amount;
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address a = actors[seed % actors.length];
        uint256 bal = staking.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        bool wasPaused = staking.paused();
        uint256 before_ = flux.balanceOf(a);
        vm.prank(a);
        try staking.withdraw(amount) {
            ghostStaked -= amount;
            if (flux.balanceOf(a) != before_ + amount) principalWithdrawFailed = true;
        } catch {
            principalWithdrawFailed = true;
            if (wasPaused) pausedWithdrawFailed = true;
        }
    }

    function getReward(uint256 seed) external {
        address a = actors[seed % actors.length];
        uint256 before_ = flux.balanceOf(a);
        vm.prank(a);
        staking.getReward();
        ghostClaimed += flux.balanceOf(a) - before_;
    }

    function exit(uint256 seed) external {
        address a = actors[seed % actors.length];
        uint256 bal = staking.balanceOf(a);
        uint256 before_ = flux.balanceOf(a);
        vm.prank(a);
        try staking.exit() {
            ghostStaked -= bal;
            ghostClaimed += flux.balanceOf(a) - before_ - bal;
        } catch {
            principalWithdrawFailed = true;
            if (staking.paused()) pausedWithdrawFailed = true;
        }
    }

    function notify(uint256 reward) external {
        if (staking.totalStaked() == 0) return;
        uint256 dur = staking.rewardsDuration();
        reward = bound(reward, dur, 1_000_000e18);
        vm.prank(distributor);
        staking.notifyRewardAmount(reward);
        ghostNotified += reward;
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 0, 20 days);
        vm.warp(block.timestamp + dt);
    }

    function setPaused(bool p) external {
        vm.startPrank(pauser);
        if (p && !staking.paused()) staking.pause();
        else if (!p && staking.paused()) staking.unpause();
        vm.stopPrank();
    }

    function totalEarned() external view returns (uint256 sum) {
        for (uint256 i; i < actors.length; ++i) sum += staking.earned(actors[i]);
    }
}

contract FluxoraStakingInvariantTest is Test {
    FluxoraToken internal flux;
    FluxoraStaking internal staking;
    StakingHandler internal handler;
    address internal treasury = makeAddr("treasury");
    address internal admin = makeAddr("admin");
    address internal distributor = makeAddr("distributor");
    address internal pauser = makeAddr("pauser");

    function setUp() public {
        vm.warp(1_700_000_000);
        flux = new FluxoraToken(treasury);
        staking = new FluxoraStaking(IERC20(address(flux)), admin, distributor, pauser, 30 days);
        handler = new StakingHandler(staking, flux, treasury, distributor, pauser);
        targetContract(address(handler));
    }

    /// Solvency: token balance covers all principal plus all reserved rewards.
    function invariant_Solvency() public view {
        assertGe(flux.balanceOf(address(staking)), staking.totalStaked() + staking.rewardReserve());
    }

    /// Principal accounting: totalStaked is the sum of staker balances and equals deposits - withdrawals.
    function invariant_PrincipalAccounting() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) sum += staking.balanceOf(handler.actors(i));
        assertEq(sum, staking.totalStaked());
        assertEq(handler.ghostStaked(), staking.totalStaked());
    }

    /// A staker can always withdraw principal, including while paused.
    function invariant_PrincipalAlwaysWithdrawable() public view {
        assertFalse(handler.principalWithdrawFailed());
        assertFalse(handler.pausedWithdrawFailed());
    }

    /// Never over-emit: unclaimed accrued rewards fit in the reserve; and total claimed + reserve == total funded.
    function invariant_NeverOverEmits() public view {
        assertLe(handler.totalEarned(), staking.rewardReserve());
        assertEq(handler.ghostClaimed() + staking.rewardReserve(), handler.ghostNotified());
    }
}
