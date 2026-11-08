# Portfolio Manager (Nimiq Pay mini app + mandate contracts)

Three mandates on Arbitrum One:
- **Conservative** — pooled ERC-4626 USD₮0 vault, idle floor + Aave V3 supply-only adapter.
- **Balanced** — per-user account: ≥50% of each contribution into Conservative reserve shares the
  trading path cannot touch; ≤50% active capital for GMX V2 isolated perps; optional profit banking.
- **Aggressive** — per-user account: up to 100% active capital; separate, stricter-coded ceilings.

No funded mainnet transactions have been made. See `docs/acceptance-matrix.md` for what is and isn't done.

## Contracts
```
cd contracts
# Foundry 1.5.1, solc 0.8.28, OZ v5.4.0 (c64a1ed), forge-std v1.11.0 (8e40513) vendored in lib/
export ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc   # any Arbitrum archive-capable RPC
forge build
forge test            # unit + fuzz + invariant + fork (fork pinned at block 522351408)
forge test --match-path 'test/unit/*'   # offline only
```
Last run: 16 passed, 0 failed (4 suites).
