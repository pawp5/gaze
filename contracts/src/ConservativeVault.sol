// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626, ERC20, IERC20, Math} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";

/// @title ConservativeVault
/// @notice Pooled single-underlying ERC-4626 vault: idle reserve + one fixed supply-only adapter.
/// - Adapter, idle floor and adapter cap are immutable (no adapter-replacement backdoor).
/// - Inflation defense: OZ virtual shares/assets with a 6-decimal offset.
/// - Keeper can only move funds between idle and the fixed adapter, within immutable bounds.
/// - Guardian pause blocks deposits/allocation; withdrawals/redemptions are never paused by this contract.
/// - Unsupported: fee-on-transfer and rebasing assets (deposit reverts on balance mismatch).
contract ConservativeVault is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    error NotAdmin();
    error NotKeeper();
    error NotGuardian();
    error Paused();
    error DeadlineExpired();
    error SlippageExceeded(uint256 got, uint256 limit);
    error UnsupportedTokenBehavior();
    error PolicyViolation();
    error ZeroShares();
    error BadConfig();

    event Allocated(address indexed keeper, uint256 assets, uint256 idleAfter, uint256 adapterAfter, bytes32 decisionHash);
    event Deallocated(address indexed caller, uint256 assets, uint256 idleAfter, uint256 adapterAfter, bytes32 decisionHash);
    event PausedSet(bool paused);
    event KeeperSet(address keeper);
    event AdminTransferred(address admin);

    uint16 public constant BPS = 10_000;

    IYieldAdapter public immutable adapter;
    uint16 public immutable minIdleBps;
    uint16 public immutable maxAdapterBps;
    address public immutable creator;
    address public immutable guardian;

    address public admin;
    address public keeper;
    bool public paused;

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        IYieldAdapter adapter_,
        address creator_,
        address admin_,
        address keeper_,
        address guardian_,
        uint16 minIdleBps_,
        uint16 maxAdapterBps_
    ) ERC20(name_, symbol_) ERC4626(asset_) {
        if (address(adapter_) == address(0) || admin_ == address(0) || guardian_ == address(0)) revert BadConfig();
        if (minIdleBps_ > BPS || maxAdapterBps_ > BPS || uint256(minIdleBps_) + maxAdapterBps_ > BPS) revert BadConfig();
        adapter = adapter_;
        minIdleBps = minIdleBps_;
        maxAdapterBps = maxAdapterBps_;
        creator = creator_;
        admin = admin_;
        keeper = keeper_;
        guardian = guardian_;
    }

    // ---------------------------------------------------------------- accounting

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function idleAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice NAV = idle underlying + adapter claim. Adapter view reverting reverts NAV (never silently 0).
    function totalAssets() public view override returns (uint256) {
        return idleAssets() + adapter.totalAssets();
    }

    /// @notice Immediately withdrawable underlying (idle + venue-liquid portion of adapter claim).
    function availableLiquidity() public view returns (uint256) {
        return idleAssets() + adapter.maxWithdrawable();
    }

    function maxDeposit(address) public view override returns (uint256) {
        return paused ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return paused ? 0 : type(uint256).max;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 own = previewRedeem(balanceOf(owner));
        uint256 liq = availableLiquidity();
        return own < liq ? own : liq;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 shares = balanceOf(owner);
        uint256 liq = availableLiquidity();
        // Full exit is allowed whenever the owner's redeemable value fits in available liquidity.
        if (previewRedeem(shares) <= liq) return shares;
        return _convertToShares(liq, Math.Rounding.Floor);
    }

    // ---------------------------------------------------------------- user entry/exit

    /// @notice Deposit with minShares and deadline protection.
    function depositChecked(uint256 assets, address receiver, uint256 minShares, uint256 deadline)
        external
        returns (uint256 shares)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        shares = deposit(assets, receiver);
        if (shares < minShares) revert SlippageExceeded(shares, minShares);
    }

    /// @notice Redeem with minAssets and deadline protection. Never blocked by pause.
    function redeemChecked(uint256 shares, address receiver, address owner, uint256 minAssets, uint256 deadline)
        external
        returns (uint256 assets)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        assets = redeem(shares, receiver, owner);
        if (assets < minAssets) revert SlippageExceeded(assets, minAssets);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        if (paused) revert Paused();
        if (shares == 0) revert ZeroShares();
        IERC20 token = IERC20(asset());
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(caller, address(this), assets);
        if (token.balanceOf(address(this)) - before != assets) revert UnsupportedTokenBehavior();
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        if (caller != owner) _spendAllowance(owner, caller, shares);
        // Burn first (CEI), then source liquidity. Any failure reverts the whole tx: shares are not lost.
        _burn(owner, shares);
        uint256 idle = idleAssets();
        if (idle < assets) {
            adapter.withdraw(assets - idle);
        }
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    // ---------------------------------------------------------------- keeper allocation

    /// @notice Move idle funds into the fixed adapter. Enforces adapter cap and idle floor post-move.
    function allocate(uint256 assets, bytes32 decisionHash) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        if (paused) revert Paused();
        uint256 total = totalAssets();
        uint256 idleAfter = idleAssets() - assets; // reverts on underflow
        uint256 adapterAfter = adapter.totalAssets() + assets;
        if (idleAfter * BPS < total * minIdleBps) revert PolicyViolation();
        if (adapterAfter * BPS > total * maxAdapterBps) revert PolicyViolation();
        IERC20(asset()).forceApprove(address(adapter), assets);
        adapter.deposit(assets);
        IERC20(asset()).forceApprove(address(adapter), 0);
        emit Allocated(msg.sender, assets, idleAssets(), adapter.totalAssets(), decisionHash);
    }

    /// @notice Pull funds back to idle. Risk-reducing: allowed for keeper, admin or guardian, also while paused.
    function deallocate(uint256 assets, bytes32 decisionHash) external nonReentrant {
        if (msg.sender != keeper && msg.sender != admin && msg.sender != guardian) revert NotKeeper();
        adapter.withdraw(assets);
        emit Deallocated(msg.sender, assets, idleAssets(), adapter.totalAssets(), decisionHash);
    }

    // ---------------------------------------------------------------- roles

    function setPaused(bool p) external {
        if (msg.sender != guardian) revert NotGuardian();
        paused = p;
        emit PausedSet(p);
    }

    function setKeeper(address k) external {
        if (msg.sender != admin) revert NotAdmin();
        keeper = k;
        emit KeeperSet(k);
    }

    function transferAdmin(address a) external {
        if (msg.sender != admin) revert NotAdmin();
        if (a == address(0)) revert BadConfig();
        admin = a;
        emit AdminTransferred(a);
    }
}
