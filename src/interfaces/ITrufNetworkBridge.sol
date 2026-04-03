// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITrufNetworkBridge
/// @notice Interface for TrufNetworkBridge — bridges ERC20 tokens between Ethereum and TN (Kwil-DB).
/// @dev Based on the deployed TrufNetworkBridge on Hoodi testnet at 0x878d6aaeb6e746033f50b8dc268d54b4631554e7
interface ITrufNetworkBridge {
    struct Signature {
        bytes32 r;
        bytes32 s;
        uint8 v;
    }

    /// @notice Deposit tokens into the bridge for a recipient on TN.
    /// @param amount The amount of tokens to bridge.
    /// @param recipient The recipient address on TN (Ethereum-format address used as Kwil wallet).
    function deposit(uint256 amount, address recipient) external;

    /// @notice Withdraw tokens from TN back to Ethereum.
    /// @param recipient The recipient address on Ethereum.
    /// @param amount The amount of tokens to withdraw.
    /// @param kwilBlockHash The Kwil block hash for proof verification.
    /// @param root The Merkle root for the withdrawal proof.
    /// @param proof The Merkle proof path.
    /// @param signatures Validator signatures attesting to the withdrawal.
    function withdraw(
        address recipient,
        uint256 amount,
        bytes32 kwilBlockHash,
        bytes32 root,
        bytes32[] calldata proof,
        Signature[] calldata signatures
    ) external;

    /// @notice Returns the ERC20 token used by the bridge.
    function token() external view returns (address);
}
