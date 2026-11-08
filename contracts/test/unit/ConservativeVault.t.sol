// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConservativeVault} from "../../src/ConservativeVault.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {MockUSDT, MockAdapter} from "../mocks/UnitMocks.sol";

contract ConservativeVaultUnitTest is Test {
    MockUSDT usdt;
    MockAdapter ad;
    ConservativeVault v;
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address admin = makeAddr("admin");
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    function setUp() public {
        usdt = new MockUSDT();
        ad = new MockAdapter(address(usdt));
        v = new ConservativeVault(IERC20(address(usdt)), "v", "v", IYieldAdapter(address(ad)), address(this), admin, keeper, guardian, 1000, 9000);
        ad.bind(address(v));
    }

    function _dep(address u, uint256 a) internal returns (uint256 s) {
        usdt.mint(u, a);
        vm.startPrank(u);
        usdt.approve(address(v), a);
        s = v.deposit(a, u);
        vm.stopPrank();
    }

    /// Classic first-depositor donation attack must not steal the victim's deposit.
    function test_inflationAttack_fails() public {
        _dep(attacker, 1);
        usdt.mint(attacker, 10_000e6);
        vm.prank(attacker);
        usdt.transfer(address(v), 10_000e6); // donation
        uint256 s = _dep(victim, 50e6);
        assertGt(s, 0, "victim gets shares");
        vm.prank(victim);
        uint256 out = v.redeem(s, victim, victim);
        assertApproxEqRel(out, 50e6, 0.001e18, "victim keeps ~all value");
    }

    function test_zeroShareDeposit_reverts() public {
        // 0 assets => 0 shares
        vm.expectRevert(ConservativeVault.ZeroShares.selector);
        v.deposit(0, address(this));
    }

    function test_adapterViewRevert_blocksEntry_noCheapMint() public {
        _dep(victim, 100e6);
        vm.prank(keeper);
        v.allocate(80e6, bytes32(0));
        ad.setRevert(true);
        usdt.mint(attacker, 10e6);
        vm.startPrank(attacker);
        usdt.approve(address(v), 10e6);
        vm.expectRevert(bytes("adapter down"));
        v.deposit(10e6, attacker); // NAV not silently computed as idle-only
        vm.stopPrank();
    }

    function test_illiquidAdapter_exitRevertsAtomically_sharesKept() public {
        uint256 s = _dep(victim, 100e6);
        vm.prank(keeper);
        v.allocate(90e6, bytes32(0));
        ad.setLiquidityCap(5e6);
        assertEq(v.maxWithdraw(victim), 15e6, "maxWithdraw reflects venue liquidity");
        vm.prank(victim);
        vm.expectRevert();
        v.redeem(s, victim, victim);
        assertEq(v.balanceOf(victim), s, "shares not burned on failed exit");
    }

    function test_keeperBounds_and_roles() public {
        _dep(victim, 100e6);
        vm.prank(attacker);
        vm.expectRevert(ConservativeVault.NotKeeper.selector);
        v.allocate(1e6, bytes32(0));
        vm.prank(keeper);
        vm.expectRevert(ConservativeVault.PolicyViolation.selector);
        v.allocate(95e6, bytes32(0)); // breaks 10% idle floor
        vm.prank(attacker);
        vm.expectRevert(ConservativeVault.NotGuardian.selector);
        v.setPaused(true);
    }

    function testFuzz_lossesAndGains_sharedProRata(uint96 a1, uint96 a2, uint64 gain, uint64 loss) public {
        uint256 x = bound(a1, 1e6, 1e12);
        uint256 y = bound(a2, 1e6, 1e12);
        uint256 s1 = _dep(victim, x);
        uint256 s2 = _dep(attacker, y);
        vm.prank(keeper);
        v.allocate((x + y) * 8 / 10, bytes32(0));
        ad.gain(bound(gain, 0, 1e11));
        ad.lose(bound(loss, 0, ad.held()));
        uint256 total = v.totalAssets();
        uint256 v1 = v.previewRedeem(s1);
        uint256 v2 = v.previewRedeem(s2);
        assertLe(v1 + v2, total, "no over-issuance of claims");
        // each holder's value ~ proportional to contribution (within rounding)
        if (total > 1e6) {
            assertApproxEqAbs(v1 * (x + y), total * x, (x + y) * 2 + total, "pro-rata 1");
        }
    }

    function testFuzz_depositRedeem_noFreeValue(uint96 a) public {
        uint256 x = bound(a, 1, 1e13);
        _dep(victim, 77e6);
        uint256 s = _dep(attacker, x);
        vm.prank(attacker);
        uint256 out = v.redeem(s, attacker, attacker);
        assertLe(out, x, "round trip never profits");
    }
}

/// Invariant: sum of all holders' redeemable value never exceeds NAV; NAV equals idle + adapter.
contract VaultHandler is Test {
    ConservativeVault v; MockUSDT usdt; MockAdapter ad; address keeper;
    address[3] users;
    constructor(ConservativeVault v_, MockUSDT u_, MockAdapter ad_, address k_) {
        v = v_; usdt = u_; ad = ad_; keeper = k_;
        users = [address(0xA1), address(0xB2), address(0xC3)];
    }
    function deposit(uint8 i, uint64 a) external {
        address u = users[i % 3]; uint256 x = bound(a, 1, 1e12);
        usdt.mint(u, x); vm.startPrank(u); usdt.approve(address(v), x);
        try v.deposit(x, u) {} catch {} vm.stopPrank();
    }
    function redeem(uint8 i, uint64 frac) external {
        address u = users[i % 3]; uint256 s = v.balanceOf(u) * bound(frac, 0, 100) / 100;
        uint256 m = v.maxRedeem(u); if (s > m) s = m; if (s == 0) return;
        vm.prank(u); v.redeem(s, u, u);
    }
    function allocate(uint64 a) external { vm.prank(keeper); try v.allocate(bound(a, 0, 1e12), bytes32(0)) {} catch {} }
    function deallocate(uint64 a) external { uint256 x = bound(a, 0, ad.held()); vm.prank(keeper); v.deallocate(x, bytes32(0)); }
    function gain(uint64 a) external { ad.gain(bound(a, 0, 1e9)); }
    function lose(uint64 a) external { ad.lose(bound(a, 0, ad.held())); }
    function donate(uint64 a) external { usdt.mint(address(v), bound(a, 0, 1e9)); }
    function sumValue() external view returns (uint256 s) { for (uint256 i; i < 3; ++i) s += v.previewRedeem(v.balanceOf(users[i])); }
}

contract ConservativeVaultInvariantTest is Test {
    MockUSDT usdt; MockAdapter ad; ConservativeVault v; VaultHandler h;
    function setUp() public {
        usdt = new MockUSDT(); ad = new MockAdapter(address(usdt));
        v = new ConservativeVault(IERC20(address(usdt)), "v", "v", IYieldAdapter(address(ad)), address(this), address(this), address(this), address(this), 1000, 9000);
        ad.bind(address(v));
        v.setKeeper(address(0));
        h = new VaultHandler(v, usdt, ad, address(this));
        v.setKeeper(address(this));
        targetContract(address(h));
    }
    function invariant_claimsNeverExceedNav() public view {
        assertLe(h.sumValue(), v.totalAssets());
    }
    function invariant_navIsIdlePlusAdapter() public view {
        assertEq(v.totalAssets(), usdt.balanceOf(address(v)) + ad.held());
    }
}
