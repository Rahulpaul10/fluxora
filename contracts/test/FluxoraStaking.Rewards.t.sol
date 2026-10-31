// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FluxoraStakingTestBase} from "./FluxoraStaking.Base.t.sol";

contract FluxoraStakingRewardsTest is FluxoraStakingTestBase {
    // Tokens are 1e18-scaled and emissions are whole multiples of 1e18, so with equal/round
    // stakes rewards are exact; a few wei of tolerance guards the unequal-share cases.
    uint256 internal constant DUST = 1e3;

    function test_SingleStakerEarnsLinearly() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        skip(7 days);
        assertEq(staking.earned(alice), 7 days * RATE);
        skip(DURATION); // way past the end
        assertEq(staking.earned(alice), REWARD);
        assertEq(staking.lastTimeRewardApplicable(), staking.periodFinish());
    }

    function test_NoRewardsAccrueAfterPeriodFinish() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        skip(DURATION + 100 days);
        assertEq(staking.earned(alice), REWARD);
        vm.prank(alice);
        staking.getReward();
        skip(10 days);
        assertEq(staking.earned(alice), 0);
    }

    function test_TwoStakersEqualJoinMidway() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        skip(10 days);
        _stake(bob, STAKE);
        skip(20 days);
        // alice: 10d solo + 20d shared half; bob: 20d shared half
        assertApproxEqAbs(staking.earned(alice), 20 days * RATE, DUST);
        assertApproxEqAbs(staking.earned(bob), 10 days * RATE, DUST);
        assertLe(staking.earned(alice) + staking.earned(bob), REWARD);
    }

    function test_TwoStakersProportionalToStake() public {
        _stake(alice, 100e18);
        _stake(bob, 300e18);
        _notify(REWARD);
        skip(DURATION);
        assertApproxEqAbs(staking.earned(alice), REWARD / 4, DUST);
        assertApproxEqAbs(staking.earned(bob), (REWARD * 3) / 4, DUST);
        assertLe(staking.earned(alice) + staking.earned(bob), REWARD);
    }

    function test_LateJoinerGetsNothingForPastTime() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        skip(15 days);
        _stake(bob, STAKE);
        assertEq(staking.earned(bob), 0);
        assertEq(staking.userRewardPerTokenPaid(bob), staking.rewardPerTokenStored());
    }

    function test_PartialWithdrawKeepsAccruedAndReducesFutureShare() public {
        _stake(alice, 200e18);
        _stake(bob, 200e18);
        _notify(REWARD);
        skip(10 days);
        vm.prank(alice);
        staking.withdraw(100e18); // alice now 100 vs bob 200
        uint256 aliceAtWithdraw = staking.earned(alice);
        assertApproxEqAbs(aliceAtWithdraw, 5 days * RATE, DUST);
        skip(20 days);
        // remaining 20d split 1:2
        assertApproxEqAbs(staking.earned(alice), aliceAtWithdraw + (20 days * RATE) / 3, DUST);
        assertApproxEqAbs(staking.earned(bob), 5 days * RATE + (20 days * RATE * 2) / 3, DUST);
    }

    function test_RewardsSurviveStakeTopUp() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        skip(10 days);
        _stake(alice, STAKE); // top-up settles first
        assertEq(staking.earned(alice), 10 days * RATE);
        skip(20 days);
        assertEq(staking.earned(alice), REWARD);
    }

    // ------------------------------------------------------------ zero-stake interval
    function test_ZeroStakeIntervalDefersEmissionsInsteadOfLosingThem() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        uint256 start = block.timestamp;
        skip(10 days);
        vm.prank(alice);
        staking.exit();
        uint256 aliceReward = 10 days * RATE;
        assertEq(flux.balanceOf(alice), 1_000_000e18 + aliceReward);
        assertEq(staking.totalStaked(), 0);

        skip(5 days); // nobody staked
        _stake(bob, STAKE);
        // period pushed back by exactly the empty interval
        assertEq(staking.periodFinish(), start + DURATION + 5 days);
        assertEq(staking.earned(bob), 0);

        skip(20 days);
        assertApproxEqAbs(staking.earned(bob), 20 days * RATE, DUST);
        vm.prank(bob);
        staking.exit();
        // Emissions never exceed the funded amount and (up to dust) none was lost.
        uint256 paid = aliceReward + (flux.balanceOf(bob) - 1_000_000e18);
        assertLe(paid, REWARD);
        assertApproxEqAbs(paid, REWARD, DUST);
        assertLe(staking.rewardReserve(), DUST); // only dust left reserved
    }

    function test_ZeroStakeFromStartDefersWholePeriodPastOriginalFinish() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        vm.prank(alice);
        staking.withdraw(STAKE); // zero stake right away
        skip(40 days); // beyond the original finish
        _stake(bob, STAKE);
        assertEq(staking.periodFinish(), block.timestamp + DURATION);
        skip(DURATION);
        assertApproxEqAbs(staking.earned(bob), REWARD, DUST);
        assertLe(staking.earned(bob), REWARD);
    }

    function test_NoEmissionWhileZeroStake() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        vm.prank(alice);
        staking.withdraw(STAKE);
        uint256 rpt = staking.rewardPerToken();
        skip(3 days);
        assertEq(staking.rewardPerToken(), rpt);
        assertEq(staking.earned(alice), 0);
    }

    function test_ZeroStakeAfterPeriodEndedDoesNotExtendFinish() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        uint256 finish = staking.periodFinish();
        skip(DURATION + 1 days);
        vm.prank(alice);
        staking.exit();
        skip(3 days);
        _stake(bob, STAKE);
        assertEq(staking.periodFinish(), finish);
        skip(10 days);
        assertEq(staking.earned(bob), 0);
    }

    function test_NewNotifyAfterZeroStakeResumesNormally() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        skip(DURATION);
        vm.prank(alice);
        staking.exit();
        _stake(bob, STAKE);
        _notify(REWARD);
        skip(DURATION);
        assertEq(staking.earned(bob), REWARD);
    }

    // ------------------------------------------------------------ fuzz
    function testFuzz_SingleStakerAccrual(uint256 stake_, uint256 reward, uint256 elapsed) public {
        stake_ = bound(stake_, 1e6, 1e26);
        reward = bound(reward, DURATION, 1e26);
        elapsed = bound(elapsed, 0, DURATION);
        vm.prank(treasury);
        flux.transfer(alice, stake_);
        _stake(alice, stake_);
        _notify(reward);
        uint256 rate = staking.rewardRate();
        skip(elapsed);
        uint256 e = staking.earned(alice);
        assertLe(e, rate * elapsed); // never over-emit
        assertLe(rate * elapsed - e, stake_ / 1e18 + 1); // only rounding dust lost
        assertLe(e, reward);
        vm.prank(alice);
        staking.exit();
        assertEq(staking.totalStaked(), 0);
        assertGe(flux.balanceOf(address(staking)), staking.rewardReserve());
    }

    function testFuzz_TwoStakersNeverOverEmitAndShareProportionally(uint256 a, uint256 b, uint256 reward, uint256 t1)
        public
    {
        a = bound(a, 1e18, 1e24);
        b = bound(b, 1e18, 1e24);
        reward = bound(reward, DURATION, 1e26);
        t1 = bound(t1, 0, DURATION);
        vm.startPrank(treasury);
        flux.transfer(alice, a);
        flux.transfer(bob, b);
        vm.stopPrank();
        _stake(alice, a);
        _stake(bob, b);
        _notify(reward);
        skip(t1);
        uint256 rate = staking.rewardRate();
        uint256 ea = staking.earned(alice);
        uint256 eb = staking.earned(bob);
        assertLe(ea + eb, rate * t1);
        assertLe(rate * t1 - (ea + eb), (a + b) / 1e18 + 3); // dust only
        // proportionality: ea/a ≈ eb/b (cross-multiplied, tolerance for floor rounding)
        uint256 lhs = ea * b;
        uint256 rhs = eb * a;
        uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        assertLe(diff, (a + b) + 1);
        skip(DURATION);
        assertLe(staking.earned(alice) + staking.earned(bob), reward);
    }

    function testFuzz_ZeroStakeGapNeverLosesEmissions(uint256 first, uint256 gap) public {
        first = bound(first, 1, DURATION - 1);
        gap = bound(gap, 1, 400 days);
        _stake(alice, STAKE);
        _notify(REWARD);
        skip(first);
        vm.prank(alice);
        staking.exit();
        skip(gap);
        _stake(bob, STAKE);
        skip(DURATION);
        uint256 total = staking.rewards(alice) + (flux.balanceOf(alice) - 1_000_000e18) + staking.earned(bob);
        assertLe(total, REWARD);
        assertApproxEqAbs(total, REWARD, DUST);
    }
}
