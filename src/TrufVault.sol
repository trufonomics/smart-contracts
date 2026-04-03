// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITrufNetworkBridge} from "./interfaces/ITrufNetworkBridge.sol";

/// @title TrufVault
/// @notice ERC4626 vault that bridges deposited assets to TN prediction markets via TrufNetworkBridge.
/// @dev Restricted vault (Morpho model): funds can ONLY go to the bridge or back to depositors.
///      No arbitrary transfers, no DEX approvals, no external protocol calls.
///
///      Architecture:
///        User deposits USDC → vault mints shares (ERC4626 standard)
///        Operator bridges funds to TN → curator trades prediction markets
///        Curator PnL updates totalAssets → share price changes
///        User redeems shares → receives proportional USDC
///
///      Security:
///        - Operator (Gnosis Safe 2-of-3 on mainnet) controls bridge operations + pause
///        - No function exists to send assets to arbitrary addresses
///        - Only TrufNetworkBridge is approved for token spending
///        - Pausable for emergency stops
contract TrufVault is ERC4626, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice The operator address (EOA for testnet, Gnosis Safe for mainnet).
    address public operator;

    /// @notice The TrufNetworkBridge contract.
    ITrufNetworkBridge public immutable bridge;

    /// @notice The curator's wallet address on TN (receives bridged funds).
    address public curatorTNAddress;

    /// @notice Total assets currently deployed on TN (bridged out).
    uint256 public deployedOnTN;

    // ─── Events ──────────────────────────────────────────────────────────

    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event CuratorUpdated(address indexed previousCurator, address indexed newCurator);
    event BridgedToTN(uint256 amount, address indexed curator);
    event ClaimedFromTN(uint256 amount);
    event PnLRecorded(int256 pnlDelta, uint256 newTotalAssets);

    // ─── Errors ──────────────────────────────────────────────────────────

    error OnlyOperator();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientIdle(uint256 requested, uint256 available);
    error InsufficientDeployed(uint256 requested, uint256 deployed);

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    /// @param asset_ The underlying ERC20 token (USDC on mainnet, TT2 on Hoodi).
    /// @param bridge_ The TrufNetworkBridge contract address.
    /// @param operator_ The initial operator (EOA for testnet).
    /// @param curatorTNAddress_ The curator's TN wallet address.
    constructor(
        IERC20 asset_,
        ITrufNetworkBridge bridge_,
        address operator_,
        address curatorTNAddress_
    )
        ERC4626(asset_)
        ERC20("TrufVault Share", "tvUSDC")
    {
        if (address(bridge_) == address(0)) revert ZeroAddress();
        if (operator_ == address(0)) revert ZeroAddress();
        if (curatorTNAddress_ == address(0)) revert ZeroAddress();

        bridge = bridge_;
        operator = operator_;
        curatorTNAddress = curatorTNAddress_;
    }

    // ─── ERC4626 Overrides ───────────────────────────────────────────────

    /// @notice Total assets = idle balance in vault + deployed on TN.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + deployedOnTN;
    }

    /// @notice Deposits are paused when vault is paused.
    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    /// @notice Minting is paused when vault is paused.
    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    /// @notice Withdrawals use idle balance only.
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) revert InsufficientIdle(assets, idle);
        return super.withdraw(assets, receiver, owner_);
    }

    /// @notice Redemptions use idle balance only.
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        uint256 assets = previewRedeem(shares);
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) revert InsufficientIdle(assets, idle);
        return super.redeem(shares, receiver, owner_);
    }

    // ─── Operator Functions ──────────────────────────────────────────────

    /// @notice Bridge idle funds from vault to TN via TrufNetworkBridge.
    /// @param amount The amount to bridge.
    function depositToTN(uint256 amount) external onlyOperator {
        if (amount == 0) revert ZeroAmount();
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (amount > idle) revert InsufficientIdle(amount, idle);

        deployedOnTN += amount;

        IERC20(asset()).safeIncreaseAllowance(address(bridge), amount);
        bridge.deposit(amount, curatorTNAddress);

        emit BridgedToTN(amount, curatorTNAddress);
    }

    /// @notice Claim funds back from TN via TrufNetworkBridge withdrawal proof.
    /// @param amount The amount to claim.
    /// @param kwilBlockHash The Kwil block hash for proof verification.
    /// @param root The Merkle root.
    /// @param proof The Merkle proof path.
    /// @param signatures Validator signatures.
    function claimFromTN(
        uint256 amount,
        bytes32 kwilBlockHash,
        bytes32 root,
        bytes32[] calldata proof,
        ITrufNetworkBridge.Signature[] calldata signatures
    ) external onlyOperator {
        if (amount == 0) revert ZeroAmount();
        if (amount > deployedOnTN) revert InsufficientDeployed(amount, deployedOnTN);

        deployedOnTN -= amount;

        bridge.withdraw(address(this), amount, kwilBlockHash, root, proof, signatures);

        emit ClaimedFromTN(amount);
    }

    /// @notice Record PnL from curator trading activity on TN.
    /// @dev Adjusts deployedOnTN to reflect gains or losses. Called after indexer verification.
    /// @param pnlDelta Positive for gains, negative for losses.
    function recordPnL(int256 pnlDelta) external onlyOperator {
        if (pnlDelta > 0) {
            deployedOnTN += uint256(pnlDelta);
        } else if (pnlDelta < 0) {
            uint256 loss = uint256(-pnlDelta);
            if (loss > deployedOnTN) {
                deployedOnTN = 0;
            } else {
                deployedOnTN -= loss;
            }
        }

        emit PnLRecorded(pnlDelta, totalAssets());
    }

    // ─── Admin Functions ─────────────────────────────────────────────────

    /// @notice Transfer operator role to a new address (e.g., EOA → Gnosis Safe).
    function transferOperator(address newOperator) external onlyOperator {
        if (newOperator == address(0)) revert ZeroAddress();
        address previous = operator;
        operator = newOperator;
        emit OperatorTransferred(previous, newOperator);
    }

    /// @notice Update the curator's TN wallet address.
    function updateCurator(address newCurator) external onlyOperator {
        if (newCurator == address(0)) revert ZeroAddress();
        address previous = curatorTNAddress;
        curatorTNAddress = newCurator;
        emit CuratorUpdated(previous, newCurator);
    }

    /// @notice Pause all deposits/withdrawals.
    function pause() external onlyOperator {
        _pause();
    }

    /// @notice Unpause the vault.
    function unpause() external onlyOperator {
        _unpause();
    }

    // ─── View Functions ──────────────────────────────────────────────────

    /// @notice Returns the idle (unbridged) balance available for withdrawals.
    function idleBalance() external view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Returns the reserve ratio (idle / totalAssets) in basis points.
    function reserveRatioBps() external view returns (uint256) {
        uint256 total = totalAssets();
        if (total == 0) return 10000;
        return (IERC20(asset()).balanceOf(address(this)) * 10000) / total;
    }
}
