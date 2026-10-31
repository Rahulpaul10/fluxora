import { useState } from 'react'
import { useAccount, usePublicClient, useReadContracts } from 'wagmi'
import { useGuardedWrite } from '@/hooks/useGuardedWallet'
import { erc20Abi, type Hex, zeroAddress } from 'viem'
import { toast } from 'sonner'
import { Amount } from '@/onchain-money'
import { FLUXORA, fluxoraStakingAbi } from '@/config/contracts'
import { ARC_CHAIN_ID } from '@/config/networks'
import { getFees } from '@/lib/fees'
import { fmtDuration, fmtToken } from '@/lib/format'
import { parseTxError } from '@/lib/errors'
import { recordActivity } from '@/lib/activity'
import { ensureAllowance } from '@/lib/tx'
import { ArcGate, NotDeployed } from '@/components/Gate'
import { TxStatus } from '@/components/TxStatus'
import { Card, Notice, PageTitle, Row, Segmented, Spinner } from '@/components/ui'
import { useNow } from '@/hooks/useNow'

const FLUX_DECIMALS = 18

export function Earn() {
  return (
    <>
      <PageTitle title="Earn" subtitle="Stake FLUX in the FLUXORA Staking contract and earn FLUX rewards. Withdraw any time." />
      {!FLUXORA.staking || !FLUXORA.token ? (
        <NotDeployed contracts={["token", "staking"]} />
      ) : (
        <ArcGate feature="Staking">
          <Staking staking={FLUXORA.staking} flux={FLUXORA.token} />
        </ArcGate>
      )}
    </>
  )
}

function Staking({ staking, flux }: { staking: `0x${string}`; flux: `0x${string}` }) {
  const { address } = useAccount()
  const client = usePublicClient({ chainId: ARC_CHAIN_ID })
  const { writeContractAsync } = useGuardedWrite()
  const [mode, setMode] = useState<'stake' | 'withdraw'>('stake')
  const [amount, setAmount] = useState('')
  const [busy, setBusy] = useState(false)
  const [hash, setHash] = useState<Hex>()
  const [error, setError] = useState<string>()

  const base = { address: staking, abi: fluxoraStakingAbi, chainId: ARC_CHAIN_ID } as const
  const reads = useReadContracts({
    contracts: [
      { ...base, functionName: 'totalStaked' },
      { ...base, functionName: 'rewardRate' },
      { ...base, functionName: 'periodFinish' },
      { ...base, functionName: 'rewardsDuration' },
      { ...base, functionName: 'paused' },
      { ...base, functionName: 'balanceOf', args: [address ?? zeroAddress] },
      { ...base, functionName: 'earned', args: [address ?? zeroAddress] },
      { address: flux, abi: erc20Abi, functionName: 'balanceOf', args: [address ?? zeroAddress], chainId: ARC_CHAIN_ID },
    ],
    query: { refetchInterval: 15_000, enabled: Boolean(address) },
  })
  const [totalStaked, rewardRate, periodFinish, rewardsDuration, paused, staked, earned, fluxBal] = (reads.data ?? []).map((r) => (r.status === 'success' ? r.result : undefined)) as [
    bigint | undefined, bigint | undefined, bigint | undefined, bigint | undefined, boolean | undefined, bigint | undefined, bigint | undefined, bigint | undefined,
  ]

  const now = useNow()
  const active = periodFinish !== undefined && Number(periodFinish) > now
  // APR = rewards emitted per year / total staked (reward and stake are both FLUX)
  const apr = active && rewardRate && totalStaked && totalStaked > 0n ? Number((rewardRate * 31_536_000n * 10_000n) / totalStaked) / 100 : undefined

  let raw: bigint | undefined
  let amountError: string | undefined
  if (amount) {
    try {
      const a = Amount.parse(amount, FLUX_DECIMALS)
      const cap = mode === 'stake' ? fluxBal : staked
      if (!a.isPositive()) amountError = 'Amount must be greater than zero.'
      else if (cap !== undefined && a.raw > cap) amountError = mode === 'stake' ? 'Amount exceeds your FLUX balance.' : 'Amount exceeds your staked FLUX.'
      else raw = a.raw
    } catch {
      amountError = 'Enter a number with up to 18 decimals.'
    }
  }

  const run = async (kind: 'stake' | 'withdraw' | 'claim' | 'exit') => {
    if (!client || !address) return
    setBusy(true)
    setError(undefined)
    try {
      const fees = await getFees(client, ARC_CHAIN_ID)
      if (kind === 'stake' && raw) {
        await ensureAllowance({ client, write: (req) => writeContractAsync(req), token: flux, symbol: 'FLUX', owner: address, spender: staking, amount: raw, fees })
      }
      const fn = kind === 'stake' ? 'stake' : kind === 'withdraw' ? 'withdraw' : kind === 'claim' ? 'getReward' : 'exit'
      const args = kind === 'stake' || kind === 'withdraw' ? ([raw ?? 0n] as const) : ([] as const)
      const params = {
        chainId: ARC_CHAIN_ID, address: staking, abi: fluxoraStakingAbi, functionName: fn, args,
        maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
      }
      const h = await writeContractAsync(params as unknown as Parameters<typeof writeContractAsync>[0])
      setHash(h)
      recordActivity({ hash: h, kind: 'stake', chainId: ARC_CHAIN_ID, account: address, summary: kind === 'stake' ? `Staked ${amount} FLUX` : kind === 'withdraw' ? `Withdrew ${amount} FLUX` : kind === 'claim' ? 'Claimed staking rewards' : 'Exited staking' })
    } catch (e) {
      const p = parseTxError(e)
      if (p.rejected) toast('Cancelled')
      else setError(p.message)
    } finally {
      setBusy(false)
    }
  }

  if (reads.isLoading) return <Card><Spinner /></Card>

  return (
    <div className="mx-auto grid max-w-3xl gap-5 md:grid-cols-2">
      <Card className="space-y-1">
        <p className="label">Pool</p>
        <div className="divide-y divide-white/5">
          <Row label="Total staked" value={totalStaked === undefined ? '—' : `${fmtToken(totalStaked, FLUX_DECIMALS, 2)} FLUX`} />
          <Row label="Current reward rate (APR)" value={apr === undefined ? (active ? '—' : 'No active rewards') : `${apr.toFixed(2)}%`} />
          <Row label="Reward period" value={rewardsDuration ? fmtDuration(Number(rewardsDuration)) : '—'} />
          <Row label="Rewards end" value={active && periodFinish ? new Date(Number(periodFinish) * 1000).toLocaleDateString() : 'Not running'} />
        </div>
        <div className="divide-y divide-white/5 pt-4">
          <p className="label pb-2">Your position</p>
          <Row label="Staked" value={staked === undefined ? '—' : `${fmtToken(staked, FLUX_DECIMALS, 4)} FLUX`} />
          <Row label="Unclaimed rewards" value={earned === undefined ? '—' : `${fmtToken(earned, FLUX_DECIMALS, 6)} FLUX`} />
          <Row label="Wallet FLUX" value={fluxBal === undefined ? '—' : `${fmtToken(fluxBal, FLUX_DECIMALS, 4)} FLUX`} />
        </div>
        <div className="grid grid-cols-2 gap-2 pt-4">
          <button className="btn-ghost" disabled={busy || !earned} onClick={() => void run('claim')}>Claim rewards</button>
          <button className="btn-ghost" disabled={busy || !staked} onClick={() => void run('exit')}>Withdraw all and claim</button>
        </div>
      </Card>

      <Card className="space-y-4">
        <Segmented value={mode} onChange={(m) => { setMode(m); setAmount('') }} options={[{ value: 'stake', label: 'Stake' }, { value: 'withdraw', label: 'Withdraw' }]} />
        {paused && mode === 'stake' && <Notice tone="warn">New staking is paused. Withdrawals and claims still work.</Notice>}
        <div>
          <div className="flex items-center justify-between">
            <label className="label" htmlFor="stake-amt">Amount of FLUX</label>
            <button className="text-xs font-semibold text-[var(--a)]" onClick={() => { const cap = mode === 'stake' ? fluxBal : staked; if (cap !== undefined) setAmount(Amount.fromRaw(cap, FLUX_DECIMALS).toString()) }}>Max</button>
          </div>
          <input id="stake-amt" inputMode="decimal" className="field mt-2 font-display !text-2xl tabular" placeholder="0.00" value={amount} onChange={(e) => setAmount(e.target.value.replace(/,/g, '.'))} />
          {amountError && <p className="mt-1.5 text-sm text-flux-pink">{amountError}</p>}
        </div>
        {error && <Notice tone="error">{error}</Notice>}
        {hash ? (
          <>
            <TxStatus hash={hash} chainId={ARC_CHAIN_ID} title="Staking transaction" onSettled={() => { void reads.refetch(); setAmount('') }} />
            <button className="btn-ghost w-full" onClick={() => setHash(undefined)}>Done</button>
          </>
        ) : (
          <button className="btn-primary w-full" disabled={!raw || busy || (paused === true && mode === 'stake')} onClick={() => void run(mode)}>
            {busy ? <><Spinner /> Confirm in your wallet…</> : mode === 'stake' ? 'Approve and stake' : 'Withdraw'}
          </button>
        )}
        <p className="text-xs text-slate-500">Rewards are paid from FLUX deposited by the reward distributor. If no rewards are funded, the rate shows as inactive.</p>
      </Card>
    </div>
  )
}
