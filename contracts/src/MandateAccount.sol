// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ConservativeVault} from "./ConservativeVault.sol";
import {OracleGuard} from "./libraries/OracleGuard.sol";
import {GmxOrder, GmxKeys, IGmxExchangeRouter, IGmxDataStore} from "./interfaces/external/IGmx.sol";

interface IRiskPauseSource {
    function riskPaused() external view returns (bool);
}

/// @title MandateAccount
/// @notice Per-user isolated account for the Balanced and Aggressive mandates.
///
/// Custody model (enforced by code, not labels):
///  - RESERVE  = ConservativeVault shares held by this account. No keeper-callable function can
///               redeem, transfer, approve or pledge them. Only the owner can redeem, and only to the owner.
///  - ACTIVE   = USDT/USDC/WETH balances in this account plus GMX positions/orders owned by this account.
///               The keeper can only send ACTIVE USDT to the GMX OrderVault for orders on ONE fixed market,
///               with receiver/cancellationReceiver hard-coded to this account and no callback contract.
///  - Loss boundary of the speculative path = ACTIVE funds the owner explicitly put here
///               + ETH the owner deposited for execution fees. No borrowing beyond GMX isolated-margin
///               positions, whose loss is capped at posted collateral by GMX's liquidation design.
///               This is a design boundary, not a guaranteed stop-loss.
///  - No reserve -> active replenishment path exists. New active capital only arrives via owner `fund`.
contract MandateAccount is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ types
    enum Mandate {
        Balanced,
        Aggressive
    }

    enum OrderKind {
        None,
        Increase,
        Decrease
    }

    struct Venue {
        address exchangeRouter;
        address router; // GMX Router (token spender for sendTokens)
        address orderVault;
        address dataStore;
        address market; // fixed perp market (ETH/USD [WETH-USDC])
        address swapMarket; // fixed USDT<->USDC swap-only market
        address usdt;
        address usdc;
        address indexPriceFeed; // Chainlink ETH/USD
        address usdtPriceFeed; // Chainlink USDT/USD
        address sequencerFeed;
        uint8 indexTokenDecimals; // WETH = 18
    }

    struct Policy {
        uint16 minReserveBps; // Balanced >= 5000, Aggressive may be 0
        uint32 maxLeverageBps; // 10_000 = 1x
        uint256 maxCollateralPerOrder; // USDT units
        uint256 maxExecutionFeePerOrder; // wei
        uint256 maxFeeSpendWei; // cumulative execution-fee budget for this campaign
        uint8 maxPendingOrders;
        uint8 maxOpenPositions;
        uint16 maxPriceDeviationBps; // acceptablePrice vs Chainlink
        uint16 maxSwapSlippageBps; // USDT->USDC routing inside GMX
        uint32 maxPriceAge; // seconds
    }

    struct BankRule {
        uint256 triggerFreeUsdt; // bank when free realized USDT >= trigger
        uint256 bankAmount; // amount moved into reserve shares
        uint8 remaining; // number of bank events allowed
    }

    struct Pending {
        OrderKind kind;
        bool isLong;
        uint128 collateral; // USDT sent (increase) — 0 for decrease
        uint64 createdAt;
    }

    // ------------------------------------------------------------------ errors/events
    error NotOwner();
    error NotOperator();
    error RiskPaused();
    error ExitRequested();
    error PolicyBreach(string what);
    error UnavailableAtThisSize(string what, uint256 required, uint256 provided);
    error StillPending(bytes32 key);
    error BadToken();
    error OnlyTighten();

    event Funded(uint256 total, uint256 toReserve, uint256 reserveShares, uint256 toActive);
    event OrderSubmitted(bytes32 indexed key, OrderKind kind, bool isLong, uint256 collateral, uint256 sizeDeltaUsd, uint256 acceptablePrice, uint256 executionFee, bytes32 decisionHash, address operator);
    event OrderCancelRequested(bytes32 indexed key, address operator);
    event OrderResolved(bytes32 indexed key, OrderKind kind);
    event ProfitBanked(uint256 usdt, uint256 shares, bytes32 decisionHash);
    event ExitRequestedSet(bool requested);
    event KeeperUpdated(address keeper, bool enabled);
    event PolicyTightened(Policy policy);
    event BankRuleSet(BankRule rule);
    event OwnershipTransferred(address indexed from, address indexed to);
    event ReserveWithdrawn(uint256 shares, uint256 assets);
    event ActiveWithdrawn(address token, uint256 amount);

    uint256 internal constant BPS = 10_000;

    // ------------------------------------------------------------------ state
    Mandate public immutable mandate;
    address public immutable factory;
    ConservativeVault public immutable reserveVault;

    address public owner;
    address public keeper;
    bool public keeperEnabled;
    bool public exitRequested;
    uint256 public feeSpentWei;
    uint256 public activeContributed; // cumulative USDT owner authorized for speculation
    uint256 public reserveContributed; // cumulative USDT owner put in reserve (incl. banked)
    uint256 public bankedTotal;

    Venue internal _venue;
    Policy internal _policy;
    BankRule public bankRule;

    mapping(bytes32 => Pending) public pending;
    bytes32[] internal _pendingKeys;

    constructor(
        Mandate mandate_,
        address owner_,
        address keeper_,
        ConservativeVault reserveVault_,
        Venue memory venue_,
        Policy memory policy_
    ) {
        if (mandate_ == Mandate.Balanced && policy_.minReserveBps < 5000) revert PolicyBreach("balanced reserve");
        if (address(reserveVault_) != address(0) && reserveVault_.asset() != venue_.usdt) revert BadToken();
        if (mandate_ == Mandate.Balanced && address(reserveVault_) == address(0)) revert PolicyBreach("reserve vault");
        mandate = mandate_;
        factory = msg.sender;
        owner = owner_;
        keeper = keeper_;
        keeperEnabled = keeper_ != address(0);
        reserveVault = reserveVault_;
        _venue = venue_;
        _policy = policy_;
    }

    receive() external payable {} // GMX execution-fee refunds and owner fee deposits

    // ------------------------------------------------------------------ modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != owner && !(msg.sender == keeper && keeperEnabled)) revert NotOperator();
        _;
    }

    modifier newRiskAllowed() {
        if (IRiskPauseSource(factory).riskPaused()) revert RiskPaused();
        if (exitRequested) revert ExitRequested();
        _;
    }

    // ------------------------------------------------------------------ views
    function venue() external view returns (Venue memory) {
        return _venue;
    }

    function policy() external view returns (Policy memory) {
        return _policy;
    }

    function pendingKeys() external view returns (bytes32[] memory) {
        return _pendingKeys;
    }

    function freeUsdt() public view returns (uint256) {
        return IERC20(_venue.usdt).balanceOf(address(this));
    }

    function reserveShares() public view returns (uint256) {
        return address(reserveVault) == address(0) ? 0 : reserveVault.balanceOf(address(this));
    }

    function reserveAssets() external view returns (uint256) {
        return address(reserveVault) == address(0) ? 0 : reserveVault.previewRedeem(reserveShares());
    }

    function gmxPositionCount() public view returns (uint256) {
        return IGmxDataStore(_venue.dataStore).getBytes32Count(GmxKeys.accountPositionListKey(address(this)));
    }

    function gmxOrderCount() public view returns (uint256) {
        return IGmxDataStore(_venue.dataStore).getBytes32Count(GmxKeys.accountOrderListKey(address(this)));
    }

    // ------------------------------------------------------------------ funding (owner-only authorization)

    /// @notice Owner contributes USDT. `reserveBps` of it becomes reserve shares; the rest is active capital.
    /// The split is per contribution and never re-balanced afterwards.
    function fund(uint256 amount, uint16 reserveBps, uint256 minReserveShares, uint256 deadline)
        external
        payable
        onlyOwner
        nonReentrant
    {
        if (reserveBps < _policy.minReserveBps || reserveBps > BPS) revert PolicyBreach("reserveBps");
        uint256 toReserve = amount * reserveBps / BPS;
        uint256 toActive = amount - toReserve;
        if (toActive > 0 && IRiskPauseSource(factory).riskPaused()) revert RiskPaused();
        IERC20 usdt = IERC20(_venue.usdt);
        uint256 before = usdt.balanceOf(address(this));
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        if (usdt.balanceOf(address(this)) - before != amount) revert BadToken();
        uint256 shares;
        if (toReserve > 0) {
            usdt.forceApprove(address(reserveVault), toReserve);
            shares = reserveVault.depositChecked(toReserve, address(this), minReserveShares, deadline);
            usdt.forceApprove(address(reserveVault), 0);
            reserveContributed += toReserve;
        }
        activeContributed += toActive;
        emit Funded(amount, toReserve, shares, toActive);
    }

    // ------------------------------------------------------------------ GMX execution (operator)

    struct IncreaseParams {
        bool isLong;
        uint256 collateral; // USDT units
        uint256 sizeDeltaUsd; // 1e30 USD
        uint256 acceptablePrice; // GMX contract price format
        uint256 executionFee; // wei
        bytes32 decisionHash;
    }

    struct DecreaseParams {
        bool isLong;
        uint256 sizeDeltaUsd;
        uint256 collateralDelta; // USDC units of position collateral to withdraw
        uint256 acceptablePrice;
        uint256 minOutUsdt;
        uint256 executionFee;
        bytes32 decisionHash;
    }

    /// @notice GMX contract price for the index token from Chainlink: price30 / 10**indexDecimals.
    function referencePrice() public view returns (uint256) {
        uint256 p8 = OracleGuard.read(_venue.indexPriceFeed, _venue.sequencerFeed, _policy.maxPriceAge);
        // price30 = p8 * 1e22 ; contract = price30 / 10**dec
        return p8 * 1e22 / (10 ** _venue.indexTokenDecimals);
    }

    function _collateralUsd30(uint256 usdtAmount) internal view returns (uint256) {
        uint256 p8 = OracleGuard.read(_venue.usdtPriceFeed, _venue.sequencerFeed, 1 days + 1 hours);
        // usdt has 6 decimals: usd30 = amount * p8 * 1e(30-6-8)
        return usdtAmount * p8 * 1e16;
    }

    function openOrIncrease(IncreaseParams calldata p)
        external
        onlyOperator
        newRiskAllowed
        nonReentrant
        returns (bytes32 key)
    {
        Policy memory pol = _policy;
        Venue memory v = _venue;
        if (p.collateral == 0 || p.collateral > pol.maxCollateralPerOrder) revert PolicyBreach("collateral");
        if (p.collateral > freeUsdt()) revert PolicyBreach("insufficient active funds");
        _checkFee(p.executionFee, true);
        if (_pendingKeys.length >= pol.maxPendingOrders) revert PolicyBreach("pending orders");
        if (gmxPositionCount() > pol.maxOpenPositions) revert PolicyBreach("open positions");

        uint256 collUsd = _collateralUsd30(p.collateral);
        if (p.sizeDeltaUsd * BPS > collUsd * pol.maxLeverageBps) revert PolicyBreach("leverage");
        IGmxDataStore ds = IGmxDataStore(v.dataStore);
        uint256 minColl = ds.getUint(GmxKeys.MIN_COLLATERAL_USD);
        uint256 minSize = ds.getUint(GmxKeys.MIN_POSITION_SIZE_USD);
        if (collUsd < minColl) revert UnavailableAtThisSize("min collateral usd", minColl, collUsd);
        if (p.sizeDeltaUsd < minSize) revert UnavailableAtThisSize("min position usd", minSize, p.sizeDeltaUsd);

        uint256 ref = referencePrice();
        if (p.isLong) {
            if (p.acceptablePrice * BPS > ref * (BPS + pol.maxPriceDeviationBps)) revert PolicyBreach("price");
        } else {
            if (p.acceptablePrice * BPS < ref * (BPS - pol.maxPriceDeviationBps)) revert PolicyBreach("price");
        }

        address[] memory path = new address[](1);
        path[0] = v.swapMarket;
        GmxOrder.CreateOrderParams memory params = GmxOrder.CreateOrderParams({
            addresses: GmxOrder.CreateOrderParamsAddresses({
                receiver: address(this),
                cancellationReceiver: address(this),
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: v.market,
                initialCollateralToken: v.usdt,
                swapPath: path
            }),
            numbers: GmxOrder.CreateOrderParamsNumbers({
                sizeDeltaUsd: p.sizeDeltaUsd,
                initialCollateralDeltaAmount: p.collateral,
                triggerPrice: 0,
                acceptablePrice: p.acceptablePrice,
                executionFee: p.executionFee,
                callbackGasLimit: 0,
                minOutputAmount: p.collateral * (BPS - pol.maxSwapSlippageBps) / BPS,
                validFromTime: 0
            }),
            orderType: GmxOrder.OrderType.MarketIncrease,
            decreasePositionSwapType: GmxOrder.DecreasePositionSwapType.NoSwap,
            isLong: p.isLong,
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            referralCode: bytes32(0),
            dataList: new bytes32[](0)
        });

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(IGmxExchangeRouter.sendWnt, (v.orderVault, p.executionFee));
        calls[1] = abi.encodeCall(IGmxExchangeRouter.sendTokens, (v.usdt, v.orderVault, p.collateral));
        calls[2] = abi.encodeCall(IGmxExchangeRouter.createOrder, (params));

        IERC20(v.usdt).forceApprove(v.router, p.collateral);
        bytes[] memory res = IGmxExchangeRouter(v.exchangeRouter).multicall{value: p.executionFee}(calls);
        IERC20(v.usdt).forceApprove(v.router, 0);
        key = abi.decode(res[2], (bytes32));

        feeSpentWei += p.executionFee;
        pending[key] = Pending(OrderKind.Increase, p.isLong, uint128(p.collateral), uint64(block.timestamp));
        _pendingKeys.push(key);
        emit OrderSubmitted(key, OrderKind.Increase, p.isLong, p.collateral, p.sizeDeltaUsd, p.acceptablePrice, p.executionFee, p.decisionHash, msg.sender);
    }

    /// @notice Reduce/close. Allowed while risk is paused and after an exit request (risk-reducing).
    function decrease(DecreaseParams calldata p) external onlyOperator nonReentrant returns (bytes32 key) {
        Policy memory pol = _policy;
        Venue memory v = _venue;
        _checkFee(p.executionFee, false);
        if (_pendingKeys.length >= pol.maxPendingOrders + 2) revert PolicyBreach("pending orders");
        uint256 ref = referencePrice();
        // closing a long sells: acceptable must not be far BELOW reference; closing a short buys.
        if (p.isLong) {
            if (p.acceptablePrice * BPS < ref * (BPS - pol.maxPriceDeviationBps)) revert PolicyBreach("price");
        } else {
            if (p.acceptablePrice * BPS > ref * (BPS + pol.maxPriceDeviationBps)) revert PolicyBreach("price");
        }

        address[] memory path = new address[](1);
        path[0] = v.swapMarket;
        GmxOrder.CreateOrderParams memory params = GmxOrder.CreateOrderParams({
            addresses: GmxOrder.CreateOrderParamsAddresses({
                receiver: address(this),
                cancellationReceiver: address(this),
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: v.market,
                initialCollateralToken: v.usdc, // position collateral token after the entry swap
                swapPath: path // output USDC -> USDT
            }),
            numbers: GmxOrder.CreateOrderParamsNumbers({
                sizeDeltaUsd: p.sizeDeltaUsd,
                initialCollateralDeltaAmount: p.collateralDelta,
                triggerPrice: 0,
                acceptablePrice: p.acceptablePrice,
                executionFee: p.executionFee,
                callbackGasLimit: 0,
                minOutputAmount: p.minOutUsdt,
                validFromTime: 0
            }),
            orderType: GmxOrder.OrderType.MarketDecrease,
            decreasePositionSwapType: GmxOrder.DecreasePositionSwapType.SwapPnlTokenToCollateralToken,
            isLong: p.isLong,
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            referralCode: bytes32(0),
            dataList: new bytes32[](0)
        });

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IGmxExchangeRouter.sendWnt, (v.orderVault, p.executionFee));
        calls[1] = abi.encodeCall(IGmxExchangeRouter.createOrder, (params));
        bytes[] memory res = IGmxExchangeRouter(v.exchangeRouter).multicall{value: p.executionFee}(calls);
        key = abi.decode(res[1], (bytes32));

        feeSpentWei += p.executionFee;
        pending[key] = Pending(OrderKind.Decrease, p.isLong, 0, uint64(block.timestamp));
        _pendingKeys.push(key);
        emit OrderSubmitted(key, OrderKind.Decrease, p.isLong, 0, p.sizeDeltaUsd, p.acceptablePrice, p.executionFee, p.decisionHash, msg.sender);
    }

    function cancelOrder(bytes32 key) external onlyOperator nonReentrant {
        if (pending[key].kind == OrderKind.None) revert PolicyBreach("unknown order");
        IGmxExchangeRouter(_venue.exchangeRouter).cancelOrder(key);
        emit OrderCancelRequested(key, msg.sender);
    }

    /// @notice Permissionless, idempotent reconciliation from GMX DataStore state.
    /// An order absent from ORDER_LIST has been executed or cancelled; funds/positions are then
    /// observable directly (token balances here / position list). Returns false if nothing to do.
    function reconcile(bytes32 key) public returns (bool) {
        Pending memory pd = pending[key];
        if (pd.kind == OrderKind.None) return false;
        if (IGmxDataStore(_venue.dataStore).containsBytes32(GmxKeys.ORDER_LIST, key)) revert StillPending(key);
        delete pending[key];
        uint256 n = _pendingKeys.length;
        for (uint256 i; i < n; ++i) {
            if (_pendingKeys[i] == key) {
                _pendingKeys[i] = _pendingKeys[n - 1];
                _pendingKeys.pop();
                break;
            }
        }
        emit OrderResolved(key, pd.kind);
        return true;
    }

    function _checkFee(uint256 fee, bool isIncrease) internal view {
        Policy memory pol = _policy;
        if (fee > pol.maxExecutionFeePerOrder) revert PolicyBreach("fee per order");
        if (fee > address(this).balance) revert PolicyBreach("fee balance");
        // Increases must leave budget for at least one closing order. Owner may always pay to reduce risk.
        uint256 needed = feeSpentWei + fee + (isIncrease ? pol.maxExecutionFeePerOrder : 0);
        if (needed > pol.maxFeeSpendWei && !(msg.sender == owner && !isIncrease)) revert PolicyBreach("fee budget");
    }

    // ------------------------------------------------------------------ profit banking

    function setBankRule(BankRule calldata r) external onlyOwner {
        if (address(reserveVault) == address(0) || r.bankAmount > r.triggerFreeUsdt) revert PolicyBreach("bank rule");
        bankRule = r;
        emit BankRuleSet(r);
    }

    /// @notice Move realized, withdrawable USDT into reserve shares per the owner's rule.
    /// Risk-reducing; operator may call it. Only free USDT balance counts — never unrealized marks.
    function bankProfit(uint256 minShares, uint256 deadline, bytes32 decisionHash)
        external
        onlyOperator
        nonReentrant
        returns (uint256 shares)
    {
        BankRule memory r = bankRule;
        if (r.remaining == 0) revert PolicyBreach("no bank events left");
        if (freeUsdt() < r.triggerFreeUsdt) revert PolicyBreach("trigger not reached");
        bankRule.remaining = r.remaining - 1;
        IERC20(_venue.usdt).forceApprove(address(reserveVault), r.bankAmount);
        shares = reserveVault.depositChecked(r.bankAmount, address(this), minShares, deadline);
        IERC20(_venue.usdt).forceApprove(address(reserveVault), 0);
        bankedTotal += r.bankAmount;
        reserveContributed += r.bankAmount;
        emit ProfitBanked(r.bankAmount, shares, decisionHash);
    }

    // ------------------------------------------------------------------ owner controls & exits (no AI/keeper needed)

    function requestExit() external onlyOwner {
        exitRequested = true;
        emit ExitRequestedSet(true);
    }

    function clearExit() external onlyOwner {
        exitRequested = false;
        emit ExitRequestedSet(false);
    }

    function setKeeper(address k, bool enabled) external onlyOwner {
        keeper = k;
        keeperEnabled = enabled && k != address(0);
        emit KeeperUpdated(k, keeperEnabled);
    }

    /// @notice Owner may only tighten risk parameters.
    function tightenPolicy(uint32 maxLeverageBps, uint256 maxCollateralPerOrder, uint256 maxFeeSpendWei, uint8 maxOpenPositions)
        external
        onlyOwner
    {
        Policy storage p = _policy;
        if (
            maxLeverageBps > p.maxLeverageBps || maxCollateralPerOrder > p.maxCollateralPerOrder
                || maxFeeSpendWei > p.maxFeeSpendWei || maxOpenPositions > p.maxOpenPositions
        ) revert OnlyTighten();
        p.maxLeverageBps = maxLeverageBps;
        p.maxCollateralPerOrder = maxCollateralPerOrder;
        p.maxFeeSpendWei = maxFeeSpendWei;
        p.maxOpenPositions = maxOpenPositions;
        emit PolicyTightened(p);
    }

    /// @notice Redeem reserve shares to the owner. Works while risk is paused; never via keeper.
    function withdrawReserve(uint256 shares, uint256 minAssets, uint256 deadline)
        external
        onlyOwner
        nonReentrant
        returns (uint256 assets)
    {
        assets = reserveVault.redeemChecked(shares, owner, address(this), minAssets, deadline);
        emit ReserveWithdrawn(shares, assets);
    }

    /// @notice Withdraw settled active-side tokens (USDT/USDC/WETH, or anything GMX returned) to the owner.
    function withdrawToken(address token, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(reserveVault)) revert BadToken(); // reserve exits go through withdrawReserve
        IERC20(token).safeTransfer(owner, amount);
        emit ActiveWithdrawn(token, amount);
    }

    function withdrawEth(uint256 amount) external onlyOwner nonReentrant {
        (bool ok,) = owner.call{value: amount}("");
        require(ok, "eth");
        emit ActiveWithdrawn(address(0), amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert NotOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
