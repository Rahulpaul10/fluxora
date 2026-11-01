/**
 * FLUXORA contract addresses.
 *
 * Addresses are NEVER hardcoded. After you deploy the contracts yourself (docs/DEPLOYMENT.md), put each
 * address in your environment (.env locally, or your host's environment settings):
 *
 *   VITE_FLUXORA_TOKEN_ADDRESS
 *   VITE_FLUXORA_PAYMENTS_ADDRESS
 *   VITE_FLUXORA_STAKING_ADDRESS
 *   VITE_FLUXORA_GOVERNANCE_ADDRESS
 *   VITE_FLUXORA_TIMELOCK_ADDRESS
 *   VITE_FLUXORA_DEPLOY_BLOCK         (optional, block of the first deployment transaction)
 *
 * A missing or invalid value means that contract is "Contract Not Deployed" and the app disables the
 * features that depend on it. No placeholder address is ever treated as a real contract.
 */
import type { Address } from 'viem'
import { envAddress, envNumber } from '@/lib/env'
import { reportConfigIssue } from '@/lib/configIssues'
import { ARC_CHAIN_ID } from '@/config/networks'

export {
  fluxoraTokenAbi,
  fluxoraPaymentsAbi,
  fluxoraStakingAbi,
  fluxoraGovernanceAbi,
  fluxoraTimelockAbi,
} from './abis.generated'

export type ContractName = 'token' | 'payments' | 'staking' | 'governance' | 'timelock'

export interface ContractDefinition {
  name: ContractName
  label: string
  envVar: string
  /** Network the contract is deployed on */
  chainId: number
  address: Address | undefined
}

export const CONTRACT_DEFINITIONS: Record<ContractName, ContractDefinition> = {
  token: { name: 'token', label: 'FLUXORA Token', envVar: 'VITE_FLUXORA_TOKEN_ADDRESS', chainId: ARC_CHAIN_ID, address: envAddress(import.meta.env.VITE_FLUXORA_TOKEN_ADDRESS) },
  payments: { name: 'payments', label: 'FLUXORA Payments', envVar: 'VITE_FLUXORA_PAYMENTS_ADDRESS', chainId: ARC_CHAIN_ID, address: envAddress(import.meta.env.VITE_FLUXORA_PAYMENTS_ADDRESS) },
  staking: { name: 'staking', label: 'FLUXORA Staking', envVar: 'VITE_FLUXORA_STAKING_ADDRESS', chainId: ARC_CHAIN_ID, address: envAddress(import.meta.env.VITE_FLUXORA_STAKING_ADDRESS) },
  governance: { name: 'governance', label: 'FLUXORA Governance', envVar: 'VITE_FLUXORA_GOVERNANCE_ADDRESS', chainId: ARC_CHAIN_ID, address: envAddress(import.meta.env.VITE_FLUXORA_GOVERNANCE_ADDRESS) },
  timelock: { name: 'timelock', label: 'FLUXORA Timelock', envVar: 'VITE_FLUXORA_TIMELOCK_ADDRESS', chainId: ARC_CHAIN_ID, address: envAddress(import.meta.env.VITE_FLUXORA_TIMELOCK_ADDRESS) },
}

/** Flat view used by hooks and pages. Each field is undefined until the address is configured. */
export const FLUXORA = {
  token: CONTRACT_DEFINITIONS.token.address,
  payments: CONTRACT_DEFINITIONS.payments.address,
  staking: CONTRACT_DEFINITIONS.staking.address,
  governance: CONTRACT_DEFINITIONS.governance.address,
  timelock: CONTRACT_DEFINITIONS.timelock.address,
  deployBlock: envNumber(import.meta.env.VITE_FLUXORA_DEPLOY_BLOCK),
} as const

export const isDeployed = (name: ContractName): boolean => CONTRACT_DEFINITIONS[name].address !== undefined
export const getContractAddress = (name: ContractName): Address | undefined => CONTRACT_DEFINITIONS[name].address
export const deployedCount = (): number => Object.values(CONTRACT_DEFINITIONS).filter((c) => c.address).length


/** Flag addresses that are set but invalid, and deployments that are only partly configured. */
;(() => {
  const raw: Record<ContractName, unknown> = {
    token: import.meta.env.VITE_FLUXORA_TOKEN_ADDRESS,
    payments: import.meta.env.VITE_FLUXORA_PAYMENTS_ADDRESS,
    staking: import.meta.env.VITE_FLUXORA_STAKING_ADDRESS,
    governance: import.meta.env.VITE_FLUXORA_GOVERNANCE_ADDRESS,
    timelock: import.meta.env.VITE_FLUXORA_TIMELOCK_ADDRESS,
  }
  const names = Object.keys(raw) as ContractName[]
  for (const n of names) {
    const v = raw[n]
    if (typeof v === 'string' && v.trim() && !CONTRACT_DEFINITIONS[n].address) {
      reportConfigIssue(`${CONTRACT_DEFINITIONS[n].envVar} is set but is not a valid address, so ${CONTRACT_DEFINITIONS[n].label} stays off.`)
    }
  }
  // Each feature works on its own (for example Pay needs only the payments contract), so a partial set is fine.
  // Only flag contracts whose own dependencies are missing.
  const has = (n: ContractName): boolean => Boolean(CONTRACT_DEFINITIONS[n].address)
  const needs: [ContractName, ContractName[]][] = [
    ['staking', ['token']],
    ['governance', ['token', 'timelock']],
    ['timelock', ['governance']],
  ]
  for (const [name, deps] of needs) {
    const missingDeps = deps.filter((d) => !has(d))
    if (has(name) && missingDeps.length > 0) {
      reportConfigIssue(`${CONTRACT_DEFINITIONS[name].envVar} is set but ${missingDeps.map((d) => CONTRACT_DEFINITIONS[d].envVar).join(', ')} is not, so ${CONTRACT_DEFINITIONS[name].label} cannot work.`)
    }
  }
  const block: unknown = import.meta.env.VITE_FLUXORA_DEPLOY_BLOCK
  if (typeof block === 'string' && block.trim() && envNumber(block) === undefined) {
    reportConfigIssue('VITE_FLUXORA_DEPLOY_BLOCK must be a whole block number.')
  }
})()
