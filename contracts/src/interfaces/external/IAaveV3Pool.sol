// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal subset of the Aave V3 Pool used here. Verified against Arbitrum Pool
/// 0x794a61358D6845594F94dc1DB02A252b5b4814aD (bgd-labs/aave-address-book, 2026-11-08).
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
