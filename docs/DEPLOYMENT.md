# Deploying the FLUXORA contracts

> Prefer deploying by hand from Remix with your own wallet? Follow `docs/REMIX_DEPLOYMENT.md` (self-contained sources in `contracts/remix/`). The Foundry steps below do the same thing in one script.


You deploy these contracts yourself, from your own wallet. Arc Studio does not deploy to, sign for, or fund anything on mainnet,
and this repository contains no deployed addresses. Deployments are irreversible and move real funds. Do the whole process on
Arc Testnet first (chain id 5042002), get an independent professional audit, and review every address and parameter before you
broadcast on mainnet (chain id 5042).

## What gets deployed

| Contract | File | Role |
| --- | --- | --- |
| `FluxoraToken` | `contracts/src/FluxoraToken.sol` | FLUX, fixed supply of 1,000,000,000, burn, permit, voting. No mint, no owner. |
| `FluxoraTimelock` | `contracts/src/FluxoraTimelock.sol` | Timelock with a 14-day execution window. Owns the admin roles of Payments and Staking. |
| `FluxoraGovernance` | `contracts/src/FluxoraGovernance.sol` | Token-voting governor (timestamp clock). The only proposer on the timelock. |
| `FluxoraPayments` | `contracts/src/FluxoraPayments.sol` | Payments, payment requests, receipts. Never holds user funds. Optional fee, capped at 1%. |
| `FluxoraStaking` | `contracts/src/FluxoraStaking.sol` | Stake FLUX, earn FLUX rewards funded by the rewards distributor. |

`contracts/script/DeployFluxora.s.sol` deploys all five in order, wires the roles, and removes the deployer's temporary timelock
admin role. It only runs on chain 5042 or 5042002, and it checks that the USDC predeploy reports `USDC` with 6 decimals.

## 1. Prerequisites

- Foundry (`forge`, `cast`). Arc Foundry is recommended: https://docs.arc.io/arc/tutorials/install-arc-foundry.md
- Dependencies: `bun install` and `bun run setup:contracts` (installs forge-std without git submodules).
- A funded deployer wallet on Arc. Gas is paid in USDC.
- A hardware wallet or an encrypted Foundry keystore. **Never pass a private key on the command line or put one in a file.**

```bash
cast wallet import fluxora-deployer --interactive      # prompts for the key and a password; stored encrypted
```

## 2. Configure the run

Find the Arc RPC URL in `src/config/networks.ts` (it comes from the built-in registry) or in the Arc docs, then:

```bash
export ARC_RPC_URL=<Arc RPC URL>

# Optional overrides (defaults in brackets)
export FLUX_INITIAL_HOLDER=<address that receives the 1B FLUX>      # [the deployer]
export TIMELOCK_DELAY=172800                                          # [2 days, seconds]
export VOTING_DELAY=86400                                             # [1 day]
export VOTING_PERIOD=259200                                           # [3 days]
export PROPOSAL_THRESHOLD=1000000000000000000000000                   # [1,000,000 FLUX]
export QUORUM_PERCENT=4                                               # [4]
export STAKING_REWARDS_DURATION=2592000                               # [30 days]
export REWARDS_DISTRIBUTOR=<address allowed to fund staking rewards>  # [the deployer]
export PAUSER=<address allowed to pause Payments and Staking>         # [the deployer]
export EURC_ADDRESS=<EURC address from docs.arc.io contract addresses> # [none]
```

The script checks these values before it sends anything and reverts with a named error if one is unsafe:
`PROPOSAL_THRESHOLD` must not exceed the 1B FLUX supply (otherwise nobody could ever propose),
`QUORUM_PERCENT` must be 1 to 100, `VOTING_PERIOD` and `TIMELOCK_DELAY` must be at least 1 hour,
and `STAKING_REWARDS_DURATION` must be 7 to 365 days. Before the deployer gives up its temporary
timelock admin role, the script also confirms the governance roles and the timelock's admin role on
Payments and Staking, so a half-wired deployment reverts instead of ending up locked.

## 3. Test and rehearse

```bash
forge build
forge test                                      # run all contract tests

# Simulation only: no --broadcast, nothing is sent
forge script contracts/script/DeployFluxora.s.sol:DeployFluxora --rpc-url $ARC_RPC_URL --account fluxora-deployer
```

Read the printed addresses and role table. Confirm the deployer holds no lasting admin role.

## 4. Broadcast (only when you are ready)

```bash
forge script contracts/script/DeployFluxora.s.sol:DeployFluxora --rpc-url $ARC_RPC_URL --account fluxora-deployer --broadcast
```

Arc enforces a minimum `maxFeePerGas` of 20 gwei. If a transaction is rejected as underpriced, retry with a gas price of at
least 20 gwei.

## 5. Record the addresses and connect the app

```bash
bun run deploy:record            # reads broadcast/DeployFluxora.s.sol/5042/run-latest.json
```

It writes `contracts/deployments/arc-mainnet.json` and prints the variables to set. Add them to your local `.env` and to your
hosting provider's environment settings (see [CONFIGURATION.md](CONFIGURATION.md)):

```
VITE_FLUXORA_TOKEN_ADDRESS=
VITE_FLUXORA_PAYMENTS_ADDRESS=
VITE_FLUXORA_STAKING_ADDRESS=
VITE_FLUXORA_GOVERNANCE_ADDRESS=
VITE_FLUXORA_TIMELOCK_ADDRESS=
VITE_FLUXORA_DEPLOY_BLOCK=        # optional
```

Restart the dev server (Vite reads `.env` at startup) or redeploy the site. Until a variable is set, the matching feature shows
"Contract Not Deployed".

## 6. Verify the contracts

See "Verify on the explorer" in [`contracts/README.md`](../contracts/README.md). In short: generate the Standard JSON input with
`forge verify-contract --show-standard-json-input`, then submit it on the contract's page at the Arc explorer with the compiler
settings from `contracts/foundry.toml` (solc 0.8.28, optimizer 200 runs, EVM `cancun`).

## 7. After deployment

1. **Fund staking rewards.** The rewards distributor approves FLUX to the Staking contract, then calls `notifyRewardAmount`. It needs at least one staker first.
2. **Delegate to yourself.** FLUX only counts for voting after `delegate(yourAddress)`. The Govern page has a button.
3. **Enable more payment tokens.** Payments accepts USDC and FLUX (and EURC if you set it). Adding a token is a governance proposal that calls `setTokenSupported` through the timelock; the Govern page has a template.
4. **Hand over roles carefully.** The deployer's `PAUSER` and `REWARDS_DISTRIBUTOR` roles are operational roles. Move them to a multisig when you are ready.
