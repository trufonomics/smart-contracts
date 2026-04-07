// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISafe
/// @notice Minimal interface for the Gnosis Safe / Safe{Wallet} module execution path.
/// @dev Only the function the AutoBridgeModule needs is included. The full Safe ABI is
///      intentionally not pulled in — see docs/automation-references.md for the rationale.
///
///      This matches the canonical signature in safe-global/safe-contracts:
///      contracts/base/ModuleManager.sol:execTransactionFromModule.
interface ISafe {
    /// @notice Operation type for Safe module-routed transactions.
    /// @dev Values match Safe's internal `Enum.Operation`:
    ///        0 = Call
    ///        1 = DelegateCall
    ///      The AutoBridgeModule only ever uses Operation.Call. DelegateCall is never issued.
    enum Operation {
        Call,
        DelegateCall
    }

    /// @notice Execute a transaction originating from a Safe module.
    /// @dev The Safe verifies that `msg.sender` is an enabled module before executing.
    ///      The transaction is executed with the Safe itself as the caller — meaning
    ///      downstream contracts (like the vault) see `msg.sender == address(safe)`.
    /// @param to The target address.
    /// @param value Native ETH value to forward (always 0 for the AutoBridgeModule).
    /// @param data ABI-encoded calldata for the target.
    /// @param operation Call or DelegateCall (always Call for the AutoBridgeModule).
    /// @return success True if the underlying call succeeded.
    function execTransactionFromModule(address to, uint256 value, bytes memory data, Operation operation)
        external
        returns (bool success);

    /// @notice Whether a given address is an enabled module on this Safe.
    /// @dev Retained for operational tooling and parity with the canonical Safe surface.
    function isModuleEnabled(address module) external view returns (bool);
}
