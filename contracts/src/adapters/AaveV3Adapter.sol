// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";
import {IAaveV3Pool} from "../interfaces/external/IAaveV3Pool.sol";

/// @notice Supply-only Aave V3 adapter. Per-vault instance: holds aTokens for exactly one vault.
/// No borrowing, no arbitrary calls, approvals are exact-amount and reset.
contract AaveV3Adapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    error OnlyVault();
    error ZeroAddress();
    error WithdrawShortfall(uint256 requested, uint256 received);
    error AlreadyBound();

    address public override vault; // bound once, atomically, by the deploying factory
    address public immutable deployer;
    address public immutable override asset;
    IAaveV3Pool public immutable pool;
    IERC20 public immutable aToken;

    constructor(address asset_, address pool_, address aToken_) {
        if (asset_ == address(0) || pool_ == address(0) || aToken_ == address(0)) revert ZeroAddress();
        deployer = msg.sender;
        asset = asset_;
        pool = IAaveV3Pool(pool_);
        aToken = IERC20(aToken_);
    }

    /// @notice One-time binding performed by the factory in the same transaction as deployment.
    function bind(address vault_) external {
        if (msg.sender != deployer || vault != address(0)) revert AlreadyBound();
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function totalAssets() public view override returns (uint256) {
        // aToken balance is the underlying claim (1:1, accrues via liquidity index). Counted once here.
        return aToken.balanceOf(address(this));
    }

    function maxWithdrawable() external view override returns (uint256) {
        uint256 claim = totalAssets();
        // Aave keeps unborrowed underlying in the aToken contract.
        uint256 liquidity = IERC20(asset).balanceOf(address(aToken));
        return claim < liquidity ? claim : liquidity;
    }

    function deposit(uint256 assets) external override onlyVault {
        IERC20(asset).safeTransferFrom(vault, address(this), assets);
        IERC20(asset).forceApprove(address(pool), assets);
        pool.supply(asset, assets, address(this), 0);
        IERC20(asset).forceApprove(address(pool), 0);
    }

    function withdraw(uint256 assets) external override onlyVault {
        uint256 before = IERC20(asset).balanceOf(vault);
        pool.withdraw(asset, assets, vault);
        uint256 received = IERC20(asset).balanceOf(vault) - before;
        if (received < assets) revert WithdrawShortfall(assets, received);
    }
}
