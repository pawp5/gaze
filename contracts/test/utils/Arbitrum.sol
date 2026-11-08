// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Verified Arbitrum One (42161) addresses — sources & dates in docs/integrations.md.
library Arb {
    uint256 internal constant FORK_BLOCK = 522351408; // pinned 2026-11-08
    // tokens
    address internal constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9; // USD₮0, 6 dec
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    // Aave V3
    address internal constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address internal constant AAVE_aUSDT = 0x6ab707Aca953eDAeFBc4fD23bA73294241490620;
    // Chainlink
    address internal constant CL_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant CL_USDT_USD = 0x21E1a03da332F9277A6839d1EF182d07644d1875;
    address internal constant CL_SEQUENCER = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    // GMX V2 (docs.gmx.io/docs/api/contracts/addresses + on-chain RoleStore CONTROLLER check)
    address internal constant GMX_EXCHANGE_ROUTER = 0x7dE39FF2e232A2203196788d37e234cF8F1b83f1;
    address internal constant GMX_ROUTER = 0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6;
    address internal constant GMX_ORDER_VAULT = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;
    address internal constant GMX_DATASTORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address internal constant GMX_ROLESTORE = 0x3c3d99FD298f679DBC2CEcd132b4eC4d0F5e6e72;
    address internal constant GMX_ORDER_HANDLER = 0xa5D2d45228ee2E3A18AB122B2cE84997d008f4Eb;
    address internal constant GMX_ORACLE = 0x26C02F221e8dB5A821e12347C7eA8a6b6E10842f;
    address internal constant GMX_READER = 0xfA26cBb46e2614609406de08CA1Dc7f70a684184;
    address internal constant GMX_CL_PRICEFEED_PROVIDER = 0x90218fbb064b1475E4382b041Cc7ccF08AF718B0;
    address internal constant GMX_ORDER_KEEPER = 0xE47b36382DC50b90bCF6176Ddb159C4b9333A7AB;
    address internal constant GMX_ETH_USD_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336; // WETH-USDC
    address internal constant GMX_USDC_USDT_SWAP = 0xB686BcB112660343E6d15BDb65297e110C8311c4;
}
