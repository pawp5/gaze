// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConservativeVault} from "../ConservativeVault.sol";
import {AaveV3Adapter} from "../adapters/AaveV3Adapter.sol";

/// @notice Permissionless creation of Conservative vaults within a CURATED integration universe.
/// Anyone may create; only the curator registers integrations (asset/pool/aToken triples) and
/// may set a "reviewed" label. New vaults are never auto-labelled reviewed.
contract ConservativeVaultFactory {
    error NotCurator();
    error UnknownIntegration();

    struct AaveIntegration {
        address asset;
        address pool;
        address aToken;
        bool enabled;
    }

    event IntegrationSet(bytes32 indexed id, address asset, address pool, address aToken, bool enabled);
    event VaultCreated(
        address indexed vault,
        address indexed adapter,
        address indexed creator,
        bytes32 integrationId,
        address admin,
        address keeper,
        uint16 minIdleBps,
        uint16 maxAdapterBps
    );
    event Reviewed(address indexed vault, bool reviewed);

    address public curator;
    address public immutable guardian;
    mapping(bytes32 => AaveIntegration) public integrations;
    mapping(address => bool) public isVault;
    mapping(address => bool) public reviewed;
    address[] public allVaults;

    constructor(address curator_, address guardian_) {
        curator = curator_;
        guardian = guardian_;
    }

    function setIntegration(bytes32 id, AaveIntegration calldata i) external {
        if (msg.sender != curator) revert NotCurator();
        integrations[id] = i;
        emit IntegrationSet(id, i.asset, i.pool, i.aToken, i.enabled);
    }

    function setReviewed(address vault, bool r) external {
        if (msg.sender != curator) revert NotCurator();
        reviewed[vault] = r;
        emit Reviewed(vault, r);
    }

    function createVault(
        bytes32 integrationId,
        string calldata name,
        string calldata symbol,
        address admin,
        address keeper,
        uint16 minIdleBps,
        uint16 maxAdapterBps
    ) external returns (ConservativeVault vault) {
        AaveIntegration memory i = integrations[integrationId];
        if (!i.enabled) revert UnknownIntegration();
        AaveV3Adapter adapter = new AaveV3Adapter(i.asset, i.pool, i.aToken);
        vault = new ConservativeVault(
            IERC20(i.asset), name, symbol, adapter, msg.sender, admin, keeper, guardian, minIdleBps, maxAdapterBps
        );
        adapter.bind(address(vault)); // atomic: same tx as deployment
        isVault[address(vault)] = true;
        allVaults.push(address(vault));
        emit VaultCreated(address(vault), address(adapter), msg.sender, integrationId, admin, keeper, minIdleBps, maxAdapterBps);
    }

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }
}
