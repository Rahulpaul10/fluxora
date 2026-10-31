import { useMemo } from 'react'
import { erc20Abi, type Address } from 'viem'
import { useAccount, usePublicClient, useReadContracts } from 'wagmi'
import { useQuery } from '@tanstack/react-query'
import { ARC_TOKENS, USDC, type TokenInfo } from '@/lib/tokens'
import { ARC_CHAIN_ID } from '@/config/networks'
import { bestQuote } from '@/lib/uniswap-arc'

export interface BalanceRow {
  token: TokenInfo
  /** Raw balance in the token's own decimals. undefined while loading or if the read failed. */
  raw: bigint | undefined
}

/**
 * Real ERC-20 balances on Arc via one multicall. Decimals are read from each contract so a wrong
 * configured value can never produce a wrong amount. On Arc, USDC is shown ONLY through its 6-decimal
 * ERC-20 view (the native balance is the same pool and must never be added on top).
 */
export function useTokenBalances() {
  const { address } = useAccount()
  const contracts = useMemo(
    () =>
      ARC_TOKENS.flatMap((t) => [
        { address: t.address, abi: erc20Abi, functionName: 'balanceOf', args: [address as Address], chainId: ARC_CHAIN_ID } as const,
        { address: t.address, abi: erc20Abi, functionName: 'decimals', chainId: ARC_CHAIN_ID } as const,
      ]),
    [address],
  )
  const query = useReadContracts({
    contracts,
    allowFailure: true,
    query: { enabled: Boolean(address), refetchInterval: 15_000 },
  })

  const rows: BalanceRow[] = ARC_TOKENS.map((t, i) => {
    const bal = query.data?.[i * 2]
    const dec = query.data?.[i * 2 + 1]
    const decimals = dec?.status === 'success' ? Number(dec.result) : t.decimals
    return {
      token: { ...t, decimals },
      raw: bal?.status === 'success' ? (bal.result as bigint) : undefined,
    }
  })
  return { rows, isLoading: query.isLoading, refetch: query.refetch, isError: query.isError }
}

/** Live USDC price of one unit of each non-USDC token, from real Uniswap quotes on Arc. */
export function useTokenPrices() {
  const client = usePublicClient({ chainId: ARC_CHAIN_ID })
  return useQuery({
    queryKey: ['token-prices'],
    enabled: Boolean(client),
    refetchInterval: 60_000,
    staleTime: 30_000,
    queryFn: async () => {
      const prices: Record<string, bigint | null> = { [USDC.symbol]: 10n ** BigInt(USDC.decimals) }
      if (!client) return prices
      await Promise.all(
        ARC_TOKENS.filter((t) => t.symbol !== 'USDC').map(async (t) => {
          try {
            const q = await bestQuote(client, t.address, USDC.address, 'exactIn', 10n ** BigInt(t.decimals))
            prices[t.symbol] = q.amountOut
          } catch {
            prices[t.symbol] = null // no live liquidity: value is unknown, never guessed
          }
        }),
      )
      return prices
    },
  })
}
