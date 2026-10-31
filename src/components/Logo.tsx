export function LogoMark({ size = 36 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 48 48" fill="none" aria-hidden="true">
      <defs>
        <linearGradient id="fx-a" x1="6" y1="4" x2="42" y2="44" gradientUnits="userSpaceOnUse">
          <stop stopColor="#8B5CF6" />
          <stop offset="0.55" stopColor="#EC4899" />
          <stop offset="1" stopColor="#22D3EE" />
        </linearGradient>
        <linearGradient id="fx-b" x1="10" y1="40" x2="40" y2="8" gradientUnits="userSpaceOnUse">
          <stop stopColor="#22D3EE" />
          <stop offset="1" stopColor="#10B981" />
        </linearGradient>
      </defs>
      <rect x="2" y="2" width="44" height="44" rx="14" fill="#0B1230" stroke="url(#fx-a)" strokeWidth="1.5" />
      <path d="M15 35V14h17" stroke="url(#fx-a)" strokeWidth="4.5" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M15 24.5h12" stroke="url(#fx-b)" strokeWidth="4.5" strokeLinecap="round" />
      <path d="M26 35c4 0 7-3 7-7" stroke="url(#fx-b)" strokeWidth="4.5" strokeLinecap="round" opacity="0.9" />
    </svg>
  )
}

export function Wordmark() {
  return (
    <span className="flex items-center gap-2.5">
      <LogoMark />
      <span className="font-display text-xl font-bold tracking-[0.06em] text-white">FLUXORA</span>
    </span>
  )
}
