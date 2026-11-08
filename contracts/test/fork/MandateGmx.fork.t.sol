// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConservativeVault} from "../../src/ConservativeVault.sol";
import {ConservativeVaultFactory} from "../../src/factories/ConservativeVaultFactory.sol";
import {MandateAccount} from "../../src/MandateAccount.sol";
import {MandateAccountFactory} from "../../src/factories/MandateAccountFactory.sol";
import {GmxKeys} from "../../src/interfaces/external/IGmx.sol";
import {IAggregatorV3} from "../../src/interfaces/external/IChainlink.sol";
import {Arb} from "../utils/Arbitrum.sol";

interface IGmxOrderHandler {
    struct SetPricesParams {
        address[] tokens;
        address[] providers;
        bytes[] data;
    }

    function executeOrder(bytes32 key, SetPricesParams calldata oracleParams) external;
}

interface IDS {
    function setAddress(bytes32 key, address value) external returns (address);
    function getBytes32Count(bytes32) external view returns (uint256);
}

/// @notice REAL GMX V2 integration on an Arbitrum fork (pinned block).
/// Real: ExchangeRouter.createOrder, OrderVault custody, DataStore order/position state,
///       OrderHandler.executeOrder -> real IncreaseOrderUtils/DecreaseOrderUtils/SwapUtils, real fees.
/// PRIVILEGED TEST SCAFFOLDING (disclosed, test-only):
///   1. ORACLE_PROVIDER_FOR_TOKEN for WETH/USDC/USDT is switched from ChainlinkDataStreamProvider
///      (signed off-chain reports we cannot produce) to GMX's own deployed ChainlinkPriceFeedProvider,
///      which reads the same on-chain Chainlink feeds GMX already configures for these tokens.
///      Done by impersonating a GMX CONTROLLER (the ExchangeRouter) to write DataStore.
///   2. A real GMX ORDER_KEEPER address is impersonated to call executeOrder.
///   3. `deal` mints USD₮0 test balances.
///   4. Loss scenario only: the ETH/USD Chainlink aggregator answer is mocked (deterministic price
///      scenario — NOT market evidence).
contract MandateGmxForkTest is Test {
    ConservativeVault reserve;
    MandateAccountFactory mFactory;
    address curator = makeAddr("curator");
    address guardian = makeAddr("guardian");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice"); // Balanced user
    address carol = makeAddr("carol"); // Aggressive user

    uint256 constant FEE = 0.0005 ether;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), Arb.FORK_BLOCK);
        vm.txGasPrice(0.02 gwei);

        ConservativeVaultFactory vf = new ConservativeVaultFactory(curator, guardian);
        bytes32 id = keccak256("aave-v3-arbitrum-usdt0");
        vm.prank(curator);
        vf.setIntegration(id, ConservativeVaultFactory.AaveIntegration(Arb.USDT, Arb.AAVE_POOL, Arb.AAVE_aUSDT, true));
        reserve = vf.createVault(id, "PM Reserve USDT", "pmrUSDT", curator, keeper, 1000, 9000);

        mFactory = new MandateAccountFactory(curator, guardian, keeper, reserve);
        vm.startPrank(curator);
        mFactory.setVenue(_venue());
        mFactory.setCeiling(MandateAccount.Mandate.Balanced, _policy(5000, 30_000));
        mFactory.setCeiling(MandateAccount.Mandate.Aggressive, _policy(0, 50_000));
        vm.stopPrank();

        _useOnchainChainlinkProvider();
    }

    // ------------------------------------------------------------ config
    function _venue() internal pure returns (MandateAccount.Venue memory) {
        return MandateAccount.Venue({
            exchangeRouter: Arb.GMX_EXCHANGE_ROUTER,
            router: Arb.GMX_ROUTER,
            orderVault: Arb.GMX_ORDER_VAULT,
            dataStore: Arb.GMX_DATASTORE,
            market: Arb.GMX_ETH_USD_MARKET,
            swapMarket: Arb.GMX_USDC_USDT_SWAP,
            usdt: Arb.USDT,
            usdc: Arb.USDC,
            indexPriceFeed: Arb.CL_ETH_USD,
            usdtPriceFeed: Arb.CL_USDT_USD,
            sequencerFeed: Arb.CL_SEQUENCER,
            indexTokenDecimals: 18
        });
    }

    function _policy(uint16 minReserve, uint32 lev) internal pure returns (MandateAccount.Policy memory) {
        return MandateAccount.Policy({
            minReserveBps: minReserve,
            maxLeverageBps: lev,
            maxCollateralPerOrder: 50e6,
            maxExecutionFeePerOrder: 0.002 ether,
            maxFeeSpendWei: 0.02 ether,
            maxPendingOrders: 2,
            maxOpenPositions: 1,
            maxPriceDeviationBps: 100,
            maxSwapSlippageBps: 50,
            maxPriceAge: 1 hours
        });
    }

    function _useOnchainChainlinkProvider() internal {
        bytes32 OPT = keccak256(abi.encode("ORACLE_PROVIDER_FOR_TOKEN"));
        address[3] memory toks = [Arb.WETH, Arb.USDC, Arb.USDT];
        vm.startPrank(Arb.GMX_EXCHANGE_ROUTER); // a live CONTROLLER
        for (uint256 i; i < 3; ++i) {
            IDS(Arb.GMX_DATASTORE).setAddress(keccak256(abi.encode(OPT, Arb.GMX_ORACLE, toks[i])), Arb.GMX_CL_PRICEFEED_PROVIDER);
        }
        vm.stopPrank();
    }

    function _execute(bytes32 key) internal {
        IGmxOrderHandler.SetPricesParams memory p;
        p.tokens = new address[](3);
        p.providers = new address[](3);
        p.data = new bytes[](3);
        p.tokens[0] = Arb.WETH;
        p.tokens[1] = Arb.USDC;
        p.tokens[2] = Arb.USDT;
        for (uint256 i; i < 3; ++i) p.providers[i] = Arb.GMX_CL_PRICEFEED_PROVIDER;
        vm.prank(Arb.GMX_ORDER_KEEPER);
        IGmxOrderHandler(Arb.GMX_ORDER_HANDLER).executeOrder(key, p);
    }

    function _newAccount(address user, MandateAccount.Mandate m, uint16 minRes, uint32 lev)
        internal
        returns (MandateAccount a)
    {
        vm.prank(user);
        a = mFactory.createAccount(m, _policy(minRes, lev));
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(a).call{value: 0.01 ether}("");
        assertTrue(ok);
    }

    function _fund(MandateAccount a, address user, uint256 amt, uint16 resBps) internal {
        deal(Arb.USDT, user, amt);
        vm.startPrank(user);
        IERC20(Arb.USDT).approve(address(a), amt);
        a.fund(amt, resBps, 0, vm.getBlockTimestamp() + 60);
        vm.stopPrank();
    }

    function _open(MandateAccount a, address op, uint256 coll, uint256 sizeUsd30) internal returns (bytes32 key) {
        uint256 ref = a.referencePrice();
        vm.prank(op);
        key = a.openOrIncrease(MandateAccount.IncreaseParams(true, coll, sizeUsd30, ref * 10_050 / 10_000, FEE, keccak256("open")));
    }

    function _close(MandateAccount a, address op, uint256 sizeUsd30) internal returns (bytes32 key) {
        uint256 ref = a.referencePrice();
        vm.prank(op);
        key = a.decrease(MandateAccount.DecreaseParams(true, sizeUsd30, 0, ref * 9_950 / 10_000, 0, FEE, keccak256("close")));
    }

    // ------------------------------------------------------------ Balanced: profit-path lifecycle
    function test_fork_balanced_open_execute_close_withdraw() public {
        MandateAccount a = _newAccount(alice, MandateAccount.Mandate.Balanced, 5000, 30_000);
        _fund(a, alice, 50e6, 5000);
        uint256 resShares = a.reserveShares();
        assertEq(a.freeUsdt(), 25e6, "active sleeve = 25");
        assertGt(resShares, 0);

        // keeper opens 2x long: 25 USDT collateral, $50 size
        bytes32 k1 = _open(a, keeper, 25e6, 50e30);
        assertTrue(IDS(Arb.GMX_DATASTORE).getBytes32Count(GmxKeys.accountOrderListKey(address(a))) == 1, "order created on GMX");
        assertEq(a.freeUsdt(), 0);
        _execute(k1);
        assertEq(a.gmxPositionCount(), 1, "real GMX position exists");
        assertTrue(a.reconcile(k1));
        assertFalse(a.reconcile(k1), "idempotent");

        // owner requests exit -> keeper cannot add risk, but can close
        vm.prank(alice);
        a.requestExit();
        uint256 ref = a.referencePrice();
        vm.prank(keeper);
        vm.expectRevert(MandateAccount.ExitRequested.selector);
        a.openOrIncrease(MandateAccount.IncreaseParams(true, 1e6, 2e30, ref * 10_050 / 10_000, FEE, bytes32(0)));

        bytes32 k2 = _close(a, keeper, 50e30);
        _execute(k2);
        a.reconcile(k2);
        assertEq(a.gmxPositionCount(), 0, "position closed");
        uint256 back = a.freeUsdt();
        console2.log("active USDT after open+close (6dp):", back);
        assertGt(back, 24e6, "round trip returns collateral minus real fees/impact");
        assertLt(back, 25e6 + 1e6);
        assertEq(a.reserveShares(), resShares, "reserve untouched by trading");

        // owner exits fully without keeper/AI
        vm.startPrank(alice);
        a.withdrawToken(Arb.USDT, back);
        a.withdrawReserve(resShares, 24e6, vm.getBlockTimestamp() + 60);
        vm.stopPrank();
        assertGt(IERC20(Arb.USDT).balanceOf(alice), 49e6);
        console2.log("alice final USDT (6dp):", IERC20(Arb.USDT).balanceOf(alice));
    }

    // ------------------------------------------------------------ Balanced: loss scenario + reserve isolation
    function test_fork_balanced_loss_cannot_touch_reserve() public {
        MandateAccount a = _newAccount(alice, MandateAccount.Mandate.Balanced, 5000, 30_000);
        _fund(a, alice, 50e6, 5000);
        uint256 resShares = a.reserveShares();
        bytes32 k1 = _open(a, keeper, 25e6, 74e30); // ~2.96x (USDT priced via Chainlink, not hardcoded $1)
        _execute(k1);
        a.reconcile(k1);

        // DETERMINISTIC SCENARIO: ETH -20% (mocked aggregator answer; not market evidence)
        (, int256 px,,,) = IAggregatorV3(Arb.CL_ETH_USD).latestRoundData();
        int256 down = px * 80 / 100;
        vm.mockCall(
            Arb.CL_ETH_USD,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), down, vm.getBlockTimestamp(), vm.getBlockTimestamp(), uint80(1))
        );

        bytes32 k2 = _close(a, keeper, 74e30);
        _execute(k2);
        a.reconcile(k2);
        uint256 back = a.freeUsdt();
        console2.log("active USDT after -20% scenario at 3x (6dp):", back);
        assertLt(back, 12e6, "~60% loss plus fees");

        // keeper cannot reach reserve: no path exists; owner-only functions revert for keeper
        vm.startPrank(keeper);
        vm.expectRevert(MandateAccount.NotOwner.selector);
        a.withdrawReserve(resShares, 0, vm.getBlockTimestamp() + 60);
        vm.expectRevert(MandateAccount.NotOwner.selector);
        a.withdrawToken(address(reserve), 1);
        vm.expectRevert(); // collateral > free active funds; reserve is not spendable
        a.openOrIncrease(MandateAccount.IncreaseParams(true, 20e6, 20e30, uint256(down) * 1e4 * 10_050 / 10_000, FEE, bytes32(0)));
        vm.stopPrank();
        assertEq(a.reserveShares(), resShares, "reserve shares unchanged after loss");
        assertGe(a.reserveAssets(), 25e6 - 1, "reserve value intact");
    }

    // ------------------------------------------------------------ Aggressive: full-capital, isolation, recovery w/o keeper
    function test_fork_aggressive_isolated_and_owner_recovery() public {
        MandateAccount bal = _newAccount(alice, MandateAccount.Mandate.Balanced, 5000, 30_000);
        _fund(bal, alice, 50e6, 5000);
        MandateAccount agg = _newAccount(carol, MandateAccount.Mandate.Aggressive, 0, 50_000);
        _fund(agg, carol, 50e6, 0);
        assertEq(agg.freeUsdt(), 50e6, "aggressive: 100% active");
        assertEq(agg.reserveShares(), 0);

        // Balanced ceiling forbids reserve below 50%
        vm.prank(alice);
        vm.expectRevert();
        bal.fund(0, 4000, 0, vm.getBlockTimestamp() + 60);

        bytes32 k = _open(agg, keeper, 50e6, 200e30); // 4x within 5x ceiling
        _execute(k);
        agg.reconcile(k);
        assertEq(agg.gmxPositionCount(), 1);
        assertEq(bal.gmxPositionCount(), 0, "isolated GMX accounts");

        // keeper disappears: owner revokes keeper and closes position herself
        vm.prank(carol);
        agg.setKeeper(address(0), false);
        vm.prank(keeper);
        vm.expectRevert(MandateAccount.NotOperator.selector);
        agg.decrease(MandateAccount.DecreaseParams(true, 200e30, 0, 1, 0, FEE, bytes32(0)));
        bytes32 k2 = _close(agg, carol, 200e30);
        _execute(k2); // GMX protocol keeper still required for execution (documented external dependency)
        agg.reconcile(k2);
        uint256 back = agg.freeUsdt();
        console2.log("aggressive USDT after owner-driven close (6dp):", back);
        vm.prank(carol);
        agg.withdrawToken(Arb.USDT, back);
        assertEq(IERC20(Arb.USDT).balanceOf(carol), back);
    }

    // ------------------------------------------------------------ policy: unavailable sizes / leverage / pause
    function test_fork_policy_limits() public {
        MandateAccount a = _newAccount(alice, MandateAccount.Mandate.Balanced, 5000, 30_000);
        _fund(a, alice, 50e6, 5000);
        uint256 ref = a.referencePrice();
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(MandateAccount.PolicyBreach.selector, "leverage"));
        a.openOrIncrease(MandateAccount.IncreaseParams(true, 10e6, 40e30, ref, FEE, bytes32(0)));
        vm.expectRevert(abi.encodeWithSelector(MandateAccount.PolicyBreach.selector, "price"));
        a.openOrIncrease(MandateAccount.IncreaseParams(true, 10e6, 20e30, ref * 11 / 10, FEE, bytes32(0)));
        vm.stopPrank();
        vm.prank(guardian);
        mFactory.setRiskPaused(true);
        vm.prank(keeper);
        vm.expectRevert(MandateAccount.RiskPaused.selector);
        a.openOrIncrease(MandateAccount.IncreaseParams(true, 10e6, 20e30, ref, FEE, bytes32(0)));
        // user can still exit reserve while paused
        uint256 s = a.reserveShares();
        vm.prank(alice);
        a.withdrawReserve(s, 0, vm.getBlockTimestamp() + 60);
    }
    // ------------------------------------------------------------ Balanced: staged profit banking (scenario)
    function test_fork_balanced_profit_banking_realized_only() public {
        MandateAccount a = _newAccount(alice, MandateAccount.Mandate.Balanced, 5000, 30_000);
        _fund(a, alice, 50e6, 5000);
        uint256 res0 = a.reserveAssets();
        // staged rule: when realized free USDT >= 50, bank 25 into reserve (once)
        vm.prank(alice);
        a.setBankRule(MandateAccount.BankRule({triggerFreeUsdt: 50e6, bankAmount: 25e6, remaining: 1}));

        bytes32 k1 = _open(a, keeper, 25e6, 74e30);
        _execute(k1);
        a.reconcile(k1);
        // open position marked up does NOT count: free USDT is 0 -> banking must fail
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(MandateAccount.PolicyBreach.selector, "trigger not reached"));
        a.bankProfit(0, vm.getBlockTimestamp() + 60, bytes32(0));

        // DETERMINISTIC SCENARIO: ETH +40% (mocked aggregator; not market evidence)
        (, int256 px,,,) = IAggregatorV3(Arb.CL_ETH_USD).latestRoundData();
        vm.mockCall(
            Arb.CL_ETH_USD,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), px * 140 / 100, vm.getBlockTimestamp(), vm.getBlockTimestamp(), uint80(1))
        );
        bytes32 k2 = _close(a, keeper, 74e30);
        _execute(k2);
        a.reconcile(k2);
        uint256 realized = a.freeUsdt();
        console2.log("realized active USDT after +40% scenario (6dp):", realized);
        assertGe(realized, 50e6, "scenario doubles the active stake net of real fees");

        vm.prank(keeper);
        a.bankProfit(0, vm.getBlockTimestamp() + 60, keccak256("bank-1"));
        assertEq(a.freeUsdt(), realized - 25e6, "25 banked from realized funds");
        assertApproxEqAbs(a.reserveAssets(), res0 + 25e6, 2, "reserve grew by banked amount");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(MandateAccount.PolicyBreach.selector, "no bank events left"));
        a.bankProfit(0, vm.getBlockTimestamp() + 60, bytes32(0));
    }
}
