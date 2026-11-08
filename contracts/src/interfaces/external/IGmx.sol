// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice GMX V2 types/selectors verified against live Arbitrum ExchangeRouter
/// 0x7dE39FF2e232A2203196788d37e234cF8F1b83f1 bytecode (createOrder selector 0xf59c48eb) and
/// gmx-synthetics IBaseOrderUtils at commit a85ea349 on 2026-11-08.
library GmxOrder {
    enum OrderType {
        MarketSwap,
        LimitSwap,
        MarketIncrease,
        LimitIncrease,
        MarketDecrease,
        LimitDecrease,
        StopLossDecrease,
        Liquidation,
        StopIncrease
    }

    enum DecreasePositionSwapType {
        NoSwap,
        SwapPnlTokenToCollateralToken,
        SwapCollateralTokenToPnlToken
    }

    struct CreateOrderParamsAddresses {
        address receiver;
        address cancellationReceiver;
        address callbackContract;
        address uiFeeReceiver;
        address market;
        address initialCollateralToken;
        address[] swapPath;
    }

    struct CreateOrderParamsNumbers {
        uint256 sizeDeltaUsd;
        uint256 initialCollateralDeltaAmount;
        uint256 triggerPrice;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 callbackGasLimit;
        uint256 minOutputAmount;
        uint256 validFromTime;
    }

    struct CreateOrderParams {
        CreateOrderParamsAddresses addresses;
        CreateOrderParamsNumbers numbers;
        OrderType orderType;
        DecreasePositionSwapType decreasePositionSwapType;
        bool isLong;
        bool shouldUnwrapNativeToken;
        bool autoCancel;
        bytes32 referralCode;
        bytes32[] dataList;
    }
}

interface IGmxExchangeRouter {
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
    function sendWnt(address receiver, uint256 amount) external payable;
    function sendTokens(address token, address receiver, uint256 amount) external payable;
    function createOrder(GmxOrder.CreateOrderParams calldata params) external payable returns (bytes32);
    function cancelOrder(bytes32 key) external payable;
}

interface IGmxDataStore {
    function containsBytes32(bytes32 setKey, bytes32 value) external view returns (bool);
    function getBytes32Count(bytes32 setKey) external view returns (uint256);
    function getUint(bytes32 key) external view returns (uint256);
}

/// @notice GMX DataStore key derivations (gmx-synthetics contracts/data/Keys.sol).
library GmxKeys {
    bytes32 internal constant ORDER_LIST = keccak256(abi.encode("ORDER_LIST"));
    bytes32 internal constant ACCOUNT_ORDER_LIST = keccak256(abi.encode("ACCOUNT_ORDER_LIST"));
    bytes32 internal constant ACCOUNT_POSITION_LIST = keccak256(abi.encode("ACCOUNT_POSITION_LIST"));
    bytes32 internal constant MIN_COLLATERAL_USD = keccak256(abi.encode("MIN_COLLATERAL_USD"));
    bytes32 internal constant MIN_POSITION_SIZE_USD = keccak256(abi.encode("MIN_POSITION_SIZE_USD"));

    function accountOrderListKey(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(ACCOUNT_ORDER_LIST, account));
    }

    function accountPositionListKey(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(ACCOUNT_POSITION_LIST, account));
    }
}
