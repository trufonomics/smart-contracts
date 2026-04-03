// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITrufNetworkBridge} from "../../src/interfaces/ITrufNetworkBridge.sol";

/// @dev Mock TrufNetworkBridge for testing. Simulates deposit/withdraw flows.
contract MockBridge is ITrufNetworkBridge {
    address public token_;
    uint256 public lastDepositAmount;
    address public lastDepositRecipient;
    uint256 public lastWithdrawAmount;
    address public lastWithdrawRecipient;
    bool public shouldRevert;

    constructor(address token__) {
        token_ = token__;
    }

    function token() external view override returns (address) {
        return token_;
    }

    function deposit(uint256 amount, address recipient) external override {
        require(!shouldRevert, "MockBridge: revert");
        lastDepositAmount = amount;
        lastDepositRecipient = recipient;
        // Pull tokens from caller (simulates real bridge behavior)
        IERC20(token_).transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(
        address recipient,
        uint256 amount,
        bytes32,
        bytes32,
        bytes32[] calldata,
        Signature[] calldata
    ) external override {
        require(!shouldRevert, "MockBridge: revert");
        lastWithdrawAmount = amount;
        lastWithdrawRecipient = recipient;
        // Send tokens to recipient (simulates real bridge releasing escrow)
        IERC20(token_).transfer(recipient, amount);
    }

    // Test helpers
    function setShouldRevert(bool val) external {
        shouldRevert = val;
    }

    /// @dev Fund the bridge with tokens to simulate escrow for withdrawals.
    function fundEscrow(uint256 amount) external {
        IERC20(token_).transferFrom(msg.sender, address(this), amount);
    }
}
