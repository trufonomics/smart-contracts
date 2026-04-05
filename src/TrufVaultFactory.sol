// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITrufNetworkBridge} from "./interfaces/ITrufNetworkBridge.sol";
import {TrufVault} from "./TrufVault.sol";

/// @title TrufVaultFactory
/// @notice Deploys TrufVault instances and maintains a registry.
/// @dev Modeled on Morpho's MetaMorphoFactory. Uses CREATE2 for deterministic addresses.
///      All vaults use the same bridge (immutable per vault).
contract TrufVaultFactory {
    // ─── State ────────────────────────────────────────────────────────────

    /// @notice Whether an address was deployed by this factory. NOT an approval or endorsement.
    mapping(address => bool) public isVault;

    /// @notice All vault addresses deployed by this factory (permissionless — not curated).
    address[] public vaults;

    // ─── Events ───────────────────────────────────────────────────────────

    event VaultCreated(
        address indexed vault,
        address indexed deployer,
        address indexed asset,
        address bridge,
        address operator,
        address curatorTNAddress,
        string name,
        string symbol,
        bytes32 salt
    );

    // ─── Errors ───────────────────────────────────────────────────────────

    error ZeroAddress();

    // ─── Factory ──────────────────────────────────────────────────────────

    /// @notice Deploy a new TrufVault with CREATE2.
    /// @param asset The underlying ERC20 token (e.g., USDC).
    /// @param bridge The TrufNetworkBridge contract.
    /// @param operator_ The initial operator (EOA for testnet, Gnosis Safe for mainnet).
    /// @param curatorTNAddress The curator's wallet on TN.
    /// @param name The vault share token name (e.g., "TrufVault USDC").
    /// @param symbol The vault share token symbol (e.g., "tvUSDC").
    /// @param salt Deterministic deployment salt.
    /// @return vault The deployed TrufVault address.
    function createVault(
        IERC20 asset,
        ITrufNetworkBridge bridge,
        address operator_,
        address curatorTNAddress,
        string memory name,
        string memory symbol,
        bytes32 salt
    ) external returns (address vault) {
        if (address(asset) == address(0)) revert ZeroAddress();

        TrufVault v = new TrufVault{salt: salt}(
            asset,
            bridge,
            operator_,
            curatorTNAddress,
            name,
            symbol
        );

        vault = address(v);
        isVault[vault] = true;
        vaults.push(vault);

        emit VaultCreated(
            vault,
            msg.sender,
            address(asset),
            address(bridge),
            operator_,
            curatorTNAddress,
            name,
            symbol,
            salt
        );
    }

    /// @notice Returns the total number of vaults deployed.
    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }
}
