// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISafe} from "../../src/automation/ISafe.sol";

/// @dev Mock Gnosis Safe for testing the AutoBridgeModule.
///      Simulates the parts of `safe-contracts/ModuleManager` we actually exercise:
///        - `enableModule(address)` / `disableModule(address)` toggle authorization
///        - `execTransactionFromModule` validates `msg.sender` is enabled, then forwards
///          the call so the target sees `msg.sender == address(this)`.
///      Mirrors the canonical Safe behavior closely enough that downstream contracts
///      (like the vault) cannot tell the difference between this mock and a real Safe.
contract MockSafe is ISafe {
    mapping(address => bool) public modulesEnabled;

    error ModuleNotEnabled();

    /// @notice Enable a module. In a real Safe this would be guarded by `authorized` (the Safe
    ///         calling itself via signed multisig tx). The mock skips the gating because tests
    ///         drive it directly.
    function enableModule(address module) external {
        modulesEnabled[module] = true;
    }

    /// @notice Disable a module. Same gating notes as `enableModule`.
    function disableModule(address module) external {
        modulesEnabled[module] = false;
    }

    /// @inheritdoc ISafe
    function isModuleEnabled(address module) external view override returns (bool) {
        return modulesEnabled[module];
    }

    /// @inheritdoc ISafe
    /// @dev Validates the caller is an enabled module, then low-level calls `to` with `data`
    ///      so the target sees `msg.sender == address(this)` — exactly how a real Safe routes
    ///      module-originated transactions.
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes memory data,
        Operation operation
    ) external override returns (bool success) {
        if (!modulesEnabled[msg.sender]) revert ModuleNotEnabled();

        if (operation == Operation.Call) {
            (success,) = to.call{value: value}(data);
        } else {
            // The AutoBridgeModule never uses DelegateCall, but support it here for completeness.
            (success,) = to.delegatecall(data);
        }
    }

    /// @notice Helper for tests: execute an arbitrary call as the Safe (used for admin actions
    ///         that the AutoBridgeModule's `onlySafe` modifier requires).
    function execAsSafe(address to, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call(data);
        require(ok, "MockSafe: execAsSafe failed");
        return ret;
    }

    /// @notice Allow the mock Safe to receive ETH (Safes are payable).
    receive() external payable {}
}
