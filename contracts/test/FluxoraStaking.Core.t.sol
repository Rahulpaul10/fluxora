// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {FluxoraStaking} from "../src/FluxoraStaking.sol";
import {FluxoraStakingTestBase} from "./FluxoraStaking.Base.t.sol";
import {MockERC20, MockFeeToken} from "./helpers/MockERC20.sol";

contract FluxoraStakingCoreTest is FluxoraStakingTestBase {
    bytes32 internal constant PAUSER = keccak256("PAUSER_ROLE");
    bytes32 internal constant DISTRIBUTOR = keccak256("REWARDS_DISTRIBUTOR_ROLE");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    // ------------------------------------------------------------ constructor
    function test_ConstructorSetsConfigAndRoles() public view {
        assertEq(address(staking.stakingToken()), address(flux));
        assertEq(staking.rewardsDuration(), DURATION);
        assertTrue(staking.hasRole(bytes32(0), admin));
        assertTrue(staking.hasRole(DISTRIBUTOR, distributor));
        assertTrue(staking.hasRole(PAUSER, pauser));
        assertFalse(staking.hasRole(bytes32(0), distributor));
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.MIN_REWARDS_DURATION(), 7 days);
        assertEq(staking.MAX_REWARDS_DURATION(), 365 days);
    }

    function test_RevertConstructorZeroAddresses() public {
        IERC20 t = IERC20(address(flux));
        vm.expectRevert(FluxoraStaking.ZeroAddress.selector);
        new FluxoraStaking(IERC20(address(0)), admin, distributor, pauser, DURATION);
        vm.expectRevert(FluxoraStaking.ZeroAddress.selector);
        new FluxoraStaking(t, address(0), distributor, pauser, DURATION);
        vm.expectRevert(FluxoraStaking.ZeroAddress.selector);
        new FluxoraStaking(t, admin, address(0), pauser, DURATION);
        vm.expectRevert(FluxoraStaking.ZeroAddress.selector);
        new FluxoraStaking(t, admin, distributor, address(0), DURATION);
    }

    function test_RevertConstructorTokenWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(FluxoraStaking.InvalidToken.selector, alice));
        new FluxoraStaking(IERC20(alice), admin, distributor, pauser, DURATION);
    }

    function test_RevertConstructorInvalidDuration() public {
        IERC20 t = IERC20(address(flux));
        vm.expectRevert(abi.encodeWithSelector(FluxoraStaking.InvalidDuration.selector, 7 days - 1));
        new FluxoraStaking(t, admin, distributor, pauser, 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(FluxoraStaking.InvalidDuration.selector, 365 days + 1));
        new FluxoraStaking(t, admin, distributor, pauser, 365 days + 1);
        new FluxoraStaking(t, admin, distributor, pauser, 7 days); // boundaries OK
        new FluxoraStaking(t, admin, distributor, pauser, 365 days);
    }

    // ------------------------------------------------------------ pause
    function test_PauseGatingAndRoles() public {
        vm.prank(pauser);
        staking.pause();
        assertTrue(staking.paused());
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staking.stake(1);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staking.stakeWithPermit(1, block.timestamp, 0, bytes32(0), bytes32(0));
        vm.prank(pauser);
        staking.unpause();
        assertFalse(staking.paused());
    }

    function test_RevertNonPauserPauseUnpause() public {
        vm.prank(alice);
        vm.expectRevert(_unauth(alice, PAUSER));
        staking.pause();
        vm.prank(pauser);
        staking.pause();
        vm.prank(admin);
        vm.expectRevert(_unauth(admin, PAUSER));
        staking.unpause();
    }

    // ------------------------------------------------------------ stake
    function test_StakeMovesTokensAndEmits() public {
        vm.expectEmit(true, false, false, true, address(staking));
        emit FluxoraStaking.Staked(alice, STAKE);
        _stake(alice, STAKE);
        assertEq(staking.balanceOf(alice), STAKE);
        assertEq(staking.totalStaked(), STAKE);
        assertEq(flux.balanceOf(address(staking)), STAKE);
        assertEq(flux.balanceOf(alice), 1_000_000e18 - STAKE);
    }

    function test_RevertStakeZero() public {
        vm.prank(alice);
        vm.expectRevert(FluxoraStaking.ZeroAmount.selector);
        staking.stake(0);
    }

    function test_RevertStakeWithoutAllowance() public {
        address carol = makeAddr("carol");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(staking), 0, 1));
        staking.stake(1);
    }

    function test_RevertStakeFeeOnTransferToken() public {
        MockFeeToken fee = new MockFeeToken();
        FluxoraStaking s = new FluxoraStaking(IERC20(address(fee)), admin, distributor, pauser, DURATION);
        fee.mint(alice, 1000e18);
        fee.setFeeBps(100);
        vm.startPrank(alice);
        fee.approve(address(s), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(FluxoraStaking.UnexpectedTransferAmount.selector, 100e18, 99e18));
        s.stake(100e18);
        vm.stopPrank();
    }

    function _signPermit(uint256 pk, address owner_, uint256 value, uint256 nonce, uint256 deadline)
        internal view returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner_, address(staking), value, nonce, deadline));
        (v, r, s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", flux.DOMAIN_SEPARATOR(), structHash)));
    }

    function test_StakeWithPermitNoPriorApproval() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        vm.prank(treasury);
        flux.transfer(signer, 500e18);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, signer, 200e18, 0, deadline);
        vm.prank(signer);
        staking.stakeWithPermit(200e18, deadline, v, r, s);
        assertEq(staking.balanceOf(signer), 200e18);
        assertEq(flux.nonces(signer), 1);
    }

    function test_StakeWithPermitToleratesConsumedPermitWhenAllowanceExists() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        vm.prank(treasury);
        flux.transfer(signer, 500e18);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, signer, 200e18, 0, deadline);
        flux.permit(signer, address(staking), 200e18, deadline, v, r, s); // front-run / consumed
        vm.prank(signer);
        staking.stakeWithPermit(200e18, deadline, v, r, s);
        assertEq(staking.balanceOf(signer), 200e18);
    }

    function test_RevertStakeWithPermitInvalidSigAndNoAllowance() public {
        (address signer,) = makeAddrAndKey("signer");
        (, uint256 otherPk) = makeAddrAndKey("other");
        vm.prank(treasury);
        flux.transfer(signer, 500e18);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(otherPk, signer, 10e18, 0, deadline);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(staking), 0, 10e18));
        staking.stakeWithPermit(10e18, deadline, v, r, s);
    }

    // ------------------------------------------------------------ withdraw
    function test_WithdrawReturnsPrincipalAndEmits() public {
        _stake(alice, STAKE);
        vm.expectEmit(true, false, false, true, address(staking));
        emit FluxoraStaking.Withdrawn(alice, 40e18);
        vm.prank(alice);
        staking.withdraw(40e18);
        assertEq(staking.balanceOf(alice), 60e18);
        assertEq(staking.totalStaked(), 60e18);
        assertEq(flux.balanceOf(alice), 1_000_000e18 - 60e18);
    }

    function test_RevertWithdrawZero() public {
        _stake(alice, STAKE);
        vm.prank(alice);
        vm.expectRevert(FluxoraStaking.ZeroAmount.selector);
        staking.withdraw(0);
    }

    function test_RevertWithdrawMoreThanStaked() public {
        _stake(alice, STAKE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FluxoraStaking.InsufficientStake.selector, STAKE + 1, STAKE));
        staking.withdraw(STAKE + 1);
    }

    function test_WithdrawWorksWhilePaused() public {
        _stake(alice, STAKE);
        vm.prank(pauser);
        staking.pause();
        vm.prank(alice);
        staking.withdraw(STAKE);
        assertEq(staking.balanceOf(alice), 0);
        assertEq(flux.balanceOf(alice), 1_000_000e18);
    }

    function test_WithdrawWorksWhilePausedWithActiveRewardsAndAfterFinish() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        skip(5 days);
        vm.prank(pauser);
        staking.pause();
        vm.prank(alice);
        staking.withdraw(STAKE / 2);
        skip(40 days);
        vm.prank(alice);
        staking.withdraw(STAKE / 2);
        assertEq(staking.totalStaked(), 0);
    }

    // ------------------------------------------------------------ getReward / exit
    function test_GetRewardPaysAndEmits() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        skip(1 days);
        uint256 expected = 1 days * RATE;
        assertEq(staking.earned(alice), expected);
        vm.expectEmit(true, false, false, true, address(staking));
        emit FluxoraStaking.RewardPaid(alice, expected);
        vm.prank(alice);
        staking.getReward();
        assertEq(flux.balanceOf(alice), 1_000_000e18 - STAKE + expected);
        assertEq(staking.rewards(alice), 0);
        assertEq(staking.rewardReserve(), REWARD - expected);
        assertEq(staking.balanceOf(alice), STAKE);
    }

    function test_GetRewardZeroIsNoop() public {
        _stake(alice, STAKE);
        uint256 before_ = flux.balanceOf(alice);
        vm.prank(alice);
        staking.getReward();
        assertEq(flux.balanceOf(alice), before_);
    }

    function test_GetRewardWorksWhilePaused() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        skip(2 days);
        vm.prank(pauser);
        staking.pause();
        vm.prank(alice);
        staking.getReward();
        assertEq(flux.balanceOf(alice), 1_000_000e18 - STAKE + 2 days * RATE);
    }

    function test_ExitWithdrawsAllAndClaimsEvenWhenPaused() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        skip(3 days);
        vm.prank(pauser);
        staking.pause();
        vm.expectEmit(true, false, false, true, address(staking));
        emit FluxoraStaking.Withdrawn(alice, STAKE);
        vm.expectEmit(true, false, false, true, address(staking));
        emit FluxoraStaking.RewardPaid(alice, 3 days * RATE);
        vm.prank(alice);
        staking.exit();
        assertEq(staking.balanceOf(alice), 0);
        assertEq(staking.totalStaked(), 0);
        assertEq(flux.balanceOf(alice), 1_000_000e18 + 3 days * RATE);
    }

    function test_ExitWithNothingStakedIsNoop() public {
        vm.prank(alice);
        staking.exit();
        assertEq(flux.balanceOf(alice), 1_000_000e18);
    }

    // ------------------------------------------------------------ notifyRewardAmount
    function test_NotifySetsScheduleAndEmits() public {
        _stake(alice, STAKE);
        vm.expectEmit(false, false, false, true, address(staking));
        emit FluxoraStaking.RewardAdded(REWARD);
        _notify(REWARD);
        assertEq(staking.rewardRate(), RATE);
        assertEq(staking.periodFinish(), block.timestamp + DURATION);
        assertEq(staking.lastUpdateTime(), block.timestamp);
        assertEq(staking.rewardReserve(), REWARD);
        assertEq(staking.getRewardForDuration(), REWARD);
        assertEq(flux.balanceOf(address(staking)), STAKE + REWARD);
    }

    function test_NotifyMergesLeftoverIntoNewPeriod() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        skip(10 days);
        _notify(REWARD);
        uint256 leftover = 20 days * RATE;
        assertEq(staking.rewardRate(), (REWARD + leftover) / DURATION);
        assertEq(staking.periodFinish(), block.timestamp + DURATION);
        assertEq(staking.rewardReserve(), 2 * REWARD);
        assertEq(staking.earned(alice), 10 days * RATE);
    }

    function test_RevertNotifyNonDistributor() public {
        _stake(alice, STAKE);
        vm.prank(admin);
        vm.expectRevert(_unauth(admin, DISTRIBUTOR));
        staking.notifyRewardAmount(REWARD);
    }

    function test_RevertNotifyZero() public {
        _stake(alice, STAKE);
        vm.prank(distributor);
        vm.expectRevert(FluxoraStaking.ZeroAmount.selector);
        staking.notifyRewardAmount(0);
    }

    function test_RevertNotifyNoStakers() public {
        vm.prank(distributor);
        vm.expectRevert(FluxoraStaking.NoStakers.selector);
        staking.notifyRewardAmount(REWARD);
    }

    function test_RevertNotifyZeroRate() public {
        _stake(alice, STAKE);
        vm.prank(distributor);
        vm.expectRevert(FluxoraStaking.ZeroRewardRate.selector);
        staking.notifyRewardAmount(DURATION - 1);
    }

    function test_RevertNotifyWithoutAllowance() public {
        _stake(alice, STAKE);
        vm.prank(distributor);
        flux.approve(address(staking), 0);
        vm.prank(distributor);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(staking), 0, REWARD)
        );
        staking.notifyRewardAmount(REWARD);
    }

    function test_RevertNotifyFeeOnTransferToken() public {
        MockFeeToken fee = new MockFeeToken();
        FluxoraStaking s = new FluxoraStaking(IERC20(address(fee)), admin, distributor, pauser, DURATION);
        fee.mint(alice, 1000e18);
        fee.mint(distributor, 1_000_000e18);
        vm.startPrank(alice);
        fee.approve(address(s), type(uint256).max);
        s.stake(100e18); // fee still 0 here
        vm.stopPrank();
        fee.setFeeBps(100);
        vm.startPrank(distributor);
        fee.approve(address(s), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(FluxoraStaking.UnexpectedTransferAmount.selector, 1_000_000e18, 990_000e18)
        );
        s.notifyRewardAmount(1_000_000e18);
        vm.stopPrank();
    }

    function test_RevertWhenTokenBalanceBelowLiabilities() public {
        MockERC20 mock = new MockERC20("M", "M", 18);
        FluxoraStaking s = new FluxoraStaking(IERC20(address(mock)), admin, distributor, pauser, DURATION);
        mock.mint(alice, 1000e18);
        vm.startPrank(alice);
        mock.approve(address(s), type(uint256).max);
        s.stake(100e18);
        vm.stopPrank();
        mock.burn(address(s), 1e18); // simulate external balance loss
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FluxoraStaking.InsufficientTokenBalance.selector, 99e18, 100e18));
        s.getReward();
    }

    // ------------------------------------------------------------ setRewardsDuration
    function test_SetRewardsDurationWhenInactiveEmits() public {
        vm.expectEmit(false, false, false, true, address(staking));
        emit FluxoraStaking.RewardsDurationUpdated(14 days);
        vm.prank(admin);
        staking.setRewardsDuration(14 days);
        assertEq(staking.rewardsDuration(), 14 days);
    }

    function test_SetRewardsDurationAfterPeriodEnds() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        skip(DURATION);
        vm.prank(admin);
        staking.setRewardsDuration(10 days);
        assertEq(staking.rewardsDuration(), 10 days);
    }

    function test_RevertSetRewardsDurationDuringActivePeriod() public {
        _stake(alice, STAKE);
        _notify(REWARD);
        uint256 finish = staking.periodFinish();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(FluxoraStaking.RewardPeriodActive.selector, finish));
        staking.setRewardsDuration(10 days);
    }

    function test_RevertSetRewardsDurationInvalidOrNonAdmin() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(FluxoraStaking.InvalidDuration.selector, 1 days));
        staking.setRewardsDuration(1 days);
        vm.prank(alice);
        vm.expectRevert(_unauth(alice, bytes32(0)));
        staking.setRewardsDuration(10 days);
    }

    // ------------------------------------------------------------ recoverERC20
    function test_RecoverUnrelatedTokenEmits() public {
        MockERC20 other = new MockERC20("O", "O", 18);
        other.mint(address(staking), 50e18);
        vm.expectEmit(true, true, false, true, address(staking));
        emit FluxoraStaking.Recovered(address(other), bob, 50e18);
        vm.prank(admin);
        staking.recoverERC20(address(other), bob, 50e18);
        assertEq(other.balanceOf(bob), 50e18);
    }

    function test_RevertRecoverStakingTokenOrBadArgsOrNonAdmin() public {
        _stake(alice, STAKE);
        vm.startPrank(admin);
        vm.expectRevert(FluxoraStaking.ProtectedToken.selector);
        staking.recoverERC20(address(flux), admin, 1);
        vm.expectRevert(FluxoraStaking.ZeroAddress.selector);
        staking.recoverERC20(address(0), admin, 1);
        vm.expectRevert(FluxoraStaking.ZeroAddress.selector);
        staking.recoverERC20(address(1), address(0), 1);
        vm.expectRevert(FluxoraStaking.ZeroAddress.selector);
        staking.recoverERC20(address(1), address(staking), 1);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(_unauth(alice, bytes32(0)));
        staking.recoverERC20(address(1), alice, 1);
    }
}
