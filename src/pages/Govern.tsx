import { useState } from 'react'
import { encodeFunctionData, getAddress, isAddress, keccak256, parseEventLogs, stringToHex, type Hex, zeroAddress } from 'viem'
import { useAccount, usePublicClient, useReadContracts } from 'wagmi'
import { useGuardedWrite } from '@/hooks/useGuardedWallet'
import { toast } from 'sonner'
import { useProposals, type Proposal, type ProposalStateName } from '@/hooks/useProposals'
import { FLUXORA, fluxoraGovernanceAbi, fluxoraPaymentsAbi, fluxoraTokenAbi } from '@/config/contracts'
import { ARC_CHAIN_ID } from '@/config/networks'
import { getFees } from '@/lib/fees'
import { waitForReceipt } from '@/lib/txTracker'
import { fmtDate, fmtToken } from '@/lib/format'
import { parseTxError } from '@/lib/errors'
import { recordActivity } from '@/lib/activity'
import { ArcGate, NotDeployed } from '@/components/Gate'
import { TxStatus } from '@/components/TxStatus'
import { Card, Notice, PageTitle, Row, Segmented, Spinner } from '@/components/ui'

export function Govern() {
  return (
    <>
      <PageTitle title="Govern" subtitle="FLUX holders vote on changes to FLUXORA. Passed proposals wait in a timelock before they run." />
      {!FLUXORA.governance || !FLUXORA.token ? (
        <NotDeployed contracts={["governance", "token"]} />
      ) : (
        <ArcGate feature="Governance">
          <Governance governance={FLUXORA.governance} token={FLUXORA.token} />
        </ArcGate>
      )}
    </>
  )
}

function Governance({ governance, token }: { governance: `0x${string}`; token: `0x${string}` }) {
  const { address } = useAccount()
  const client = usePublicClient({ chainId: ARC_CHAIN_ID })
  const { writeContractAsync } = useGuardedWrite()
  const { proposals, isLoading, isError, refetch } = useProposals()
  const [hash, setHash] = useState<Hex>()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string>()

  const holder = address ?? zeroAddress
  const reads = useReadContracts({
    contracts: [
      { address: token, abi: fluxoraTokenAbi, functionName: 'delegates', args: [holder], chainId: ARC_CHAIN_ID },
      { address: token, abi: fluxoraTokenAbi, functionName: 'getVotes', args: [holder], chainId: ARC_CHAIN_ID },
      { address: token, abi: fluxoraTokenAbi, functionName: 'balanceOf', args: [holder], chainId: ARC_CHAIN_ID },
      { address: governance, abi: fluxoraGovernanceAbi, functionName: 'proposalThreshold', chainId: ARC_CHAIN_ID },
      { address: governance, abi: fluxoraGovernanceAbi, functionName: 'votingPeriod', chainId: ARC_CHAIN_ID },
      { address: governance, abi: fluxoraGovernanceAbi, functionName: 'votingDelay', chainId: ARC_CHAIN_ID },
    ],
    query: { enabled: Boolean(address), refetchInterval: 20_000 },
  })
  const val = (i: number) => (reads.data?.[i]?.status === 'success' ? reads.data[i].result : undefined)
  const delegatee = val(0) as string | undefined
  const votes = val(1) as bigint | undefined
  const balance = val(2) as bigint | undefined
  const threshold = val(3) as bigint | undefined
  const votingPeriod = val(4) as bigint | undefined
  const votingDelay = val(5) as bigint | undefined
  const zero = zeroAddress
  const needsDelegation = balance !== undefined && balance > 0n && (!delegatee || delegatee === zero)

  const sendAsync = async (label: string, run: () => Promise<Hex>) => {
    if (!address) return
    setBusy(true)
    setError(undefined)
    try {
      const h = await run()
      setHash(h)
      recordActivity({ hash: h, kind: 'govern', chainId: ARC_CHAIN_ID, account: address, summary: label })
    } catch (e) {
      const p = parseTxError(e)
      if (p.rejected) toast('Cancelled')
      else setError(p.message)
    } finally {
      setBusy(false)
    }
  }
  const send = (label: string, run: () => Promise<Hex>) => {
    void sendAsync(label, run)
  }

  const write = async (address_: `0x${string}`, abi: typeof fluxoraGovernanceAbi | typeof fluxoraTokenAbi, fn: string, args: readonly unknown[]) => {
    if (!client || !address) throw new Error('Wallet not ready')
    const fees = await getFees(client, ARC_CHAIN_ID)
    const params = {
      chainId: ARC_CHAIN_ID, address: address_, abi, functionName: fn, args,
      maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
    }
    return writeContractAsync(params as unknown as Parameters<typeof writeContractAsync>[0])
  }

  return (
    <div className="mx-auto max-w-3xl space-y-5">
      <Card className="space-y-1">
        <p className="label">Your voting power</p>
        <div className="divide-y divide-white/5">
          <Row label="FLUX balance" value={balance === undefined ? '—' : `${fmtToken(balance, 18, 4)} FLUX`} />
          <Row label="Active votes" value={votes === undefined ? '—' : `${fmtToken(votes, 18, 4)}`} />
          <Row label="Delegated to" value={!delegatee || delegatee === zero ? 'Nobody' : delegatee.toLowerCase() === address?.toLowerCase() ? 'Yourself' : delegatee} mono />
          <Row label="Needed to propose" value={threshold === undefined ? '—' : `${fmtToken(threshold, 18, 2)} FLUX`} />
          <Row label="Voting delay / period" value={votingDelay !== undefined && votingPeriod !== undefined ? `${Number(votingDelay) / 3600} h / ${Number(votingPeriod) / 3600} h` : '—'} />
        </div>
        {needsDelegation && address && (
          <div className="pt-3">
            <Notice tone="warn" action={<button className="btn-ghost !min-h-[36px]" disabled={busy} onClick={() => void send('Delegated voting power to self', () => write(token, fluxoraTokenAbi, 'delegate', [address]))}>Delegate to myself</button>}>
              Your FLUX has no voting power until you delegate it. Delegate to yourself or someone you trust.
            </Notice>
          </div>
        )}
      </Card>

      {error && <Notice tone="error">{error}</Notice>}
      {hash && <TxStatus hash={hash} chainId={ARC_CHAIN_ID} title="Governance transaction" onSettled={() => { void reads.refetch(); void refetch() }} />}

      <CreateProposal
        enabled={Boolean(votes !== undefined && threshold !== undefined && votes >= threshold)}
        threshold={threshold}
        busy={busy}
        onSubmit={(targets, values, calldatas, description) =>
          send('Created a governance proposal', async () => {
            const h = await write(governance, fluxoraGovernanceAbi, 'propose', [targets, values, calldatas, description])
            const receipt = await waitForReceipt(client, h)
            if (receipt) parseEventLogs({ abi: fluxoraGovernanceAbi, logs: receipt.logs, eventName: 'ProposalCreated' })
            return h
          })
        }
      />

      <Card className="space-y-3">
        <p className="label">Proposals (recent blocks)</p>
        {isLoading ? <Spinner /> : isError ? (
          <Notice tone="warn">Could not read proposals right now.</Notice>
        ) : proposals.length === 0 ? (
          <p className="py-4 text-center text-sm text-slate-400">No proposals found in the recent blocks scanned.</p>
        ) : (
          <ul className="space-y-3">
            {proposals.map((p) => (
              <ProposalCard key={p.id.toString()} p={p} state={p.state} governance={governance} busy={busy}
                onVote={(support) => send('Voted on a proposal', () => write(governance, fluxoraGovernanceAbi, 'castVote', [p.id, support]))}
                onQueue={() => send('Queued a proposal', () => write(governance, fluxoraGovernanceAbi, 'queue', [p.targets, p.values, p.calldatas, keccak256(stringToHex(p.description))]))}
                onExecute={() => send('Executed a proposal', () => write(governance, fluxoraGovernanceAbi, 'execute', [p.targets, p.values, p.calldatas, keccak256(stringToHex(p.description))]))}
              />
            ))}
          </ul>
        )}
        <p className="text-xs text-slate-500">Proposals older than the scanned range do not appear here. Queued proposals can only run for 14 days after the timelock delay.</p>
      </Card>
    </div>
  )
}

function ProposalCard({ p, state, governance, busy, onVote, onQueue, onExecute }: {
  p: Proposal; state: ProposalStateName | undefined; governance: `0x${string}`; busy: boolean
  onVote: (support: 0 | 1 | 2) => void; onQueue: () => void; onExecute: () => void
}) {
  const { address } = useAccount()
  const reads = useReadContracts({
    contracts: [
      { address: governance, abi: fluxoraGovernanceAbi, functionName: 'proposalVotes', args: [p.id], chainId: ARC_CHAIN_ID },
      { address: governance, abi: fluxoraGovernanceAbi, functionName: 'hasVoted', args: [p.id, address ?? zeroAddress], chainId: ARC_CHAIN_ID },
    ],
    query: { refetchInterval: 20_000 },
  })
  const tally = reads.data?.[0]?.status === 'success' ? (reads.data[0].result) : undefined
  const voted = reads.data?.[1]?.status === 'success' ? (reads.data[1].result) : false
  const title = p.description.split('\n')[0].replace(/^#+\s*/, '') || `Proposal ${p.id.toString().slice(0, 8)}…`

  return (
    <li className="glass-inner rounded-2xl p-4">
      <div className="flex items-start justify-between gap-3">
        <p className="min-w-0 font-semibold text-white">{title}</p>
        <span className="shrink-0 rounded-full bg-volt/20 px-2.5 py-1 text-xs font-semibold text-volt">{state ?? '…'}</span>
      </div>
      <p className="mt-1 text-xs text-slate-400">Voting {fmtDate(p.voteStart)} to {fmtDate(p.voteEnd)}</p>
      {tally && (
        <div className="mt-3 grid grid-cols-3 gap-2 text-center text-xs">
          <div className="rounded-xl bg-flux-green/10 p-2"><p className="text-flux-green">For</p><p className="tabular text-white">{fmtToken(tally[1], 18, 2)}</p></div>
          <div className="rounded-xl bg-flux-pink/10 p-2"><p className="text-flux-pink">Against</p><p className="tabular text-white">{fmtToken(tally[0], 18, 2)}</p></div>
          <div className="rounded-xl bg-white/5 p-2"><p className="text-slate-300">Abstain</p><p className="tabular text-white">{fmtToken(tally[2], 18, 2)}</p></div>
        </div>
      )}
      <div className="mt-3 flex flex-wrap gap-2">
        {state === 'Active' && !voted && (
          <>
            <button className="btn-ghost !min-h-[40px]" disabled={busy} onClick={() => onVote(1)}>Vote for</button>
            <button className="btn-ghost !min-h-[40px]" disabled={busy} onClick={() => onVote(0)}>Vote against</button>
            <button className="btn-ghost !min-h-[40px]" disabled={busy} onClick={() => onVote(2)}>Abstain</button>
          </>
        )}
        {state === 'Active' && voted && <span className="text-sm text-slate-400">You have voted.</span>}
        {state === 'Succeeded' && <button className="btn-primary !min-h-[40px]" disabled={busy} onClick={onQueue}>Queue in timelock</button>}
        {state === 'Queued' && <button className="btn-primary !min-h-[40px]" disabled={busy} onClick={onExecute}>Execute</button>}
      </div>
    </li>
  )
}

type Template = 'fee' | 'token'

function CreateProposal({ enabled, threshold, busy, onSubmit }: {
  enabled: boolean; threshold: bigint | undefined; busy: boolean
  onSubmit: (targets: `0x${string}`[], values: bigint[], calldatas: Hex[], description: string) => void
}) {
  const [template, setTemplate] = useState<Template>('fee')
  const [bps, setBps] = useState('')
  const [tokenAddr, setTokenAddr] = useState('')
  const [allow, setAllow] = useState(true)
  const [why, setWhy] = useState('')

  if (!FLUXORA.payments) return null

  const bpsNum = Number(bps)
  const bpsOk = Number.isInteger(bpsNum) && bpsNum >= 0 && bpsNum <= 100
  const tokenOk = isAddress(tokenAddr)
  const valid = (template === 'fee' ? bpsOk && bps !== '' : tokenOk) && why.trim().length >= 10

  const submit = () => {
    if (!FLUXORA.payments) return
    const data =
      template === 'fee'
        ? encodeFunctionData({ abi: fluxoraPaymentsAbi, functionName: 'setFeeBps', args: [BigInt(bpsNum)] })
        : encodeFunctionData({ abi: fluxoraPaymentsAbi, functionName: 'setTokenSupported', args: [getAddress(tokenAddr), allow] })
    const title = template === 'fee' ? `Set payment fee to ${bpsNum / 100}%` : `${allow ? 'Enable' : 'Disable'} ${getAddress(tokenAddr)} for payments`
    onSubmit([FLUXORA.payments], [0n], [data], `# ${title}\n${why.trim()}`)
  }

  return (
    <Card className="space-y-4">
      <p className="label">Create a proposal</p>
      {!enabled && (
        <Notice tone="info">
          You need at least {threshold === undefined ? 'the threshold of' : `${fmtToken(threshold, 18, 2)}`} delegated FLUX to propose.
        </Notice>
      )}
      <Segmented value={template} onChange={setTemplate} options={[{ value: 'fee', label: 'Payment fee' }, { value: 'token', label: 'Payment token' }]} />
      {template === 'fee' ? (
        <div>
          <label className="label" htmlFor="p-bps">New fee in basis points (0 to 100)</label>
          <input id="p-bps" className="field mt-2" inputMode="numeric" value={bps} onChange={(e) => setBps(e.target.value)} placeholder="25 = 0.25%" />
          {bps && !bpsOk && <p className="mt-1.5 text-sm text-flux-pink">The contract caps the fee at 100 bps (1%).</p>}
        </div>
      ) : (
        <div className="space-y-3">
          <input className="field font-mono text-sm" placeholder="Token address 0x…" value={tokenAddr} onChange={(e) => setTokenAddr(e.target.value.trim())} aria-label="Token address" />
          <Segmented value={allow ? 'on' : 'off'} onChange={(v) => setAllow(v === 'on')} options={[{ value: 'on', label: 'Enable' }, { value: 'off', label: 'Disable' }]} />
          <p className="text-xs text-slate-500">Only standard, non-rebasing, exact-transfer ERC-20 tokens should be enabled.</p>
        </div>
      )}
      <div>
        <label className="label" htmlFor="p-why">Why (shown to voters)</label>
        <textarea id="p-why" className="field mt-2 min-h-24" value={why} onChange={(e) => setWhy(e.target.value)} />
      </div>
      <button className="btn-primary w-full" disabled={!enabled || !valid || busy} onClick={submit}>Submit proposal</button>
      <p className="text-xs text-slate-500">The proposal runs through the timelock after a successful vote. It never sends value.</p>
    </Card>
  )
}
