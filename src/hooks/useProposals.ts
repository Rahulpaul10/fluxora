import { parseAbiItem, type Address, type Hex, type PublicClient } from 'viem'
import { useQuery } from '@tanstack/react-query'
import { usePublicClient, useReadContracts } from 'wagmi'
import { FLUXORA, fluxoraGovernanceAbi } from '@/config/contracts'
import { ARC_CHAIN_ID } from '@/config/networks'
import { isRangeError, withRateLimitRetry } from '@/lib/rpcUtils'

const proposalCreated = parseAbiItem(
  'event ProposalCreated(uint256 proposalId, address proposer, address[] targets, uint256[] values, string[] signatures, bytes[] calldatas, uint256 voteStart, uint256 voteEnd, string description)',
)

export const PROPOSAL_STATES = ['Pending', 'Active', 'Canceled', 'Defeated', 'Succeeded', 'Queued', 'Expired', 'Executed'] as const
export type ProposalStateName = (typeof PROPOSAL_STATES)[number]

export interface Proposal {
  id: bigint
  proposer: Address
  targets: readonly Address[]
  values: readonly bigint[]
  calldatas: readonly Hex[]
  voteStart: number
  voteEnd: number
  description: string
}

/** Recent history only: logs are read in bounded windows, so very old proposals need a manual lookup. */
const LOOKBACK_BLOCKS = 600_000n
const WINDOW = 8_000n

async function scan(client: PublicClient, from: bigint, to: bigint, depth = 0): Promise<Proposal[]> {
  if (!FLUXORA.governance) return []
  try {
    const logs = await withRateLimitRetry(() => client.getLogs({ address: FLUXORA.governance as Address, event: proposalCreated, fromBlock: from, toBlock: to }))
    return logs.flatMap((l) => {
      const a = l.args
      if (a.proposalId === undefined || !a.proposer || !a.targets || !a.values || !a.calldatas) return []
      return [{
        id: a.proposalId, proposer: a.proposer, targets: a.targets, values: a.values, calldatas: a.calldatas,
        voteStart: Number(a.voteStart ?? 0n), voteEnd: Number(a.voteEnd ?? 0n), description: a.description ?? '',
      }]
    })
  } catch (error) {
    if (!isRangeError(error) || to - from < 500n || depth > 4) throw error
    const mid = from + (to - from) / 2n
    return [...(await scan(client, from, mid, depth + 1)), ...(await scan(client, mid + 1n, to, depth + 1))]
  }
}

export function useProposals() {
  const client = usePublicClient({ chainId: ARC_CHAIN_ID })
  const list = useQuery({
    queryKey: ['proposals', FLUXORA.governance],
    enabled: Boolean(client && FLUXORA.governance),
    staleTime: 60_000,
    refetchInterval: 60_000,
    queryFn: async () => {
      if (!client) return [] as Proposal[]
      const head = await client.getBlockNumber()
      let lowest = head > LOOKBACK_BLOCKS ? head - LOOKBACK_BLOCKS : 0n
      if (FLUXORA.deployBlock && BigInt(FLUXORA.deployBlock) > lowest) lowest = BigInt(FLUXORA.deployBlock)
      const ranges: [bigint, bigint][] = []
      for (let lo = lowest; lo <= head; lo += WINDOW) ranges.push([lo, lo + WINDOW - 1n > head ? head : lo + WINDOW - 1n])
      const out: Proposal[] = []
      for (let i = 0; i < ranges.length; i += 3) {
        const batch = await Promise.all(ranges.slice(i, i + 3).map(([a, b]) => scan(client, a, b)))
        out.push(...batch.flat())
      }
      return out.sort((a, b) => b.voteStart - a.voteStart)
    },
  })

  const proposals = list.data ?? []
  const states = useReadContracts({
    contracts: proposals.map((p) => ({ address: FLUXORA.governance as Address, abi: fluxoraGovernanceAbi, functionName: 'state', args: [p.id], chainId: ARC_CHAIN_ID }) as const),
    query: { enabled: proposals.length > 0, refetchInterval: 20_000 },
  })
  const withState = proposals.map((p, i) => {
    const r = states.data?.[i]
    const idx = r?.status === 'success' ? Number(r.result) : undefined
    return { ...p, state: idx === undefined ? undefined : (PROPOSAL_STATES[idx]) }
  })
  return { proposals: withState, isLoading: list.isLoading, isError: list.isError, refetch: async () => { await list.refetch(); await states.refetch() } }
}
