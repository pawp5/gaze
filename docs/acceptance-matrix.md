# Acceptance matrix — increment 1 (2026-11-08)

Status dimensions are independent: **Implemented** (real tx path exists) · **Integration-tested** (ran against identified deployed contracts) · **Strategy-evaluated** (evidence for/against the investment hypothesis) · **Funded/public** (authorized live use).

| Capability | Conservative | Balanced | Aggressive |
|---|---|---|---|
| Permissionless creation (curated integrations) | Implemented · fork-tested | Implemented · fork-tested | Implemented · fork-tested |
| Deposit / shares / previews / minShares+deadline | ERC-4626 + checked wrappers · fork-tested | Per-contribution reserve/active split · fork-tested | 100% active funding · fork-tested |
| Real venue | Aave V3 USD₮0 (Arbitrum) · fork-tested, real accrual | GMX V2 ETH/USD isolated perp · fork-tested (real create/execute/close) | same venue, separate account+policy · fork-tested |
| Policy enforcement | idle floor / adapter cap immutable · unit+fork | leverage (Chainlink-priced USDT), per-order collateral, fee budget incl. close reserve, price deviation vs Chainlink, GMX min sizes read from DataStore, pending/position caps · fork | same code, different ceilings (5x vs 3x, 0% vs ≥50% reserve) · fork |
| Reserve isolation after losses | n/a | Proven in fork loss scenario (-20% ETH @3x): reserve shares unchanged, keeper has no path | no reserve by design; isolated from Balanced accounts · fork |
| Profit banking (realized only) | n/a | Fork scenario: unrealized gain cannot bank; realized $54.10 → $25 banked | supported (optional rule) — not separately fork-tested |
| Exit without AI/keeper | redeem never paused · fork | requestExit blocks new risk; owner can close/cancel/withdraw · fork | keeper revoked, owner closes & withdraws · fork |
| Guardian pause | blocks deposits/allocation, exits open · fork | blocks new risk; reduce/withdraw open · fork | same |
| Order lifecycle / reconciliation | n/a | create → execute → reconcile (idempotent) · fork. **Cancel path implemented, not yet fork-tested** (GMX market-order cancel delay) | same |
| Keeper service (TypeScript) | **Not started** | **Not started** | **Not started** |
| AI provider + deterministic baseline | **Not started** | **Not started** | **Not started** |
| Nimiq Pay mini app | **Not started** | **Not started** | **Not started** |
| Strategy-evaluated | No (lending baseline only) | **No evidence** | **No evidence** |
| Funded/public release | Not authorized | Not authorized | Not authorized |

## Measured on fork (pinned block 522351408) — mechanics, not performance claims
- Aave: 495 USDT supplied for 30 days → +1.422 USDT (≈3.5% APR at the pinned block's rate).
- GMX round trip, 25 USDT @2x: returned 24.90 USDT (real fees + price impact + USDT↔USDC swaps).
- GMX round trip, 50 USDT @4x: returned 49.70 USDT.
- Scenario (mocked ETH −20%, 3x): 25 → 10.07 USDT active; reserve intact.
- Scenario (mocked ETH +40%, ~3x): 25 → 54.10 USDT realized; 25 banked.
Scenario prices are deterministic test inputs, not market evidence.

## Known gaps / risks found
- GMX executes orders via its own keepers + Chainlink Data Streams. Fork tests substitute GMX's
  on-chain ChainlinkPriceFeedProvider and impersonate a real ORDER_KEEPER (disclosed scaffolding).
- Leverage cap applies per increment; losses raise effective leverage until GMX liquidation.
- Decrease `minOutUsdt` is keeper-supplied; GMX swaps use oracle prices, but the bound is weak.
- No callbacks are used (callbackContract = 0) → no callback-forgery surface; state is reconciled from DataStore.
- Native ETH for GMX execution fees is supplied by the owner and is outside the USDT risk budget.
- Original multiasset (USDC/USDT/WETH) pooled-share portfolio: **not implemented** in this increment.
