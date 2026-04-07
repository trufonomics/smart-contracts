// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
///        Performance fee on gains → minted as shares to feeRecipient
///        User redeems shares → receives proportional USDC
///
///      Security:
///        - Operator (Gnosis Safe 2-of-3 on mainnet) controls bridge operations + pause
///        - Two-step operator transfer prevents accidental lockout
///        - DECIMALS_OFFSET protects against inflation/donation attacks (critical for USDC)
///        - maxPnLDeltaBps caps single PnL update to limit damage from compromised keys
///        - No function exists to send assets to arbitrary addresses
///        - Only TrufNetworkBridge is approved for token spending
///        - Pausable for emergency stops
contract TrufVault is ERC4626, ERC20Permit, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ─── Constants ────────────────────────────────────────────────────────

    /// @notice Maximum performance fee: 50% (same as Morpho).
    uint256 public constant MAX_FEE = 0.5e18;

    /// @notice Maximum PnL delta per call in basis points (default 1000 = 10%).
    uint256 public constant MAX_PNL_DELTA_BPS = 1000;

    // ─── Immutables ───────────────────────────────────────────────────────

    /// @notice The TrufNetworkBridge contract.
    ITrufNetworkBridge public immutable bridge;

    /// @notice Decimal offset for share price protection (18 - assetDecimals).
    /// @dev For USDC (6 decimals), this is 12. Prevents inflation/donation attack.
    uint8 public immutable DECIMALS_OFFSET;

    // ─── State ────────────────────────────────────────────────────────────

    /// @notice The active operator address (EOA for testnet, Gnosis Safe for mainnet).
    address public operator;

    /// @notice Pending operator for two-step transfer.
    address public pendingOperator;

    /// @notice The curator's wallet address on TN (receives bridged funds).
    address public curatorTNAddress;

    /// @notice Total assets currently deployed on TN (bridged out).
    uint256 public deployedOnTN;

    /// @notice Performance fee in WAD (1e18 = 100%). Max 50%.
    uint256 public fee;

    /// @notice Address receiving performance fee shares.
    address public feeRecipient;

    /// @notice Per-share high-water mark for performance fee (assets per 1e18 shares).
    /// @dev Uses the vault's ERC-4626 conversion math (includes DECIMALS_OFFSET).
    ///      Fee only accrues when share price exceeds this value.
    uint256 public highWaterMarkPPS;

    /// @notice Designated recipient for accidentally sent tokens (skim).
    address public skimRecipient;

    // ─── Events ───────────────────────────────────────────────────────────

    event OperatorTransferStarted(address indexed currentOperator, address indexed pendingOperator);
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event CuratorUpdated(address indexed previousCurator, address indexed newCurator);
    event BridgedToTN(uint256 amount, address indexed curator);
    event ClaimedFromTN(uint256 amount);
    event PnLRecorded(int256 pnlDelta, uint256 newTotalAssets);
    event FeeSet(uint256 newFee);
    event FeeRecipientSet(address indexed newFeeRecipient);
    event SkimRecipientSet(address indexed newSkimRecipient);
    event FeesAccrued(uint256 feeShares, uint256 newTotalAssets);
    event Skimmed(address indexed token, address indexed recipient, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────────────

    error OnlyOperator();
    error OnlyPendingOperator();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientIdle(uint256 requested, uint256 available);
    error InsufficientDeployed(uint256 requested, uint256 deployed);
    error PnLDeltaExceedsMax(uint256 deltaBps, uint256 maxBps);
    error FeeExceedsMax(uint256 fee, uint256 maxFee);
    error ZeroFeeRecipient();
    error NoSkimRecipient();
    error BridgeAssetMismatch(address bridgeToken, address vaultAsset);

    // ─── Modifiers ────────────────────────────────────────────────────────

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────

    /// @param asset_ The underlying ERC20 token (USDC on mainnet, TT2 on Hoodi).
    /// @param bridge_ The TrufNetworkBridge contract address.
    /// @param operator_ The initial operator (EOA for testnet).
    /// @param curatorTNAddress_ The curator's TN wallet address.
    /// @param name_ The vault share token name (e.g., "TrufVault Share").
    /// @param symbol_ The vault share token symbol (e.g., "tvUSDC").
    constructor(
        IERC20 asset_,
        ITrufNetworkBridge bridge_,
        address operator_,
        address curatorTNAddress_,
        string memory name_,
        string memory symbol_
    ) ERC4626(asset_) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (address(bridge_) == address(0)) revert ZeroAddress();
        if (operator_ == address(0)) revert ZeroAddress();
        if (curatorTNAddress_ == address(0)) revert ZeroAddress();

        // Verify bridge is configured for the same asset (Finding 4: deployment safety guard)
        address bridgeToken = bridge_.token();
        if (bridgeToken != address(asset_)) {
            revert BridgeAssetMismatch(bridgeToken, address(asset_));
        }

        bridge = bridge_;
        operator = operator_;
        curatorTNAddress = curatorTNAddress_;

        // Inflation attack protection: offset = 18 - assetDecimals.
        // For USDC (6 decimals): offset = 12, multiplier = 10^12.
        uint8 assetDecimals = IERC20Metadata(address(asset_)).decimals();
        DECIMALS_OFFSET = assetDecimals >= 18 ? 0 : uint8(18 - assetDecimals);

        // One-time max approval to immutable bridge (Morpho pattern).
        // Safe because bridge address can never change.
        IERC20(asset_).forceApprove(address(bridge_), type(uint256).max);
    }

    // ─── ERC4626 Overrides ────────────────────────────────────────────────

    /// @dev Returns the decimal offset for share price protection.
    function _decimalsOffset() internal view override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    /// @notice Resolves decimals conflict between ERC20 and ERC4626.
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }

    /// @notice Total assets = idle balance in vault + deployed on TN.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + deployedOnTN;
    }

    /// @notice Maximum assets withdrawable by owner (capped to idle balance).
    function maxWithdraw(address owner_) public view override returns (uint256) {
        uint256 ownerAssets = _convertToAssets(balanceOf(owner_), Math.Rounding.Floor);
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return ownerAssets < idle ? ownerAssets : idle;
    }

    /// @notice Maximum shares redeemable by owner (capped to idle-equivalent shares).
    function maxRedeem(address owner_) public view override returns (uint256) {
        uint256 ownerShares = balanceOf(owner_);
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 idleShares = _convertToShares(idle, Math.Rounding.Floor);
        return ownerShares < idleShares ? ownerShares : idleShares;
    }

    /// @notice Deposits are paused when vault is paused. Accrues fees before deposit.
    function deposit(uint256 assets, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        _accrueFee();
        uint256 shares = super.deposit(assets, receiver);
        _initHighWaterMark();
        return shares;
    }

    /// @notice Minting is paused when vault is paused. Accrues fees before mint.
    function mint(uint256 shares, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        _accrueFee();
        uint256 assets = super.mint(shares, receiver);
        _initHighWaterMark();
        return assets;
    }

    /// @notice Withdrawals use idle balance only. Accrues fees before withdrawal.
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        _accrueFee();
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) revert InsufficientIdle(assets, idle);
        uint256 shares = super.withdraw(assets, receiver, owner_);
        return shares;
    }

    /// @notice Redemptions use idle balance only. Accrues fees before redemption.
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        _accrueFee();
        uint256 assets = previewRedeem(shares);
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) revert InsufficientIdle(assets, idle);
        uint256 redeemed = super.redeem(shares, receiver, owner_);
        return redeemed;
    }

    // ─── Operator Functions ───────────────────────────────────────────────

    /// @notice Bridge idle funds from vault to TN via TrufNetworkBridge.
    /// @param amount The amount to bridge.
    function depositToTN(uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (amount > idle) revert InsufficientIdle(amount, idle);

        deployedOnTN += amount;

        // Bridge already has max approval from constructor (forceApprove).
        bridge.deposit(amount, curatorTNAddress);

        emit BridgedToTN(amount, curatorTNAddress);
    }

    /// @notice Claim funds back from TN via TrufNetworkBridge withdrawal proof.
    function claimFromTN(
        uint256 amount,
        bytes32 kwilBlockHash,
        bytes32 root,
        bytes32[] calldata proof,
        ITrufNetworkBridge.Signature[] calldata signatures
    ) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > deployedOnTN) revert InsufficientDeployed(amount, deployedOnTN);

        deployedOnTN -= amount;

        bridge.withdraw(address(this), amount, kwilBlockHash, root, proof, signatures);

        // CEI: emit after state change and external call
        emit ClaimedFromTN(amount);
    }

    /// @notice Record PnL from curator trading activity on TN.
    /// @dev Adjusts deployedOnTN to reflect gains or losses. Called after indexer verification.
    ///      Capped at MAX_PNL_DELTA_BPS per call to limit damage from compromised keys.
    /// @param pnlDelta Positive for gains, negative for losses.
    function recordPnL(int256 pnlDelta) external onlyOperator {
        // Enforce max PnL delta as % of deployedOnTN
        if (deployedOnTN > 0) {
            uint256 absDelta = pnlDelta >= 0 ? uint256(pnlDelta) : uint256(-pnlDelta);
            uint256 deltaBps = (absDelta * 10000) / deployedOnTN;
            if (deltaBps > MAX_PNL_DELTA_BPS) {
                revert PnLDeltaExceedsMax(deltaBps, MAX_PNL_DELTA_BPS);
            }
        } else {
            // If nothing deployed, only allow zero delta
            if (pnlDelta != 0) revert PnLDeltaExceedsMax(type(uint256).max, MAX_PNL_DELTA_BPS);
        }

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

        // Accrue fees if share price exceeded high-water mark
        _accrueFee();

        emit PnLRecorded(pnlDelta, totalAssets());
    }

    // ─── Admin Functions ──────────────────────────────────────────────────

    /// @notice Step 1 of operator transfer: set pending operator.
    function transferOperator(address newOperator) external onlyOperator {
        if (newOperator == address(0)) revert ZeroAddress();
        pendingOperator = newOperator;
        emit OperatorTransferStarted(operator, newOperator);
    }

    /// @notice Step 2 of operator transfer: new operator accepts.
    function acceptOperator() external {
        if (msg.sender != pendingOperator) revert OnlyPendingOperator();
        address previous = operator;
        operator = pendingOperator;
        pendingOperator = address(0);
        emit OperatorTransferred(previous, operator);
    }

    /// @notice Update the curator's TN wallet address.
    function updateCurator(address newCurator) external onlyOperator {
        if (newCurator == address(0)) revert ZeroAddress();
        address previous = curatorTNAddress;
        curatorTNAddress = newCurator;
        emit CuratorUpdated(previous, newCurator);
    }

    /// @notice Set the performance fee (in WAD, 1e18 = 100%).
    function setFee(uint256 newFee) external onlyOperator {
        if (newFee > MAX_FEE) revert FeeExceedsMax(newFee, MAX_FEE);
        if (newFee != 0 && feeRecipient == address(0)) revert ZeroFeeRecipient();

        // Accrue with old fee before changing
        _accrueFee();

        // Reset HWM when activating fees so pre-fee gains aren't charged retroactively
        if (fee == 0 && newFee != 0 && totalSupply() > 0) {
            highWaterMarkPPS = _convertToAssets(1e18, Math.Rounding.Floor);
        }

        fee = newFee;
        emit FeeSet(newFee);
    }

    /// @notice Set the fee recipient address.
    function setFeeRecipient(address newFeeRecipient) external onlyOperator {
        if (newFeeRecipient == address(0) && fee != 0) revert ZeroFeeRecipient();

        // Accrue to old recipient before changing
        _accrueFee();

        // Reset HWM when activating recipient (fee becomes effective) so old gains aren't charged
        if (feeRecipient == address(0) && newFeeRecipient != address(0) && fee != 0 && totalSupply() > 0) {
            highWaterMarkPPS = _convertToAssets(1e18, Math.Rounding.Floor);
        }

        feeRecipient = newFeeRecipient;
        emit FeeRecipientSet(newFeeRecipient);
    }

    /// @notice Set the skim recipient for token recovery.
    function setSkimRecipient(address newSkimRecipient) external onlyOperator {
        skimRecipient = newSkimRecipient;
        emit SkimRecipientSet(newSkimRecipient);
    }

    /// @notice Recover accidentally sent tokens. Cannot skim the vault's own asset.
    function skim(address token_) external {
        if (skimRecipient == address(0)) revert NoSkimRecipient();

        uint256 amount = IERC20(token_).balanceOf(address(this));

        // If skimming the vault asset, only skim excess above what's accounted for
        if (token_ == asset()) {
            uint256 accounted = totalAssets() - deployedOnTN; // idle portion
            if (amount <= accounted) return;
            amount = amount - accounted;
        }

        IERC20(token_).safeTransfer(skimRecipient, amount);
        emit Skimmed(token_, skimRecipient, amount);
    }

    /// @notice Pause all deposits/withdrawals.
    function pause() external onlyOperator {
        _pause();
    }

    /// @notice Unpause the vault.
    function unpause() external onlyOperator {
        _unpause();
    }

    // ─── View Functions ───────────────────────────────────────────────────

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

    // ─── Internal ─────────────────────────────────────────────────────────

    /// @dev Accrue performance fee using per-share high-water mark.
    ///      Fee is charged only when the share price (assets per 1e18 shares) exceeds
    ///      the all-time high. This ensures depositors are never charged fees while
    ///      still underwater from a prior loss — a true high-water mark.
    ///
    ///      Uses the vault's ERC-4626 conversion math (_convertToAssets) so that
    ///      DECIMALS_OFFSET and virtual shares/assets are properly accounted for.
    ///
    ///      After minting fee shares, the watermark is set to the POST-fee share price
    ///      (not pre-fee) to avoid odd behavior on subsequent recoveries.
    function _accrueFee() internal {
        if (fee == 0 || feeRecipient == address(0)) return;

        uint256 supply = totalSupply();
        if (supply == 0) return;

        // HWM not yet initialized (no deposits yet) — skip
        if (highWaterMarkPPS == 0) return;

        // Per-share price via the vault's own ERC-4626 conversion (respects DECIMALS_OFFSET)
        uint256 currentPPS = _convertToAssets(1e18, Math.Rounding.Floor);

        // No fee unless share price exceeds all-time high
        if (currentPPS <= highWaterMarkPPS) return;

        // Fee on the per-share excess, scaled to total supply
        uint256 excessPerShare = currentPPS - highWaterMarkPPS;
        uint256 totalExcess = excessPerShare.mulDiv(supply, 1e18);
        uint256 feeAssets = totalExcess.mulDiv(fee, 1e18);

        if (feeAssets > 0) {
            uint256 feeShares = _convertToShares(feeAssets, Math.Rounding.Floor);
            if (feeShares > 0) {
                _mint(feeRecipient, feeShares);
                emit FeesAccrued(feeShares, totalAssets());
            }
        }

        // Set HWM to POST-fee share price (supply increased, totalAssets unchanged)
        highWaterMarkPPS = _convertToAssets(1e18, Math.Rounding.Floor);
    }

    /// @dev Initialize the per-share high-water mark after the first deposit creates shares.
    ///      Called at the end of deposit/mint so that shares exist before computing PPS.
    function _initHighWaterMark() internal {
        if (highWaterMarkPPS == 0 && totalSupply() > 0) {
            highWaterMarkPPS = _convertToAssets(1e18, Math.Rounding.Floor);
        }
    }
}
