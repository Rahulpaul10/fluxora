import { zeroAddress, type Address } from 'viem'
import { getUsdc } from '@/onchain-facts'
import { ARC_CHAIN_ID } from '@/config/networks'
import { envAddress } from './env'
import { reportConfigIssue } from './configIssues'
import { FLUXORA } from '@/config/contracts'

export interface TokenInfo {
  symbol: string
  name: string
  address: Address
  decimals: number
  /** Brand tint for the fallback icon */
  color: string
}

const usdc = getUsdc(ARC_CHAIN_ID)
if (!usdc) throw new Error('Arc USDC is missing from the onchain facts registry')

export const USDC: TokenInfo = {
  symbol: 'USDC',
  name: 'USD Coin',
  address: usdc.address as Address,
  decimals: usdc.decimals,
  color: '#2775CA',
}

/**
 * Tokens FLUXORA supports on Arc mainnet. Addresses other than USDC come from docs.arc.io
 * (stored in .env as VITE_ARC_*) or from the user's own FLUXORA deployment. A token whose address is
 * not configured is simply not offered. Decimals are confirmed onchain by the balance hook.
 */
function optional(symbol: string, name: string, decimals: number, color: string, raw: unknown): TokenInfo[] {
  const address = envAddress(raw)
  if (!address) {
    reportConfigIssue(`VITE_ARC_${symbol.toUpperCase()}_ADDRESS is missing or not a valid address, so ${symbol} is hidden from balances, Send and Swap.`)
    return []
  }
  return [{ symbol, name, address, decimals, color }]
}

export const ARC_TOKENS: TokenInfo[] = [
  USDC,
  ...optional('EURC', 'Euro Coin', 6, '#3B82F6', import.meta.env.VITE_ARC_EURC_ADDRESS),
  ...optional('WETH', 'Wrapped Ether', 18, '#627EEA', import.meta.env.VITE_ARC_WETH_ADDRESS),
  ...optional('cirBTC', 'Circle Wrapped Bitcoin', 8, '#F7931A', import.meta.env.VITE_ARC_CIRBTC_ADDRESS),
  ...(FLUXORA.token
    ? [{ symbol: 'FLUX', name: 'FLUXORA', address: FLUXORA.token, decimals: 18, color: '#8B5CF6' } satisfies TokenInfo]
    : []),
]

export const tokenBySymbol = (symbol: string) => ARC_TOKENS.find((t) => t.symbol.toLowerCase() === symbol.toLowerCase())
export const tokenByAddress = (address: string) =>
  ARC_TOKENS.find((t) => t.address.toLowerCase() === address.toLowerCase())

/** Rejects the 0x0 / native sentinel that must never be used as a token on Arc. */
export const isSentinel = (address: string) => address.toLowerCase() === zeroAddress
