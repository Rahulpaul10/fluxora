/**
 * Read-only check of a FLUXORA deployment on Arc. It sends NO transactions and needs NO wallet or key.
 *
 *   bun run verify:deployment                       reads the VITE_FLUXORA_*_ADDRESS values from .env
 *   bun run verify:deployment --deployer=0xYou...   also proves your deployer wallet holds no admin power
 *
 * Run it after the Remix steps in docs/REMIX_DEPLOYMENT.md and BEFORE you announce or fund anything.
 * Exit code 0 means every check passed; 1 means at least one FAIL (details are printed).
 */
import { createPublicClient, getAddress, http, isAddress, zeroAddress, type Address } from 'viem'
import {
  fluxoraGovernanceAbi,
  fluxoraPaymentsAbi,
  fluxoraStakingAbi,
  fluxoraTimelockAbi,
  fluxoraTokenAbi,
} from '../src/config/abis.generated'
import { ARC_CHAIN_ID, HOME_NETWORK } from '../src/config/networks'
import { getUsdc } from '../src/onchain-facts'

const DAY = 86_400n
const results: { status: 'PASS' | 'FAIL' | 'WARN'; name: string; detail: string }[] = []
const record = (status: 'PASS' | 'FAIL' | 'WARN', name: string, detail = '') => results.push({ status, name, detail })
const check = (ok: boolean, name: string, detail = '') => record(ok ? 'PASS' : 'FAIL', name, detail)

function addressFromEnv(name: string): Address | undefined {
  const raw = process.env[name]?.trim()
  if (!raw) return undefined
  if (!isAddress(raw)) {
    record('FAIL', name, `"${raw}" is not a valid address`)
    return undefined
  }
  return getAddress(raw)
}

const deployerArg = process.argv.find((a) => a.startsWith('--deployer='))?.slice('--deployer='.length)
const deployer = deployerArg && isAddress(deployerArg) ? getAddress(deployerArg) : undefined
if (deployerArg && !deployer) record('FAIL', '--deployer', `"${deployerArg}" is not a valid address`)

const addrs = {
  token: addressFromEnv('VITE_FLUXORA_TOKEN_ADDRESS'),
  timelock: addressFromEnv('VITE_FLUXORA_TIMELOCK_ADDRESS'),
  governance: addressFromEnv('VITE_FLUXORA_GOVERNANCE_ADDRESS'),
  payments: addressFromEnv('VITE_FLUXORA_PAYMENTS_ADDRESS'),
  staking: addressFromEnv('VITE_FLUXORA_STAKING_ADDRESS'),
}

const rpcUrl = process.env.VITE_ARC_RPC_URL?.trim() || HOME_NETWORK.rpcUrls[0]
if (!rpcUrl) throw new Error('No Arc RPC URL is configured.')
const client = createPublicClient({ transport: http(rpcUrl, { retryCount: 3, retryDelay: 400, timeout: 15_000 }) })

async function main() {
  console.log(`RPC: ${new URL(rpcUrl).host}`)
  const chainId = await client.getChainId()
  check(chainId === ARC_CHAIN_ID, 'RPC serves Arc Mainnet', `chain id ${chainId}, expected ${ARC_CHAIN_ID}`)
  if (chainId !== ARC_CHAIN_ID) return

  const missing = Object.entries(addrs).filter(([, v]) => !v).map(([k]) => k)
  if (missing.length) {
    record('FAIL', 'Contract addresses configured', `missing in .env: ${missing.join(', ')} (see docs/REMIX_DEPLOYMENT.md)`)
    return
  }
  const { token, timelock, governance, payments, staking } = addrs as Record<keyof typeof addrs, Address>
  for (const [name, address] of Object.entries(addrs)) {
    const code = await client.getCode({ address: address as Address })
    check(Boolean(code && code !== '0x'), `${name} has contract code`, address)
  }
  if (results.some((r) => r.status === 'FAIL')) return

  const usdc = getUsdc(ARC_CHAIN_ID)?.address as Address | undefined

  // ── Token ────────────────────────────────────────────────────────────────
  const [name, symbol, decimals, supply, maxSupply, tokenClock] = await Promise.all([
    client.readContract({ address: token, abi: fluxoraTokenAbi, functionName: 'name' }),
    client.readContract({ address: token, abi: fluxoraTokenAbi, functionName: 'symbol' }),
    client.readContract({ address: token, abi: fluxoraTokenAbi, functionName: 'decimals' }),
    client.readContract({ address: token, abi: fluxoraTokenAbi, functionName: 'totalSupply' }),
    client.readContract({ address: token, abi: fluxoraTokenAbi, functionName: 'INITIAL_SUPPLY' }),
    client.readContract({ address: token, abi: fluxoraTokenAbi, functionName: 'CLOCK_MODE' }),
  ])
  check(name === 'FLUXORA' && symbol === 'FLUX' && decimals === 18, 'Token is FLUXORA / FLUX / 18 decimals', `${name} / ${symbol} / ${decimals}`)
  check(supply <= maxSupply && maxSupply === 1_000_000_000n * 10n ** 18n, 'Token supply never exceeds the fixed 1,000,000,000 FLUX', `total supply ${supply}`)
  check(tokenClock === 'mode=timestamp', 'Token uses the timestamp clock', tokenClock)

  // ── Timelock ─────────────────────────────────────────────────────────────
  const tl = (functionName: 'PROPOSER_ROLE' | 'CANCELLER_ROLE' | 'EXECUTOR_ROLE' | 'DEFAULT_ADMIN_ROLE') =>
    client.readContract({ address: timelock, abi: fluxoraTimelockAbi, functionName })
  const [proposerRole, cancellerRole, executorRole, adminRole, minDelay, grace] = await Promise.all([
    tl('PROPOSER_ROLE'),
    tl('CANCELLER_ROLE'),
    tl('EXECUTOR_ROLE'),
    tl('DEFAULT_ADMIN_ROLE'),
    client.readContract({ address: timelock, abi: fluxoraTimelockAbi, functionName: 'getMinDelay' }),
    client.readContract({ address: timelock, abi: fluxoraTimelockAbi, functionName: 'GRACE_PERIOD' }),
  ])
  const tlHas = (role: `0x${string}`, account: Address) =>
    client.readContract({ address: timelock, abi: fluxoraTimelockAbi, functionName: 'hasRole', args: [role, account] })
  check(minDelay >= 3600n, 'Timelock delay is at least 1 hour', `${minDelay} s (${Number(minDelay) / 86400} days)`)
  check(grace === 14n * DAY, 'Timelock execution window is 14 days', `${grace} s`)
  check(await tlHas(proposerRole, governance), 'Governance contract is the timelock PROPOSER', governance)
  check(await tlHas(cancellerRole, governance), 'Governance contract is the timelock CANCELLER', governance)
  check(await tlHas(executorRole, zeroAddress), 'Anyone can execute a queued proposal (open EXECUTOR)', 'role held by the zero address')
  check(await tlHas(adminRole, timelock), 'Timelock administers itself (changes need a proposal)', timelock)
  if (deployer) {
    check(!(await tlHas(adminRole, deployer)), 'Your deployer wallet has RENOUNCED timelock admin', deployer)
    check(!(await tlHas(proposerRole, deployer)), 'Your deployer wallet is not a timelock proposer', deployer)
    check(!(await tlHas(cancellerRole, deployer)), 'Your deployer wallet is not a timelock canceller', deployer)
  } else {
    record('WARN', 'Deployer wallet not checked', 'pass --deployer=0xYourWallet to prove it holds no timelock admin')
  }

  // ── Governance ───────────────────────────────────────────────────────────
  const gAddr = { address: governance, abi: fluxoraGovernanceAbi } as const
  const [gToken, gTimelock, vDelay, vPeriod, threshold, quorum, gClock] = await Promise.all([
    client.readContract({ ...gAddr, functionName: 'token' }),
    client.readContract({ ...gAddr, functionName: 'timelock' }),
    client.readContract({ ...gAddr, functionName: 'votingDelay' }),
    client.readContract({ ...gAddr, functionName: 'votingPeriod' }),
    client.readContract({ ...gAddr, functionName: 'proposalThreshold' }),
    client.readContract({ ...gAddr, functionName: 'quorumNumerator' }),
    client.readContract({ ...gAddr, functionName: 'CLOCK_MODE' }),
  ])
  check(getAddress(gToken) === token, 'Governance votes with the FLUX token', gToken)
  check(getAddress(gTimelock) === timelock, 'Governance is wired to this timelock', gTimelock)
  check(threshold <= maxSupply, 'Proposal threshold is reachable (≤ total FLUX supply)', `${threshold}`)
  check(quorum >= 1n && quorum <= 100n, 'Quorum is between 1% and 100%', `${quorum}%`)
  check(vPeriod >= 3600n, 'Voting period is at least 1 hour', `${vPeriod} s`)
  check(gClock === 'mode=timestamp', 'Governance uses the timestamp clock', gClock)
  record('PASS', 'Governance settings (info)', `voting delay ${vDelay} s · voting period ${vPeriod} s · threshold ${threshold} · quorum ${quorum}%`)

  // ── Payments ─────────────────────────────────────────────────────────────
  const pay = <F extends 'DEFAULT_ADMIN_ROLE' | 'PAUSER_ROLE' | 'feeBps' | 'MAX_FEE_BPS' | 'paused'>(functionName: F) =>
    client.readContract({ address: payments, abi: fluxoraPaymentsAbi, functionName })
  const [pAdminRole, pPauserRole, feeBps, maxFee, pPaused] = await Promise.all([
    pay('DEFAULT_ADMIN_ROLE'), pay('PAUSER_ROLE'), pay('feeBps'), pay('MAX_FEE_BPS'), pay('paused'),
  ])
  const payHas = (role: `0x${string}`, account: Address) =>
    client.readContract({ address: payments, abi: fluxoraPaymentsAbi, functionName: 'hasRole', args: [role, account] })
  const payTokenOk = (t: Address) =>
    client.readContract({ address: payments, abi: fluxoraPaymentsAbi, functionName: 'supportedTokens', args: [t] })
  check(await payHas(pAdminRole, timelock), 'Payments admin is the timelock', timelock)
  check(feeBps <= maxFee, 'Payment fee is within the hard cap', `${feeBps} bps (cap ${maxFee})`)
  check(!pPaused, 'Payments is not paused', '')
  if (usdc) check(await payTokenOk(usdc), 'Payments accepts Arc USDC', usdc)
  check(await payTokenOk(token), 'Payments accepts FLUX', token)
  if (deployer) {
    check(!(await payHas(pAdminRole, deployer)), 'Your deployer wallet holds no Payments admin power', deployer)
    if (await payHas(pPauserRole, deployer)) record('WARN', 'Deployer is the Payments pauser', 'intended; governance can replace it')
  }

  // ── Staking ──────────────────────────────────────────────────────────────
  const stk = <F extends 'DEFAULT_ADMIN_ROLE' | 'REWARDS_DISTRIBUTOR_ROLE' | 'PAUSER_ROLE' | 'stakingToken' | 'rewardsDuration' | 'paused'>(functionName: F) =>
    client.readContract({ address: staking, abi: fluxoraStakingAbi, functionName })
  const [sAdminRole, sDistRole, sPauserRole, sToken, sDuration, sPaused] = await Promise.all([
    stk('DEFAULT_ADMIN_ROLE'), stk('REWARDS_DISTRIBUTOR_ROLE'), stk('PAUSER_ROLE'), stk('stakingToken'), stk('rewardsDuration'), stk('paused'),
  ])
  const stkHas = (role: `0x${string}`, account: Address) =>
    client.readContract({ address: staking, abi: fluxoraStakingAbi, functionName: 'hasRole', args: [role, account] })
  check(getAddress(sToken) === token, 'Staking token is FLUX', sToken)
  check(await stkHas(sAdminRole, timelock), 'Staking admin is the timelock', timelock)
  check(sDuration >= 7n * DAY && sDuration <= 365n * DAY, 'Staking rewards duration is 7 to 365 days', `${Number(sDuration) / 86400} days`)
  check(!sPaused, 'Staking is not paused', '')
  if (deployer) {
    check(!(await stkHas(sAdminRole, deployer)), 'Your deployer wallet holds no Staking admin power', deployer)
    if (await stkHas(sDistRole, deployer)) record('WARN', 'Deployer is the staking rewards distributor', 'intended: it funds rewards; governance can replace it')
    if (await stkHas(sPauserRole, deployer)) record('WARN', 'Deployer is the Staking pauser', 'intended; governance can replace it')
  }
}

await main().catch((error: unknown) => {
  record('FAIL', 'Verification could not finish', error instanceof Error ? error.message.split('\n')[0] ?? 'error' : 'error')
})

const icon = { PASS: 'PASS', FAIL: 'FAIL', WARN: 'WARN' } as const
for (const r of results) console.log(`${icon[r.status]}  ${r.name}${r.detail ? `  —  ${r.detail}` : ''}`)
const fails = results.filter((r) => r.status === 'FAIL').length
console.log(`\n${results.filter((r) => r.status === 'PASS').length} passed, ${fails} failed, ${results.filter((r) => r.status === 'WARN').length} warnings`)
process.exit(fails ? 1 : 0)
