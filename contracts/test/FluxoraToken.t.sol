// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {FluxoraToken} from "../src/FluxoraToken.sol";

contract FluxoraTokenTest is Test {
    FluxoraToken internal token;
    address internal holder = makeAddr("holder");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new FluxoraToken(holder);
    }

    // ---------------------------------------------------------------- deployment
    function test_ConstructorMintsFixedSupplyToHolder() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.name(), "FLUXORA");
        assertEq(token.symbol(), "FLUX");
        assertEq(token.decimals(), 18);
    }

    function test_ConstructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), alice, SUPPLY);
        new FluxoraToken(alice);
    }

    function test_RevertConstructorZeroHolder() public {
        vm.expectRevert(FluxoraToken.ZeroInitialHolder.selector);
        new FluxoraToken(address(0));
    }

    // ---------------------------------------------------------------- clock
    function test_ClockIsTimestamp() public {
        assertEq(token.clock(), uint48(block.timestamp));
        assertEq(token.CLOCK_MODE(), "mode=timestamp");
        skip(1234);
        assertEq(token.clock(), uint48(block.timestamp));
    }

    // ---------------------------------------------------------------- transfer / burn
    function test_TransferMovesBalance() public {
        vm.prank(holder);
        token.transfer(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(holder), SUPPLY - 100e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertTransferInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_BurnReducesSupplyAndBalance() public {
        vm.prank(holder);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(holder, address(0), 10e18);
        token.burn(10e18);
        assertEq(token.totalSupply(), SUPPLY - 10e18);
        assertEq(token.balanceOf(holder), SUPPLY - 10e18);
    }

    function test_RevertBurnMoreThanBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.burn(1);
    }

    function test_BurnFromUsesAllowance() public {
        vm.prank(holder);
        token.approve(alice, 50e18);
        vm.prank(alice);
        token.burnFrom(holder, 30e18);
        assertEq(token.totalSupply(), SUPPLY - 30e18);
        assertEq(token.allowance(holder, alice), 20e18);
    }

    function test_RevertBurnFromWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.burnFrom(holder, 1);
    }

    function testFuzz_SupplyOnlyDecreasesByBurn(uint256 sent, uint256 burned) public {
        sent = bound(sent, 0, SUPPLY);
        burned = bound(burned, 0, sent);
        vm.prank(holder);
        token.transfer(alice, sent);
        vm.prank(alice);
        token.burn(burned);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertEq(token.balanceOf(alice) + token.balanceOf(holder), SUPPLY - burned);
    }

    // ---------------------------------------------------------------- permit
    function _permitSig(uint256 pk, address owner_, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal view returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    function test_PermitSetsAllowanceAndBumpsNonce() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(pk, signer, alice, 77e18, 0, deadline);
        token.permit(signer, alice, 77e18, deadline, v, r, s);
        assertEq(token.allowance(signer, alice), 77e18);
        assertEq(token.nonces(signer), 1);
    }

    function test_RevertPermitReplay() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(pk, signer, alice, 1, 0, deadline);
        token.permit(signer, alice, 1, deadline, v, r, s);
        vm.expectRevert();
        token.permit(signer, alice, 1, deadline, v, r, s);
    }

    function test_RevertPermitExpired() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(pk, signer, alice, 1, 0, deadline);
        skip(1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(signer, alice, 1, deadline, v, r, s);
    }

    function test_RevertPermitWrongSigner() public {
        (address signer,) = makeAddrAndKey("signer");
        (, uint256 otherPk) = makeAddrAndKey("other");
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(otherPk, signer, alice, 1, 0, deadline);
        vm.expectRevert();
        token.permit(signer, alice, 1, deadline, v, r, s);
    }

    // ---------------------------------------------------------------- votes / delegation
    function test_NoVotesUntilDelegated() public view {
        assertEq(token.getVotes(holder), 0);
        assertEq(token.delegates(holder), address(0));
    }

    function test_DelegateActivatesVotesAndEmits() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IVotes.DelegateChanged(holder, address(0), alice);
        vm.expectEmit(true, false, false, true, address(token));
        emit IVotes.DelegateVotesChanged(alice, 0, SUPPLY);
        vm.prank(holder);
        token.delegate(alice);
        assertEq(token.getVotes(alice), SUPPLY);
        assertEq(token.delegates(holder), alice);
    }

    function test_TransferMovesVotesBetweenDelegates() public {
        vm.prank(holder);
        token.delegate(holder);
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(holder);
        token.transfer(alice, 40e18);
        assertEq(token.getVotes(alice), 40e18);
        assertEq(token.getVotes(holder), SUPPLY - 40e18);
    }

    function test_BurnReducesVotesAndPastTotalSupplyCheckpoint() public {
        vm.prank(holder);
        token.delegate(holder);
        uint256 t0 = block.timestamp;
        skip(10);
        vm.prank(holder);
        token.burn(5e18);
        skip(10);
        assertEq(token.getVotes(holder), SUPPLY - 5e18);
        assertEq(token.getPastVotes(holder, t0 + 5), SUPPLY);
        assertEq(token.getPastTotalSupply(t0 + 5), SUPPLY);
        assertEq(token.getPastTotalSupply(t0 + 15), SUPPLY - 5e18);
    }

    function test_PastVotesUseTimestampClock() public {
        vm.prank(holder);
        token.delegate(alice);
        uint256 t = block.timestamp;
        skip(100);
        assertEq(token.getPastVotes(alice, t), SUPPLY);
        assertEq(token.getPastVotes(alice, t - 1), 0);
    }

    function test_RevertPastVotesFuture() public {
        vm.expectRevert();
        token.getPastVotes(alice, block.timestamp + 1);
    }

    function test_DelegateBySig() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        vm.prank(holder);
        token.transfer(signer, 9e18);
        uint256 expiry = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, bob, 0, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        token.delegateBySig(bob, 0, expiry, v, r, s);
        assertEq(token.delegates(signer), bob);
        assertEq(token.getVotes(bob), 9e18);
        assertEq(token.nonces(signer), 1);
    }

    function test_RevertDelegateBySigExpired() public {
        (, uint256 pk) = makeAddrAndKey("signer");
        uint256 expiry = block.timestamp + 1;
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, bob, 0, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        skip(2);
        vm.expectRevert(abi.encodeWithSelector(IVotes.VotesExpiredSignature.selector, expiry));
        token.delegateBySig(bob, 0, expiry, v, r, s);
    }

    function testFuzz_DelegatedVotesEqualBalances(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY / 2);
        b = bound(b, 0, SUPPLY / 2);
        vm.startPrank(holder);
        token.transfer(alice, a);
        token.transfer(bob, b);
        token.delegate(holder);
        vm.stopPrank();
        vm.prank(alice);
        token.delegate(bob);
        vm.prank(bob);
        token.delegate(bob);
        assertEq(token.getVotes(holder), SUPPLY - a - b);
        assertEq(token.getVotes(bob), a + b);
        assertEq(token.getVotes(holder) + token.getVotes(bob), token.totalSupply());
    }
}

contract FluxoraTokenHandler is Test {
    FluxoraToken public token;
    address[] public actors;
    uint256 public burned;

    constructor(FluxoraToken token_, address holder_) {
        token = token_;
        actors.push(holder_);
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA401));
    }

    function actorCount() external view returns (uint256) { return actors.length; }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function burn(uint256 seed, uint256 amount) external {
        address from = actors[seed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.burn(amount);
        burned += amount;
    }

    function delegate(uint256 seed, uint256 toSeed) external {
        vm.prank(actors[seed % actors.length]);
        token.delegate(actors[toSeed % actors.length]);
    }
}

contract FluxoraTokenInvariantTest is Test {
    FluxoraToken internal token;
    FluxoraTokenHandler internal handler;
    address internal holder = makeAddr("holder");

    function setUp() public {
        token = new FluxoraToken(holder);
        handler = new FluxoraTokenHandler(token, holder);
        // The handler's first actor must be the initial holder.
        targetContract(address(handler));
    }

    function invariant_SupplyIsInitialMinusBurned() public view {
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY() - handler.burned());
    }

    function invariant_SupplyEqualsSumOfBalances() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) sum += token.balanceOf(handler.actors(i));
        assertEq(sum, token.totalSupply());
    }

    function invariant_VotesNeverExceedSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) sum += token.getVotes(handler.actors(i));
        assertLe(sum, token.totalSupply());
    }
}
