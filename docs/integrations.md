# Verified integrations (Arbitrum One, chain 42161) — checked 2026-11-08

| Item | Address | Source / verification |
|---|---|---|
| USD₮0 (6 dec) | 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9 | nimiq.dev EVM tokens page; on-chain name/decimals |
| Aave V3 Pool | 0x794a61358D6845594F94dc1DB02A252b5b4814aD | bgd-labs/aave-address-book AaveV3Arbitrum.sol |
| Aave aUSDT | 0x6ab707Aca953eDAeFBc4fD23bA73294241490620 | address book + live getReserveData(USDT) |
| Chainlink ETH/USD | 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612 | docs.chain.link Arbitrum list; also GMX PRICE_FEED(WETH) |
| Chainlink USDT/USD | 0x21E1a03da332F9277A6839d1EF182d07644d1875 | underlying aggregator of Aave capped USDT oracle; on-chain description |
| Chainlink L2 sequencer | 0xFdB631F5EE196F0ed6FAa767959853A9F217697D | docs.chain.link L2 sequencer page; on-chain |
| GMX ExchangeRouter | 0x7dE39FF2e232A2203196788d37e234cF8F1b83f1 | docs.gmx.io contract addresses + live RoleStore CONTROLLER + selector check |
| GMX Router | 0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6 | docs + ExchangeRouter.router() |
| GMX OrderVault | 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5 | docs |
| GMX DataStore / RoleStore | 0xFD70…92d8 / 0x3c3d…6e72 | docs + DataStore.roleStore() |
| GMX OrderHandler | 0xa5D2d45228ee2E3A18AB122B2cE84997d008f4Eb | docs + ExchangeRouter.orderHandler() |
| GMX Reader | 0xfA26cBb46e2614609406de08CA1Dc7f70a684184 | docs |
| GMX ETH/USD market (WETH-USDC) | 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336 | Reader.getMarkets on-chain |
| GMX USDC/USDT swap market | 0xB686BcB112660343E6d15BDb65297e110C8311c4 | Reader.getMarkets on-chain |

Stale-source warning: gmx-synthetics `deployments/arbitrum/ExchangeRouter.json` (commit a85ea349)
points to 0x1C3f…6A41, which is **no longer a CONTROLLER**. Always verify routers on-chain before use.

Live observations at fork block (not quotes): Aave USDT supply rate ≈3.50% APR; USDT/USD 0.9987;
GMX MIN_COLLATERAL_USD = MIN_POSITION_SIZE_USD = $1.
