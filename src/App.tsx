import { Suspense, lazy, useEffect } from 'react'
import { Shell } from '@/components/Shell'
import { PendingReconciler } from '@/components/PendingReconciler'
import { ErrorBoundary } from '@/components/ErrorBoundary'
import { ConfigNotice } from '@/components/ConfigNotice'
import { WalletWarmup } from '@/components/WalletWarmup'
import { WalletPromptBanner } from '@/components/WalletPromptBanner'
import { WalletEvents } from '@/hooks/useWallet'
import { useRoute } from '@/lib/router'
import { Dashboard } from '@/pages/Dashboard'

const Send = lazy(() => import('@/pages/Send').then((m) => ({ default: m.Send })))
const Receive = lazy(() => import('@/pages/Receive').then((m) => ({ default: m.Receive })))
const Swap = lazy(() => import('@/pages/Swap').then((m) => ({ default: m.Swap })))
const Bridge = lazy(() => import('@/pages/Bridge').then((m) => ({ default: m.Bridge })))
const Pay = lazy(() => import('@/pages/Pay').then((m) => ({ default: m.Pay })))
const History = lazy(() => import('@/pages/History').then((m) => ({ default: m.History })))
const Earn = lazy(() => import('@/pages/Earn').then((m) => ({ default: m.Earn })))
const Govern = lazy(() => import('@/pages/Govern').then((m) => ({ default: m.Govern })))

export default function App() {
  const { view, params, navigate } = useRoute()

  useEffect(() => {
    const titles: Record<string, string> = { dashboard: 'Dashboard', send: 'Send', receive: 'Receive', swap: 'Swap', bridge: 'Bridge', pay: 'Others Pay', history: 'History', earn: 'Earn', govern: 'Govern' }
    document.title = `${titles[view]} · FLUXORA`
  }, [view])

  return (
    <Shell view={view} navigate={navigate}>
      <WalletEvents />
      <ConfigNotice />
      <PendingReconciler />
      <WalletWarmup />
      <WalletPromptBanner />
      <ErrorBoundary resetKey={view}>
      <Suspense fallback={<div className="skeleton h-64 w-full" aria-busy="true" />}>
      {view === 'dashboard' && <Dashboard navigate={navigate} />}
      {view === 'send' && <Send presetTo={params.get('to') ?? undefined} presetAmount={params.get('amount') ?? undefined} presetToken={params.get('token') ?? undefined} />}
      {view === 'receive' && <Receive />}
      {view === 'swap' && <Swap />}
      {view === 'bridge' && <Bridge />}
      {view === 'pay' && <Pay params={params} navigate={navigate} />}
      {view === 'history' && <History />}
      {view === 'earn' && <Earn />}
      {view === 'govern' && <Govern />}
      </Suspense>
      </ErrorBoundary>
    </Shell>
  )
}
