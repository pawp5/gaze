// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MandateAccount} from "../MandateAccount.sol";
import {ConservativeVault} from "../ConservativeVault.sol";

/// @notice Permissionless per-user account creation for Balanced/Aggressive mandates.
/// The curator registers ONE verified venue config and per-mandate policy CEILINGS.
/// Users may request tighter policies; never looser. Guardian can pause new risk globally;
/// reduce/cancel/withdraw paths remain open.
contract MandateAccountFactory {
    error NotCurator();
    error NotGuardian();
    error PolicyAboveCeiling(string what);
    error NotConfigured();

    event AccountCreated(address indexed account, address indexed owner, MandateAccount.Mandate mandate, address keeper);
    event RiskPausedSet(bool paused);
    event VenueSet(bytes32 venueHash);
    event CeilingSet(MandateAccount.Mandate mandate);

    address public curator;
    address public immutable guardian;
    address public defaultKeeper;
    bool public riskPaused;
    bool public venueSet;

    MandateAccount.Venue internal _venue;
    mapping(MandateAccount.Mandate => MandateAccount.Policy) internal _ceiling;
    mapping(MandateAccount.Mandate => bool) public ceilingSet;
    ConservativeVault public reserveVault;

    mapping(address => address[]) public accountsOf;
    mapping(address => bool) public isAccount;

    constructor(address curator_, address guardian_, address keeper_, ConservativeVault reserveVault_) {
        curator = curator_;
        guardian = guardian_;
        defaultKeeper = keeper_;
        reserveVault = reserveVault_;
    }

    modifier onlyCurator() {
        if (msg.sender != curator) revert NotCurator();
        _;
    }

    function setVenue(MandateAccount.Venue calldata v) external onlyCurator {
        _venue = v;
        venueSet = true;
        emit VenueSet(keccak256(abi.encode(v)));
    }

    function setCeiling(MandateAccount.Mandate m, MandateAccount.Policy calldata p) external onlyCurator {
        if (m == MandateAccount.Mandate.Balanced && p.minReserveBps < 5000) revert PolicyAboveCeiling("reserve");
        _ceiling[m] = p;
        ceilingSet[m] = true;
        emit CeilingSet(m);
    }

    function setRiskPaused(bool p) external {
        if (msg.sender != guardian) revert NotGuardian();
        riskPaused = p;
        emit RiskPausedSet(p);
    }

    function ceiling(MandateAccount.Mandate m) external view returns (MandateAccount.Policy memory) {
        return _ceiling[m];
    }

    function venue() external view returns (MandateAccount.Venue memory) {
        return _venue;
    }

    /// @param requested tighter-or-equal policy; pass the ceiling itself to accept defaults.
    function createAccount(MandateAccount.Mandate m, MandateAccount.Policy calldata requested)
        external
        returns (MandateAccount account)
    {
        if (!venueSet || !ceilingSet[m]) revert NotConfigured();
        MandateAccount.Policy memory c = _ceiling[m];
        if (requested.minReserveBps < c.minReserveBps) revert PolicyAboveCeiling("minReserveBps");
        if (requested.maxLeverageBps > c.maxLeverageBps) revert PolicyAboveCeiling("leverage");
        if (requested.maxCollateralPerOrder > c.maxCollateralPerOrder) revert PolicyAboveCeiling("collateral");
        if (requested.maxExecutionFeePerOrder > c.maxExecutionFeePerOrder) revert PolicyAboveCeiling("fee/order");
        if (requested.maxFeeSpendWei > c.maxFeeSpendWei) revert PolicyAboveCeiling("fee budget");
        if (requested.maxPendingOrders > c.maxPendingOrders) revert PolicyAboveCeiling("pending");
        if (requested.maxOpenPositions > c.maxOpenPositions) revert PolicyAboveCeiling("positions");
        if (requested.maxPriceDeviationBps > c.maxPriceDeviationBps) revert PolicyAboveCeiling("price dev");
        if (requested.maxSwapSlippageBps > c.maxSwapSlippageBps) revert PolicyAboveCeiling("swap slip");
        if (requested.maxPriceAge > c.maxPriceAge) revert PolicyAboveCeiling("price age");

        account = new MandateAccount(m, msg.sender, defaultKeeper, reserveVault, _venue, requested);
        isAccount[address(account)] = true;
        accountsOf[msg.sender].push(address(account));
        emit AccountCreated(address(account), msg.sender, m, defaultKeeper);
    }

    function accountCount(address user) external view returns (uint256) {
        return accountsOf[user].length;
    }
}
