// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Narrow reserve/yield adapter. One adapter instance serves exactly one vault.
interface IYieldAdapter {
    function vault() external view returns (address);
    function asset() external view returns (address);
    /// @notice Underlying-denominated claim held by this adapter for its vault (no double counting).
    function totalAssets() external view returns (uint256);
    /// @notice Underlying the venue can return right now (bounded by venue liquidity).
    function maxWithdrawable() external view returns (uint256);
    /// @notice Pulls `assets` from the vault and supplies them. onlyVault.
    function deposit(uint256 assets) external;
    /// @notice Withdraws exactly `assets` underlying to the vault. onlyVault. Reverts if impossible.
    function withdraw(uint256 assets) external;
}
