// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConservativeVault} from "../../src/ConservativeVault.sol";
import {ConservativeVaultFactory} from "../../src/factories/ConservativeVaultFactory.sol";
import {Arb} from "../utils/Arbitrum.sol";

/// @notice REAL integration: Arbitrum fork @ pinned block, real USD₮0, real Aave V3 Pool + aToken.
/// Accrual comes from Aave's own liquidity-index math when time advances (no mocked rates).
/// Test scaffolding disclosed: `deal` writes USD₮0 balances; vm.warp/roll advance time.
contract ConservativeAaveForkTest is Test {
    ConservativeVaultFactory factory;
    ConservativeVault vault;
    address curator = makeAddr("curator");
    address guardian = makeAddr("guardian");
    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    bytes32 constant AAVE_USDT = keccak256("aave-v3-arbitrum-usdt0");

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), Arb.FORK_BLOCK);
        factory = new ConservativeVaultFactory(curator, guardian);
        vm.prank(curator);
        factory.setIntegration(AAVE_USDT, ConservativeVaultFactory.AaveIntegration(Arb.USDT, Arb.AAVE_POOL, Arb.AAVE_aUSDT, true));
        vm.prank(makeAddr("anyone"));
        vault = factory.createVault(AAVE_USDT, "PM Conservative USDT", "pmcUSDT", admin, keeper, 1000, 9000);
        deal(Arb.USDT, alice, 500e6);
        deal(Arb.USDT, bob, 50e6);
    }

    function _deposit(address u, uint256 a) internal returns (uint256 s) {
        vm.startPrank(u);
        IERC20(Arb.USDT).approve(address(vault), a);
        s = vault.depositChecked(a, u, 1, vm.getBlockTimestamp() + 60);
        vm.stopPrank();
    }

    function test_fork_twoUsers_allocate_accrue_redeem() public {
        assertFalse(factory.reviewed(address(vault)), "new vault must not be auto-reviewed");
        uint256 sa = _deposit(alice, 500e6);
        uint256 sb = _deposit(bob, 50e6);
        assertEq(vault.totalAssets(), 550e6);

        // keeper allocates 90% to Aave (cap), leaving the 10% idle floor
        vm.prank(keeper);
        vault.allocate(495e6, keccak256("decision-1"));
        uint256 aBal = IERC20(Arb.AAVE_aUSDT).balanceOf(address(vault.adapter()));
        assertApproxEqAbs(aBal, 495e6, 1, "aToken received");
        // policy: cannot exceed adapter cap
        vm.prank(keeper);
        vm.expectRevert(ConservativeVault.PolicyViolation.selector);
        vault.allocate(1e6, bytes32(0));

        uint256 navBefore = vault.totalAssets();
        // advance 30 days; Aave accrues via its own index math
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.roll(block.number + 1);
        uint256 navAfter = vault.totalAssets();
        assertGt(navAfter, navBefore, "real Aave accrual must increase NAV");
        console2.log("NAV before (USDT 6dp)", navBefore);
        console2.log("NAV after 30d        ", navAfter);
        console2.log("30d gain (6dp)       ", navAfter - navBefore);

        uint256 bobValueBefore = vault.previewRedeem(sb);
        // alice fully redeems — requires pulling from Aave beyond idle
        vm.prank(alice);
        uint256 out = vault.redeemChecked(sa, alice, alice, 500e6, vm.getBlockTimestamp() + 60);
        assertGt(out, 500e6, "alice receives principal + accrued share");
        assertEq(IERC20(Arb.USDT).balanceOf(alice), out);
        // bob's entitlement unchanged by alice's exit (rounding favours the vault)
        uint256 bobValueAfter = vault.previewRedeem(sb);
        assertGe(bobValueAfter + 1, bobValueBefore, "remaining holder not diluted");
        vm.prank(bob);
        uint256 bobOut = vault.redeem(sb, bob, bob);
        assertGt(bobOut, 50e6);
        assertLe(vault.totalAssets(), 2, "only rounding dust remains");
    }

    function test_fork_pause_blocks_deposit_but_not_withdraw() public {
        uint256 sa = _deposit(alice, 100e6);
        vm.prank(keeper);
        vault.allocate(80e6, bytes32(0));
        vm.prank(guardian);
        vault.setPaused(true);
        vm.startPrank(bob);
        IERC20(Arb.USDT).approve(address(vault), 10e6);
        vm.expectRevert();
        vault.deposit(10e6, bob);
        vm.stopPrank();
        vm.prank(alice);
        uint256 out = vault.redeem(sa, alice, alice);
        assertApproxEqAbs(out, 100e6, 1);
    }
}
