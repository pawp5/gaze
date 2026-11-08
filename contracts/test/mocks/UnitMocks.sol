// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// UNIT-TEST MOCKS ONLY. These never establish real integration; fork tests do.
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "mUSDT") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function burn(address from, uint256 a) external { _burn(from, a); }
}

/// @notice Adapter mock with controllable gains/losses/liquidity and a revert switch (adversarial).
contract MockAdapter is IYieldAdapter {
    address public override vault;
    address public immutable override asset;
    uint256 public held;
    uint256 public liquidityCap = type(uint256).max;
    bool public revertViews;

    constructor(address asset_) { asset = asset_; }
    function bind(address v) external { require(vault == address(0)); vault = v; }
    function setRevert(bool r) external { revertViews = r; }
    function setLiquidityCap(uint256 c) external { liquidityCap = c; }
    function gain(uint256 a) external { MockUSDT(asset).mint(address(this), a); held += a; }
    function lose(uint256 a) external { MockUSDT(asset).burn(address(this), a); held -= a; }
    function totalAssets() external view override returns (uint256) { require(!revertViews, "adapter down"); return held; }
    function maxWithdrawable() external view override returns (uint256) { require(!revertViews, "adapter down"); return held < liquidityCap ? held : liquidityCap; }
    function deposit(uint256 a) external override { require(msg.sender == vault); IERC20(asset).transferFrom(vault, address(this), a); held += a; }
    function withdraw(uint256 a) external override { require(msg.sender == vault); require(a <= liquidityCap, "illiquid"); held -= a; IERC20(asset).transfer(vault, a); }
}
