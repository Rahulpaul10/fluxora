# Deploy FLUXORA from Remix with your own wallet (Arc Mainnet)

Everything here is manual and sends real, irreversible transactions on Arc Mainnet. Arc Studio never deploys
for you. These contracts have **not** had an independent professional audit (see "Security status" at the end).
Rehearse on Arc Testnet first if you can, and re-read every address before you confirm a transaction.

## What you are deploying

FLUXORA is five contracts that work together. The app uses all of them, so there is no single "one file" contract:

| Order | Contract | What the app uses it for |
|---|---|---|
| 1 | `FluxoraToken` | FLUX token: fixed 1,000,000,000 supply, burnable, voting power, gasless `permit` |
| 2 | `FluxoraTimelock` | Delay (2 days) and 14-day execution window for governance actions |
| 3 | `FluxoraGovernance` | Proposals and voting by FLUX holders (Govern page) |
| 4 | `FluxoraPayments` | Pay, payment requests and receipts (Others Pay page) |
| 5 | `FluxoraStaking` | Stake FLUX, earn FLUX rewards (Earn page) |

You (the wallet that deploys) are `msg.sender` for every deployment. Where a constructor needs an address, you
paste your own wallet address. Nothing in the contracts contains a private key, a hidden mint, a hidden transfer
or an upgrade backdoor: after the hand-off, the timelock (controlled only by FLUX holders through governance) is
the admin of Payments and Staking.

## Files and compiler settings

The files in `contracts/remix/` are self-contained (OpenZeppelin 5.6.1 is already inside them, no imports to
download). Compiled with the settings below they produce byte-for-byte the same code as the project build that
the 208 tests ran against (checked for all five contracts).

| Setting | Value |
|---|---|
| Compiler | `0.8.28` (the `0.8.28+commit…` build in Remix) |
| Language | Solidity |
| EVM version | `cancun` (set it by hand, do not leave it on default) |
| Optimization | Enabled, **200** runs |

## Before you start
1. MetaMask is on **Arc Mainnet, chain ID 5042**, and the wallet you deploy from is selected.
2. That wallet holds about **1 USDC** (on Arc, USDC is the gas token). Measured gas on a fork of Arc Mainnet:
   Token 1.84M, Timelock 1.66M, Governance 3.98M, Payments 2.15M, Staking 1.71M, plus about 0.13M for the three
   timelock calls, so about 11.6M gas in total. At 25 gwei that is about 0.29 USDC, at 45 gwei about 0.52 USDC.
   Check the fee MetaMask shows. If its Network Fee line is blank, compare against these gas numbers.
3. The wallet you use as "YOUR_WALLET" below receives **all 1,000,000,000 FLUX** and, until you renounce it in
   step 6, has admin power over the timelock. Use a wallet you control well, ideally a hardware wallet or a
   multisig that can call contracts.
4. Open https://remix.ethereum.org, create a workspace, and upload the five `*.flat.sol` files from
   `contracts/remix/` (File Explorer, upload icon).

## Deploy (Remix: Deploy & Run Transactions)
Environment: **Injected Provider - MetaMask**. Remix must show "Custom (5042) network" and your account. For each
step choose the contract in the dropdown, paste the values next to its Deploy button, and confirm in MetaMask.
Copy each deployed address (the copy icon next to the deployed instance) into a notepad before you continue.

Array arguments are typed in brackets: `[]` is empty, `["0xabc..."]` has one entry, separated by commas.

**1. FluxoraToken**
- `initialHolder`: `YOUR_WALLET`

**2. FluxoraTimelock**
- `minDelay`: `172800` (2 days, in seconds)
- `proposers`: `[]`
- `executors`: `["0x0000000000000000000000000000000000000000"]` (anyone may execute a queued proposal)
- `admin`: `YOUR_WALLET` (temporary, you renounce it in step 6)

**3. FluxoraGovernance**
- `token_`: `TOKEN_ADDRESS` (from step 1)
- `timelock_`: `TIMELOCK_ADDRESS` (from step 2)
- `votingDelay_`: `86400` (1 day)
- `votingPeriod_`: `259200` (3 days)
- `proposalThreshold_`: `1000000000000000000000000` (1,000,000 FLUX)
- `quorumPercent_`: `4`

**4. FluxoraPayments**
- `admin`: `TIMELOCK_ADDRESS` (not your wallet)
- `pauser`: `YOUR_WALLET`
- `initialTokens`: `["0x3600000000000000000000000000000000000000","TOKEN_ADDRESS","0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1"]`
  (Arc USDC, FLUX, and EURC; remove the last entry if you do not want EURC payments)

**5. FluxoraStaking**
- `token`: `TOKEN_ADDRESS`
- `admin`: `TIMELOCK_ADDRESS` (not your wallet)
- `rewardsDistributor`: `YOUR_WALLET`
- `pauser`: `YOUR_WALLET`
- `duration`: `2592000` (30 days)

**6. Hand the timelock to governance** (on the deployed `FluxoraTimelock`, in Remix expand the instance)
1. Press the blue `PROPOSER_ROLE` button and copy the returned value (a 32-byte hash). Call
   `grantRole(role, account)` with that value and `GOVERNANCE_ADDRESS`.
2. Do the same with `CANCELLER_ROLE` and `GOVERNANCE_ADDRESS`.
3. Run the check (next section) with `--deployer=YOUR_WALLET`. The only FAIL you should see is
   "Your deployer wallet has RENOUNCED timelock admin".
4. Only then call `renounceRole(role, account)` with `role` =
   `0x0000000000000000000000000000000000000000000000000000000000000000` (`DEFAULT_ADMIN_ROLE`) and
   `account` = `YOUR_WALLET`. This cannot be undone. Without it, your wallet could still bypass governance.

I rehearsed exactly these steps, with these exact values, on a local fork of Arc Mainnet. The check printed
36 passed, 0 failed. That was a simulation, not a mainnet deployment.

## Check the deployment, then connect the app
Put the five addresses in `.env` (locally) or in your host's environment settings, then run the read-only check:

```
VITE_FLUXORA_TOKEN_ADDRESS=0x...
VITE_FLUXORA_TIMELOCK_ADDRESS=0x...
VITE_FLUXORA_GOVERNANCE_ADDRESS=0x...
VITE_FLUXORA_PAYMENTS_ADDRESS=0x...
VITE_FLUXORA_STAKING_ADDRESS=0x...
VITE_FLUXORA_DEPLOY_BLOCK=<block of the FluxoraToken deployment transaction, from the explorer>
```

```
bun run verify:deployment --deployer=YOUR_WALLET
```

It sends nothing and needs no wallet. It checks chain 5042, that every address has code, the token supply and
clock, every timelock role, governance wiring, payment token allowlist and fee cap, staking token and duration,
and that your deployer wallet holds no admin power. Fix every FAIL before using the app. Warnings about you being
the pauser and rewards distributor are expected. Then restart the dev server (Vite reads `.env` only at start-up)
or rebuild and redeploy the site. A missing or malformed address shows a "Configuration problem" notice instead
of failing silently. Changing your domain later needs no contract change; see `docs/HOSTING.md`.

## After deployment
- **Fund staking rewards:** on FLUX call `approve(STAKING_ADDRESS, amount)`, then on Staking call
  `notifyRewardAmount(amount)` from your wallet (the distributor). Rewards stream over the 30-day duration.
- **Distribute FLUX before relying on governance.** While you hold all FLUX, you alone control every vote.
  Voting power also requires holders to delegate to themselves (the Govern page has a button).
- Governance can later replace the pauser and distributor roles, change the payment fee (hard cap 1%) and
  allow more payment tokens.

## Verify the source on the explorer
Arc's docs I could find do not describe contract verification, and the explorer's API is behind a bot check, so
I cannot confirm which method `https://explorer.arc.io` supports. If its contract page offers a verification
form:
1. Choose single-file Solidity, compiler `0.8.28`, EVM `cancun`, optimization **Yes**, **200** runs, license MIT.
2. Paste the `*.flat.sol` file for that contract.
3. Constructor arguments, ABI-encoded without `0x`. Example for the token:
   `cast abi-encode "constructor(address)" YOUR_WALLET`. Other signatures:
   - Timelock `constructor(uint256,address[],address[],address)`
   - Governance `constructor(address,address,uint48,uint32,uint256,uint256)`
   - Payments `constructor(address,address,address[])`
   - Staking `constructor(address,address,address,address,uint256)`
Remix's own "Contract Verification" plugin may also work if the explorer is supported there.

## Security status (be honest with yourself and your users)
- 208 automated tests pass, including fuzz and invariant tests.
- Three rounds of AI-assisted review and a Slither static scan found no High issues. Findings were fixed.
- The deployment script was dry-run against the live Arc state (no broadcast). That caught and fixed a bug that
  would have made the script revert on mainnet.
- **No independent professional audit has been done.** Get one before large amounts of value are involved.
- Known design limits: whoever holds the FLUX controls governance at first, the pauser and rewards distributor are
  EOAs until governance replaces them, and allowed payment tokens must be standard non-rebasing tokens.
