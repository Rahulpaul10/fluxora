// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {FluxoraToken, FLUXORA_INITIAL_SUPPLY} from "../src/FluxoraToken.sol";
import {FluxoraTimelock} from "../src/FluxoraTimelock.sol";
import {FluxoraGovernance} from "../src/FluxoraGovernance.sol";
import {FluxoraPayments} from "../src/FluxoraPayments.sol";
import {FluxoraStaking, FLUXORA_MIN_REWARDS_DURATION, FLUXORA_MAX_REWARDS_DURATION}
    from "../src/FluxoraStaking.sol";

/// @title FLUXORA deployment script for Arc mainnet and testnet
/// @notice Uses Foundry's command-line keystore/account or hardware-wallet signer; never reads a private key.
/// @dev Creates governance before applications and renounces the broadcaster's temporary timelock admin.
///      This script only describes deployment; writing it does not broadcast any transaction.
contract DeployFluxora is Script {
    address private constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    struct Config {
        address broadcaster;
        address initialHolder;
        address rewardsDistributor;
        address pauser;
        address eurc;
        uint256 timelockDelay;
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumPercent;
        uint256 rewardsDuration;
    }

    struct Deployment {
        FluxoraToken token;
        FluxoraTimelock timelock;
        FluxoraGovernance governor;
        FluxoraPayments payments;
        FluxoraStaking staking;
    }

    error UnsupportedChain(uint256 chainId);
    error InvalidConfiguration();
    error ProposalThresholdTooHigh(uint256 value, uint256 maximum);
    error InvalidQuorumPercent(uint256 value, uint256 minimum, uint256 maximum);
    error VotingPeriodTooShort(uint256 value, uint256 minimum);
    error TimelockDelayTooShort(uint256 value, uint256 minimum);
    error InvalidRewardsDuration(uint256 value, uint256 minimum, uint256 maximum);
    error MissingDeploymentRole(address target, bytes32 role, address account);
    error UnexpectedGovernorTimelock(address governor, address actual, address expected);
    error UsdcHasNoCode(address token);
    error InvalidUsdcMetadata(address token, bytes4 selector, bytes returnedData);
    error UnexpectedUsdcSymbol(address token, string symbol, string expected);
    error UnexpectedUsdcDecimals(address token, uint256 decimals, uint256 expected);

    /// @notice Deploy the suite using the configured Foundry broadcaster and optional environment overrides.
    function run() external {
        if (block.chainid != 5042 && block.chainid != 5042002) revert UnsupportedChain(block.chainid);
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        vm.stopBroadcast();
        Config memory config = _configuration(broadcaster);
        vm.startBroadcast();
        Deployment memory deployed;
        deployed.token = new FluxoraToken(config.initialHolder);
        address[] memory empty = new address[](0);
        deployed.timelock = new FluxoraTimelock(config.timelockDelay, empty, empty, broadcaster);
        deployed.governor = new FluxoraGovernance(
            IVotes(address(deployed.token)), deployed.timelock, config.votingDelay, config.votingPeriod,
            config.proposalThreshold, config.quorumPercent
        );
        deployed.timelock.grantRole(deployed.timelock.PROPOSER_ROLE(), address(deployed.governor));
        deployed.timelock.grantRole(deployed.timelock.CANCELLER_ROLE(), address(deployed.governor));
        deployed.timelock.grantRole(deployed.timelock.EXECUTOR_ROLE(), address(0));

        address[] memory tokens = new address[](config.eurc == address(0) ? 2 : 3);
        tokens[0] = ARC_USDC;
        tokens[1] = address(deployed.token);
        if (config.eurc != address(0)) tokens[2] = config.eurc;
        deployed.payments = new FluxoraPayments(address(deployed.timelock), config.pauser, tokens);
        deployed.staking = new FluxoraStaking(
            IERC20(address(deployed.token)), address(deployed.timelock), config.rewardsDistributor,
            config.pauser, config.rewardsDuration
        );
        _assertDeployment(deployed);
        deployed.timelock.renounceRole(deployed.timelock.DEFAULT_ADMIN_ROLE(), broadcaster);
        vm.stopBroadcast();
        _log(config, deployed);
    }

    function _configuration(address broadcaster) private view returns (Config memory config) {
        config.broadcaster = broadcaster;
        config.initialHolder = vm.envOr("FLUX_INITIAL_HOLDER", broadcaster);
        config.timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(2 days));
        config.votingDelay = SafeCast.toUint48(vm.envOr("VOTING_DELAY", uint256(1 days)));
        uint256 votingPeriod = vm.envOr("VOTING_PERIOD", uint256(3 days));
        if (votingPeriod < 1 hours) revert VotingPeriodTooShort(votingPeriod, 1 hours);
        config.votingPeriod = SafeCast.toUint32(votingPeriod);
        config.proposalThreshold = vm.envOr("PROPOSAL_THRESHOLD", uint256(1_000_000e18));
        config.quorumPercent = vm.envOr("QUORUM_PERCENT", uint256(4));
        config.rewardsDuration = vm.envOr("STAKING_REWARDS_DURATION", uint256(30 days));
        config.rewardsDistributor = vm.envOr("REWARDS_DISTRIBUTOR", broadcaster);
        config.pauser = vm.envOr("PAUSER", broadcaster);
        config.eurc = vm.envOr("EURC_ADDRESS", address(0));
        if (config.proposalThreshold > FLUXORA_INITIAL_SUPPLY) {
            revert ProposalThresholdTooHigh(config.proposalThreshold, FLUXORA_INITIAL_SUPPLY);
        }
        if (config.quorumPercent < 1 || config.quorumPercent > 100) {
            revert InvalidQuorumPercent(config.quorumPercent, 1, 100);
        }
        if (config.timelockDelay < 1 hours) revert TimelockDelayTooShort(config.timelockDelay, 1 hours);
        if (config.rewardsDuration < FLUXORA_MIN_REWARDS_DURATION
            || config.rewardsDuration > FLUXORA_MAX_REWARDS_DURATION) {
            revert InvalidRewardsDuration(config.rewardsDuration, FLUXORA_MIN_REWARDS_DURATION,
                FLUXORA_MAX_REWARDS_DURATION);
        }
        if (broadcaster == address(0) || config.initialHolder == address(0)
            || config.rewardsDistributor == address(0) || config.pauser == address(0)
            || (config.eurc != address(0) && config.eurc.code.length == 0)) {
            revert InvalidConfiguration();
        }
        _checkUsdc();
    }

    function _checkUsdc() private view {
        if (ARC_USDC.code.length == 0) revert UsdcHasNoCode(ARC_USDC);
        bytes4 symbolSelector = bytes4(keccak256("symbol()"));
        (bool symbolSuccess, bytes memory symbolData) = ARC_USDC.staticcall(abi.encodeWithSelector(symbolSelector));
        if (!symbolSuccess) revert InvalidUsdcMetadata(ARC_USDC, symbolSelector, symbolData);
        try this.decodeUsdcSymbol(symbolData) returns (string memory symbol) {
            if (keccak256(symbolData) != keccak256(abi.encode(symbol))) {
                revert InvalidUsdcMetadata(ARC_USDC, symbolSelector, symbolData);
            }
            if (keccak256(bytes(symbol)) != keccak256(bytes("USDC"))) {
                revert UnexpectedUsdcSymbol(ARC_USDC, symbol, "USDC");
            }
        } catch {
            revert InvalidUsdcMetadata(ARC_USDC, symbolSelector, symbolData);
        }
        bytes4 decimalsSelector = bytes4(keccak256("decimals()"));
        (bool decimalsSuccess, bytes memory decimalsData) = ARC_USDC.staticcall(abi.encodeWithSelector(decimalsSelector));
        if (!decimalsSuccess || decimalsData.length != 32) {
            revert InvalidUsdcMetadata(ARC_USDC, decimalsSelector, decimalsData);
        }
        uint256 decimals = abi.decode(decimalsData, (uint256));
        if (decimals != 6) revert UnexpectedUsdcDecimals(ARC_USDC, decimals, 6);
    }

    /// @dev External decoding boundary lets malformed symbol return data be caught as a custom error.
    function decodeUsdcSymbol(bytes calldata data) external pure returns (string memory) {
        return abi.decode(data, (string));
    }

    function _assertDeployment(Deployment memory deployed) private view {
        address timelock = address(deployed.timelock);
        address governor = address(deployed.governor);
        bytes32 proposerRole = deployed.timelock.PROPOSER_ROLE();
        if (!deployed.timelock.hasRole(proposerRole, governor)) {
            revert MissingDeploymentRole(timelock, proposerRole, governor);
        }
        bytes32 cancellerRole = deployed.timelock.CANCELLER_ROLE();
        if (!deployed.timelock.hasRole(cancellerRole, governor)) {
            revert MissingDeploymentRole(timelock, cancellerRole, governor);
        }
        bytes32 executorRole = deployed.timelock.EXECUTOR_ROLE();
        if (!deployed.timelock.hasRole(executorRole, address(0))) {
            revert MissingDeploymentRole(timelock, executorRole, address(0));
        }
        bytes32 paymentsAdminRole = deployed.payments.DEFAULT_ADMIN_ROLE();
        if (!deployed.payments.hasRole(paymentsAdminRole, timelock)) {
            revert MissingDeploymentRole(address(deployed.payments), paymentsAdminRole, timelock);
        }
        bytes32 stakingAdminRole = deployed.staking.DEFAULT_ADMIN_ROLE();
        if (!deployed.staking.hasRole(stakingAdminRole, timelock)) {
            revert MissingDeploymentRole(address(deployed.staking), stakingAdminRole, timelock);
        }
        address governorTimelock = deployed.governor.timelock();
        if (governorTimelock != timelock) {
            revert UnexpectedGovernorTimelock(governor, governorTimelock, timelock);
        }
    }

    function _log(Config memory config, Deployment memory deployed) private pure {
        console.log("FluxoraToken", address(deployed.token));
        console.log("FluxoraTimelock", address(deployed.timelock));
        console.log("FluxoraGovernance", address(deployed.governor));
        console.log("FluxoraPayments", address(deployed.payments));
        console.log("FluxoraStaking", address(deployed.staking));
        console.log("FLUX initial holder (no admin role)", config.initialHolder);
        console.log("Timelock DEFAULT_ADMIN_ROLE (self only)", address(deployed.timelock));
        console.log("Timelock PROPOSER_ROLE", address(deployed.governor));
        console.log("Timelock CANCELLER_ROLE", address(deployed.governor));
        console.log("Timelock EXECUTOR_ROLE (open execution)", address(0));
        console.log("Payments DEFAULT_ADMIN_ROLE", address(deployed.timelock));
        console.log("Payments PAUSER_ROLE", config.pauser);
        console.log("Staking DEFAULT_ADMIN_ROLE", address(deployed.timelock));
        console.log("Staking REWARDS_DISTRIBUTOR_ROLE", config.rewardsDistributor);
        console.log("Staking PAUSER_ROLE", config.pauser);
        console.log("Broadcaster timelock DEFAULT_ADMIN_ROLE renounced", config.broadcaster);
        console.log("Payments supported USDC", ARC_USDC);
        console.log("Payments supported FLUX", address(deployed.token));
        if (config.eurc != address(0)) console.log("Payments supported EURC", config.eurc);
    }
}
