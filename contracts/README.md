# FLUXORA smart contracts

Solidity 0.8.28, OpenZeppelin 5.6.1, Foundry. These are FLUXORA's own contracts. **Nothing here is deployed.** There are no
contract addresses in this repository, and the deployment script never runs on its own.

```
contracts/
  src/
    FluxoraToken.sol        FLUX, fixed-supply ERC-20 (burn, permit, voting)
    FluxoraPayments.sol     direct payments, payment requests, receipts
    FluxoraStaking.sol      stake FLUX, earn FLUX rewards
    FluxoraGovernance.sol   token-voting governor
    FluxoraTimelock.sol     timelock that executes passed proposals
  test/                     unit, fuzz and invariant tests (+ test/helpers mocks)
  script/DeployFluxora.s.sol  deployment script
  deployments/              your own record of deployed addresses (empty until you deploy)
  foundry.toml
```

## Contracts

| Contract | What it does |
| --- | --- |
| `FluxoraToken` | 1,000,000,000 FLUX minted once to the initial holder. Burnable, EIP-2612 permit, voting power with a timestamp clock. No mint function, no owner. |
| `FluxoraPayments` | `pay`, `createRequest`, `payRequest`, `cancelRequest`. Direct transfers from payer to recipient (it never holds funds), per-user receipt and request indexes, token allowlist, optional fee on top capped at 1%, pausable. |
| `FluxoraStaking` | Stake FLUX and earn FLUX. Rewards are pulled in by the rewards distributor so they are always fully funded. Withdraw and claim keep working while paused. Emissions are never lost while nobody is staked. |
| `FluxoraGovernance` | OpenZeppelin Governor (settings, simple counting, votes, quorum fraction, timelock control). |
| `FluxoraTimelock` | OpenZeppelin TimelockController with a 14-day execution window: a queued operation that is not executed within 14 days after it becomes ready can no longer be executed. |

After deployment the timelock owns the admin roles of Payments and Staking, so fees, token allowlist and reward settings change
only through a governance vote. The deployer keeps no lasting admin role.

## Build and test

From the repository root or from this folder (both have a `foundry.toml`):

```bash
# one time: dependencies
bun install                                 # OpenZeppelin comes from node_modules
forge install foundry-rs/forge-std          # test library, installs into ../lib (root of the repo)

cd contracts
forge build
forge test                                  # unit, fuzz and invariant tests
forge test --match-contract FluxoraStaking  # a subset
```

## Deploy (you do this, from your own wallet)

See [`../docs/DEPLOYMENT.md`](../docs/DEPLOYMENT.md) for the full walkthrough. In short:

```bash
cast wallet import fluxora-deployer --interactive     # encrypted keystore, never a raw key on the command line

# 1. simulate only (nothing is sent)
forge script script/DeployFluxora.s.sol:DeployFluxora --rpc-url $ARC_RPC_URL --account fluxora-deployer

# 2. broadcast (only after testnet rehearsal, an independent audit, and a careful review)
forge script script/DeployFluxora.s.sol:DeployFluxora --rpc-url $ARC_RPC_URL --account fluxora-deployer --broadcast
```

The script accepts only chain ids 5042 (Arc mainnet) and 5042002 (Arc Testnet) and checks that the USDC predeploy reports the
symbol `USDC` with 6 decimals before it deploys anything.

Afterwards, from the repository root:

```bash
bun run deploy:record        # writes contracts/deployments/arc-mainnet.json and prints the .env lines
```

## Verify on the explorer

Use the verification method that the Arc explorer (https://explorer.arc.io) offers on a contract's page. The inputs are always
the same. Generate the Standard JSON input for a contract, then submit it with the compiler settings from `foundry.toml`
(solc 0.8.28, optimizer on with 200 runs, EVM `cancun`):

```bash
forge verify-contract --show-standard-json-input <DEPLOYED_ADDRESS> src/FluxoraToken.sol:FluxoraToken > token.standard-json.json
```

Constructor arguments (ABI encoded) for each contract:

```bash
cast abi-encode "constructor(address)" <INITIAL_HOLDER>                                   # FluxoraToken
cast abi-encode "constructor(uint256,address[],address[],address)" <DELAY> "[]" "[]" <DEPLOYER>  # FluxoraTimelock
```

Payments, Staking and Governance take addresses and numbers printed by the deployment script; read the exact values from
`broadcast/DeployFluxora.s.sol/<chainId>/run-latest.json` (`arguments` for each transaction). If the explorer supports
`forge verify-contract` with a verifier URL, use `--verifier` and `--verifier-url` from the explorer's own documentation.

## Safety notes

- Mainnet transactions are real and irreversible. Rehearse on Arc Testnet, get an independent audit, and review every parameter.
- Never commit private keys, seed phrases or keystore passwords. `.gitignore` already excludes `.env*` and `broadcast/`.
- Arc specifics: gas is USDC, `maxFeePerGas` has a 20 gwei floor, USDC blocklisting can make a transfer revert, and blocks arrive about every half second, so all timing in these contracts uses `block.timestamp`.
