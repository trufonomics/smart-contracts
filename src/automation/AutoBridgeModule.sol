// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TrufVault} from "../TrufVault.sol";
import {ITrufNetworkBridge} from "../interfaces/ITrufNetworkBridge.sol";
import {ISafe} from "./ISafe.sol";

/// @title AutoBridgeModule
/// @notice Gnosis Safe module that lets a designated keeper bot trigger routine bridge ops on a
///         TrufVault — `depositToTN` and `claimFromTN` — within hardcoded rate limits, reserve
///         floors, and cooldowns. The Safe stays the operator of the vault. Nothing about the
///         vault contract changes.
///
/// @dev    Architecture:
///
///           ┌──────────────────────┐
///           │     TrufVault        │
///           │  (audited, immutable)│
///           └──────────▲───────────┘
///                      │ depositToTN / claimFromTN
///           ┌──────────┴───────────┐
///           │   Gnosis Safe        │   ← operator on vault, never changes
///           └──────────▲───────────┘
///                      │ execTransactionFromModule
///           ┌──────────┴───────────┐
///           │  AutoBridgeModule    │   ← this contract
///           └──────────▲───────────┘
///                      │ autoBridgeToTN / autoClaimFromTN
///           ┌──────────┴───────────┐
///           │   Keeper address     │
///           └──────────────────────┘
///
///         Access model — strict separation, modeled on Lido LimitsChecker:
///           - Keeper (single address)     → autoBridgeToTN, autoClaimFromTN
///           - Safe (the multisig itself)  → setPerTxBridgeBps, setDailyBridgeBps,
///                                           setMinReserveBps, setClaimCooldown,
///                                           transferKeeper / acceptKeeper
///           - Nobody                      → call any other vault function. The module has no
///                                           code path to pause, recordPnL, setFee, updateCurator,
///                                           transferOperator, or anything else.
///
///         Pattern lineage (see docs/automation-references.md):
///           - Safe Allowance Module    → auto-resetting periodic cap, lazy reset, interval-aligned
///           - Zodiac Module base       → internal _exec helper wrapping the Safe call
///           - Lido LimitsChecker       → two-role separation, hardcoded ceilings
///           - Yearn TokenizedStrategy  → keeper-callable accounting shape (we diverge: strict single role)
///
///         Kill switch:
///           If anything looks wrong, multisig signers call `disableModule` on the Safe directly.
///           The module instantly loses all power. The vault keeps working unchanged.
///           No emergency function on this contract — disabling the module IS the emergency stop.
contract AutoBridgeModule is ReentrancyGuard {
    // ─── Constants ────────────────────────────────────────────────────────

    /// @notice Basis-point denominator (100% = 10000 bps).
    uint256 public constant MAX_BPS = 10_000;

    /// @notice Hardcoded ceiling on per-tx bridge cap (basis points of totalAssets).
    /// @dev    The Safe itself cannot lift this. This constrains keeper-routed calls and prevents
    ///         the multisig from accidentally misconfiguring the setter above a reviewed ceiling.
    ///         At 1000 bps (10%), an attacker with a compromised keeper key needs 10+ transactions
    ///         to bridge the entire vault, giving signers time to detect and disable the module.
    uint256 public constant MAX_PER_TX_BRIDGE_BPS = 1_000;

    /// @notice Hardcoded ceiling on daily bridge cap (basis points of totalAssets).
    /// @dev    Caps keeper-routed outflow at 30% of the period-start asset base per UTC day.
    ///         Combined with the per-tx cap, this limits both single-action damage and sustained
    ///         drain rate on the module-controlled path.
    uint256 public constant MAX_DAILY_BRIDGE_BPS = 3_000;

    /// @notice Hardcoded floor on the reserve threshold (basis points of totalAssets).
    /// @dev    The minimum reserve the multisig is allowed to set. Prevents the multisig itself
    ///         (or an attacker with multisig keys) from dropping the reserve floor to zero and
    ///         then sweeping everything via the bot.
    uint256 public constant MIN_ALLOWED_RESERVE_BPS = 500;

    /// @notice Hardcoded ceiling on the reserve threshold.
    /// @dev    A 50% reserve cap is generous — anything higher and the bot is mostly redundant
    ///         because most of the vault is idle by definition.
    uint256 public constant MAX_ALLOWED_RESERVE_BPS = 5_000;

    /// @notice Minimum cooldown between consecutive `autoClaimFromTN` calls (seconds).
    uint256 public constant MIN_CLAIM_COOLDOWN = 5 minutes;

    /// @notice Maximum cooldown between consecutive `autoClaimFromTN` calls (seconds).
    /// @dev    Prevents the multisig from bricking the bot with an unreasonably long cooldown.
    uint256 public constant MAX_CLAIM_COOLDOWN = 1 days;

    /// @notice Length of the daily reset window for the bridge cap.
    uint256 public constant BRIDGE_PERIOD = 1 days;

    // ─── Immutables ───────────────────────────────────────────────────────

    /// @notice The Gnosis Safe this module is attached to.
    /// @dev    Set once at deployment, baked into bytecode. The module cannot be repointed.
    ISafe public immutable safe;

    /// @notice The TrufVault this module operates on.
    /// @dev    Set once at deployment. The module cannot be repointed at a different vault.
    TrufVault public immutable vault;

    // ─── State: Keeper ────────────────────────────────────────────────────

    /// @notice The single address authorized to call `autoBridgeToTN` and `autoClaimFromTN`.
    /// @dev    Typically an EOA hot key running on the bot, but not restricted to EOAs.
    ///         Compromise is bounded by all the limits below plus the vault contract's own
    ///         constraints (no arbitrary destinations).
    address public keeper;

    /// @notice Pending keeper for two-step rotation. Modeled on the vault's `pendingOperator`.
    address public pendingKeeper;

    // ─── State: Bridge Cap (auto-resetting daily window) ──────────────────

    /// @notice Per-transaction bridge cap as a fraction of vault totalAssets, in bps.
    /// @dev    Bounded by MAX_PER_TX_BRIDGE_BPS at the contract level.
    uint256 public perTxBridgeBps;

    /// @notice Daily bridge cap as a fraction of vault totalAssets, in bps.
    /// @dev    Bounded by MAX_DAILY_BRIDGE_BPS at the contract level.
    uint256 public dailyBridgeBps;

    /// @notice Cumulative bridged amount in the current period.
    uint256 public bridgedThisPeriod;

    /// @notice Start timestamp of the current period.
    /// @dev    Aligned to UTC day boundaries via `block.timestamp / BRIDGE_PERIOD * BRIDGE_PERIOD`.
    ///         Period boundaries do not drift over time — same pattern as the Safe Allowance Module.
    uint256 public currentPeriodStart;

    /// @notice Snapshot of `vault.totalAssets()` used to fix the daily budget for the current period.
    /// @dev    Set at period rollover. If the period starts at zero TVL, the first bridge call of
    ///         that period lazily initializes it from the current asset base.
    uint256 public periodStartTotalAssets;

    // ─── State: Reserve Floor ─────────────────────────────────────────────

    /// @notice Minimum vault reserve (idle balance) the bridge action must preserve, in bps.
    /// @dev    Bounded by [MIN_ALLOWED_RESERVE_BPS, MAX_ALLOWED_RESERVE_BPS].
    uint256 public minReserveBps;

    // ─── State: Claim Cooldown ────────────────────────────────────────────

    /// @notice Minimum seconds between consecutive `autoClaimFromTN` calls.
    /// @dev    Bounded by [MIN_CLAIM_COOLDOWN, MAX_CLAIM_COOLDOWN].
    uint256 public claimCooldown;

    /// @notice Timestamp of the last `autoClaimFromTN` call.
    uint256 public lastClaimAt;

    // ─── Events ───────────────────────────────────────────────────────────

    event KeeperTransferStarted(address indexed currentKeeper, address indexed pendingKeeper);
    event KeeperTransferred(address indexed previousKeeper, address indexed newKeeper);

    event PerTxBridgeBpsSet(uint256 previousBps, uint256 newBps);
    event DailyBridgeBpsSet(uint256 previousBps, uint256 newBps);
    event MinReserveBpsSet(uint256 previousBps, uint256 newBps);
    event ClaimCooldownSet(uint256 previousSeconds, uint256 newSeconds);

    event AutoBridged(uint256 amount, uint256 bridgedThisPeriod, uint256 periodStart);
    event AutoClaimed(uint256 amount, uint256 claimedAt);

    event PeriodReset(uint256 previousStart, uint256 newStart);

    // ─── Errors ───────────────────────────────────────────────────────────

    error OnlyKeeper();
    error OnlySafe();
    error OnlyPendingKeeper();
    error ZeroAddress();
    error ZeroAmount();

    error VaultOperatorMismatch(address vaultOperator, address expectedSafe);
    error ModuleNotEnabled(address safeAddress, address moduleAddress);

    error PerTxBridgeBpsTooHigh(uint256 requested, uint256 maxAllowed);
    error DailyBridgeBpsTooHigh(uint256 requested, uint256 maxAllowed);
    error ReserveBpsOutOfBounds(uint256 requested, uint256 minAllowed, uint256 maxAllowed);
    error ClaimCooldownOutOfBounds(uint256 requested, uint256 minAllowed, uint256 maxAllowed);

    error PerTxCapExceeded(uint256 requested, uint256 cap);
    error DailyCapExceeded(uint256 requested, uint256 remainingInPeriod);
    error ReserveFloorBreached(uint256 idleAfter, uint256 minRequired);

    error ClaimCooldownNotElapsed(uint256 nextAllowedAt);
    error ClaimExceedsDeployed(uint256 requested, uint256 deployed);

    error SafeCallFailed();

    // ─── Modifiers ────────────────────────────────────────────────────────

    /// @dev Strictly the keeper address. No dual-role with the Safe — see Yearn divergence in docs.
    modifier onlyKeeper() {
        if (msg.sender != keeper) revert OnlyKeeper();
        _;
    }

    /// @dev Only the Safe itself can call admin functions. The Safe calls these by signing
    ///      a transaction that targets the module — same ceremony as any other governance action.
    modifier onlySafe() {
        if (msg.sender != address(safe)) revert OnlySafe();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────

    /// @param safe_ The Gnosis Safe this module attaches to. Must already be the operator of `vault_`.
    /// @param vault_ The TrufVault to manage.
    /// @param perTxBridgeBps_ Initial per-tx bridge cap. Must be <= MAX_PER_TX_BRIDGE_BPS.
    /// @param dailyBridgeBps_ Initial daily bridge cap. Must be <= MAX_DAILY_BRIDGE_BPS.
    /// @param minReserveBps_ Initial reserve floor. Must be in [MIN_ALLOWED_RESERVE_BPS, MAX_ALLOWED_RESERVE_BPS].
    /// @param claimCooldown_ Initial claim cooldown (seconds). Must be in [MIN_CLAIM_COOLDOWN, MAX_CLAIM_COOLDOWN].
    ///
    /// @dev The keeper is intentionally NOT set in the constructor. The multisig sets it after
    ///      deployment via `transferKeeper`/`acceptKeeper`. This means the module can be deployed
    ///      and reviewed before any keeper address is exposed to the system.
    ///
    ///      The constructor enforces:
    ///        1. Vault operator == safe (otherwise the module would deploy mis-targeted)
    ///        2. All four parameters are within hardcoded bounds
    ///
    ///      It does NOT enforce that the module is already enabled on the Safe — that has to
    ///      happen after deployment, by signing `enableModule(address(this))` on the Safe.
    constructor(
        ISafe safe_,
        TrufVault vault_,
        uint256 perTxBridgeBps_,
        uint256 dailyBridgeBps_,
        uint256 minReserveBps_,
        uint256 claimCooldown_
    ) {
        if (address(safe_) == address(0)) revert ZeroAddress();
        if (address(vault_) == address(0)) revert ZeroAddress();

        // Critical safety check — the Safe must already be the vault's operator.
        // Otherwise the module is wired to a vault it cannot drive, which is almost certainly
        // a deployment mistake.
        address vaultOperator = vault_.operator();
        if (vaultOperator != address(safe_)) {
            revert VaultOperatorMismatch(vaultOperator, address(safe_));
        }

        // Bounds checks. The constructor uses the same validators as the setters so a deployment
        // can never start in a state the multisig couldn't reach via the setter path.
        if (perTxBridgeBps_ == 0 || perTxBridgeBps_ > MAX_PER_TX_BRIDGE_BPS) {
            revert PerTxBridgeBpsTooHigh(perTxBridgeBps_, MAX_PER_TX_BRIDGE_BPS);
        }
        if (dailyBridgeBps_ == 0 || dailyBridgeBps_ > MAX_DAILY_BRIDGE_BPS) {
            revert DailyBridgeBpsTooHigh(dailyBridgeBps_, MAX_DAILY_BRIDGE_BPS);
        }
        if (minReserveBps_ < MIN_ALLOWED_RESERVE_BPS || minReserveBps_ > MAX_ALLOWED_RESERVE_BPS) {
            revert ReserveBpsOutOfBounds(minReserveBps_, MIN_ALLOWED_RESERVE_BPS, MAX_ALLOWED_RESERVE_BPS);
        }
        if (claimCooldown_ < MIN_CLAIM_COOLDOWN || claimCooldown_ > MAX_CLAIM_COOLDOWN) {
            revert ClaimCooldownOutOfBounds(claimCooldown_, MIN_CLAIM_COOLDOWN, MAX_CLAIM_COOLDOWN);
        }

        safe = safe_;
        vault = vault_;
        perTxBridgeBps = perTxBridgeBps_;
        dailyBridgeBps = dailyBridgeBps_;
        minReserveBps = minReserveBps_;
        claimCooldown = claimCooldown_;

        // Initialize the period to the current UTC day boundary.
        currentPeriodStart = (block.timestamp / BRIDGE_PERIOD) * BRIDGE_PERIOD;
        periodStartTotalAssets = vault_.totalAssets();
    }

    // ─── Keeper Functions ─────────────────────────────────────────────────

    /// @notice Bridge `amount` from the vault's idle balance to TN, on behalf of the Safe.
    /// @dev Enforces, in order:
    ///        1. Period rollover (lazy reset of `bridgedThisPeriod` if a new day has started)
    ///        2. Per-tx cap as a fraction of totalAssets
    ///        3. Daily cap as a fraction of totalAssets
    ///        4. Reserve floor preserved AFTER the bridge action
    ///      Then routes the call through the Safe to `vault.depositToTN(amount)`.
    ///
    ///      The vault's own checks (idle >= amount, nonReentrant, etc.) still apply.
    function autoBridgeToTN(uint256 amount) external onlyKeeper nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _rolloverPeriodIfNeeded();

        uint256 totalAssetsNow = vault.totalAssets();
        uint256 dailyCapBase = periodStartTotalAssets;
        if (dailyCapBase == 0) {
            dailyCapBase = totalAssetsNow;
            periodStartTotalAssets = totalAssetsNow;
        }

        // Per-tx cap
        uint256 perTxCap = (totalAssetsNow * perTxBridgeBps) / MAX_BPS;
        if (amount > perTxCap) revert PerTxCapExceeded(amount, perTxCap);

        // Daily cap, fixed from the period snapshot rather than live TVL.
        uint256 dailyCap = (dailyCapBase * dailyBridgeBps) / MAX_BPS;
        uint256 remainingToday = dailyCap > bridgedThisPeriod ? dailyCap - bridgedThisPeriod : 0;
        if (amount > remainingToday) revert DailyCapExceeded(amount, remainingToday);

        // Reserve floor — check that idle AFTER the bridge action stays above the floor.
        // totalAssets is unchanged by depositToTN (idle decreases by `amount`, deployedOnTN
        // increases by `amount`), so we use the same totalAssetsNow for the floor calculation.
        uint256 idleNow = vault.idleBalance();
        uint256 idleAfter = idleNow > amount ? idleNow - amount : 0;
        uint256 minRequiredIdle = (totalAssetsNow * minReserveBps) / MAX_BPS;
        if (idleAfter < minRequiredIdle) revert ReserveFloorBreached(idleAfter, minRequiredIdle);

        // Effects: update the period accumulator before the external call.
        bridgedThisPeriod += amount;

        // Interaction: route the call through the Safe.
        _execVaultCall(abi.encodeCall(TrufVault.depositToTN, (amount)));

        emit AutoBridged(amount, bridgedThisPeriod, currentPeriodStart);
    }

    /// @notice Claim `amount` from TN back to the vault, on behalf of the Safe.
    /// @dev Enforces, in order:
    ///        1. Cooldown elapsed since last claim
    ///        2. Amount does not exceed `vault.deployedOnTN()` (also enforced by the vault, but
    ///           cheaper to fail fast in the module)
    ///      Then routes the call through the Safe to `vault.claimFromTN(...)`.
    ///
    ///      Why no daily cap on claims:
    ///        - Claims only bring funds back into the vault. They cannot move funds out.
    ///        - Cooldown is sufficient to prevent claim spam DoS / gas waste.
    ///        - The vault's `claimFromTN` always sends funds to the vault itself — no recipient param.
    function autoClaimFromTN(
        uint256 amount,
        bytes32 kwilBlockHash,
        bytes32 root,
        bytes32[] calldata proof,
        ITrufNetworkBridge.Signature[] calldata signatures
    ) external onlyKeeper nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Cooldown
        uint256 nextAllowed = lastClaimAt + claimCooldown;
        if (block.timestamp < nextAllowed) revert ClaimCooldownNotElapsed(nextAllowed);

        // Sanity check against deployedOnTN — saves the keeper a wasted Safe transaction
        // if it tries to claim more than what's actually out there.
        uint256 deployed = vault.deployedOnTN();
        if (amount > deployed) revert ClaimExceedsDeployed(amount, deployed);

        // Effects
        lastClaimAt = block.timestamp;

        // Interaction
        _execVaultCall(
            abi.encodeCall(
                TrufVault.claimFromTN,
                (amount, kwilBlockHash, root, proof, signatures)
            )
        );

        emit AutoClaimed(amount, block.timestamp);
    }

    // ─── Safe-Only Admin Functions ────────────────────────────────────────

    /// @notice Step 1 of keeper rotation: the Safe sets a pending new keeper.
    /// @dev Two-step pattern matches the vault's `transferOperator`. Prevents fat-fingering and
    ///      forces the incoming keeper to demonstrate it controls the new key.
    function transferKeeper(address newKeeper) external onlySafe {
        if (newKeeper == address(0)) revert ZeroAddress();
        pendingKeeper = newKeeper;
        emit KeeperTransferStarted(keeper, newKeeper);
    }

    /// @notice Step 2 of keeper rotation: the new keeper address accepts.
    function acceptKeeper() external {
        if (msg.sender != pendingKeeper) revert OnlyPendingKeeper();
        address previous = keeper;
        keeper = pendingKeeper;
        pendingKeeper = address(0);
        emit KeeperTransferred(previous, keeper);
    }

    /// @notice Update the per-tx bridge cap. Bounded by MAX_PER_TX_BRIDGE_BPS.
    function setPerTxBridgeBps(uint256 newBps) external onlySafe {
        if (newBps == 0 || newBps > MAX_PER_TX_BRIDGE_BPS) {
            revert PerTxBridgeBpsTooHigh(newBps, MAX_PER_TX_BRIDGE_BPS);
        }
        uint256 previous = perTxBridgeBps;
        perTxBridgeBps = newBps;
        emit PerTxBridgeBpsSet(previous, newBps);
    }

    /// @notice Update the daily bridge cap. Bounded by MAX_DAILY_BRIDGE_BPS.
    function setDailyBridgeBps(uint256 newBps) external onlySafe {
        if (newBps == 0 || newBps > MAX_DAILY_BRIDGE_BPS) {
            revert DailyBridgeBpsTooHigh(newBps, MAX_DAILY_BRIDGE_BPS);
        }
        uint256 previous = dailyBridgeBps;
        dailyBridgeBps = newBps;
        emit DailyBridgeBpsSet(previous, newBps);
    }

    /// @notice Update the reserve floor. Bounded by [MIN_ALLOWED_RESERVE_BPS, MAX_ALLOWED_RESERVE_BPS].
    function setMinReserveBps(uint256 newBps) external onlySafe {
        if (newBps < MIN_ALLOWED_RESERVE_BPS || newBps > MAX_ALLOWED_RESERVE_BPS) {
            revert ReserveBpsOutOfBounds(newBps, MIN_ALLOWED_RESERVE_BPS, MAX_ALLOWED_RESERVE_BPS);
        }
        uint256 previous = minReserveBps;
        minReserveBps = newBps;
        emit MinReserveBpsSet(previous, newBps);
    }

    /// @notice Update the claim cooldown. Bounded by [MIN_CLAIM_COOLDOWN, MAX_CLAIM_COOLDOWN].
    function setClaimCooldown(uint256 newSeconds) external onlySafe {
        if (newSeconds < MIN_CLAIM_COOLDOWN || newSeconds > MAX_CLAIM_COOLDOWN) {
            revert ClaimCooldownOutOfBounds(newSeconds, MIN_CLAIM_COOLDOWN, MAX_CLAIM_COOLDOWN);
        }
        uint256 previous = claimCooldown;
        claimCooldown = newSeconds;
        emit ClaimCooldownSet(previous, newSeconds);
    }

    // ─── View Helpers ─────────────────────────────────────────────────────

    /// @notice Returns the per-tx bridge cap in absolute asset units, computed against current totalAssets.
    function currentPerTxCap() external view returns (uint256) {
        return (vault.totalAssets() * perTxBridgeBps) / MAX_BPS;
    }

    /// @notice Returns the daily bridge cap in absolute asset units for the current period snapshot.
    function currentDailyCap() external view returns (uint256) {
        return (_effectivePeriodStartTotalAssets() * dailyBridgeBps) / MAX_BPS;
    }

    /// @notice Returns the remaining bridgeable amount in the current period, accounting for rollover.
    function remainingBridgeableThisPeriod() external view returns (uint256) {
        uint256 dailyCap = (_effectivePeriodStartTotalAssets() * dailyBridgeBps) / MAX_BPS;
        // If we'd roll over on the next call, the full cap is available again.
        if (block.timestamp >= currentPeriodStart + BRIDGE_PERIOD) return dailyCap;
        return dailyCap > bridgedThisPeriod ? dailyCap - bridgedThisPeriod : 0;
    }

    /// @notice Returns the timestamp at which the next claim is allowed.
    function nextClaimAllowedAt() external view returns (uint256) {
        return lastClaimAt + claimCooldown;
    }

    // ─── Internal ─────────────────────────────────────────────────────────

    /// @dev Lazy period rollover. Same pattern as Safe Allowance Module / Lido LimitsChecker.
    ///      Aligned to UTC day boundaries so the daily window does not drift over time.
    function _rolloverPeriodIfNeeded() internal {
        uint256 alignedNow = (block.timestamp / BRIDGE_PERIOD) * BRIDGE_PERIOD;
        if (alignedNow > currentPeriodStart) {
            uint256 previousStart = currentPeriodStart;
            currentPeriodStart = alignedNow;
            bridgedThisPeriod = 0;
            periodStartTotalAssets = vault.totalAssets();
            emit PeriodReset(previousStart, alignedNow);
        }
    }

    /// @dev View helper that mirrors the lazy snapshotting semantics used by `autoBridgeToTN`.
    function _effectivePeriodStartTotalAssets() internal view returns (uint256) {
        if (block.timestamp >= currentPeriodStart + BRIDGE_PERIOD) {
            return vault.totalAssets();
        }
        if (periodStartTotalAssets == 0 && bridgedThisPeriod == 0) {
            return vault.totalAssets();
        }
        return periodStartTotalAssets;
    }

    /// @dev Internal helper that wraps the single point of contact between this module and the Safe.
    ///      Modeled on Zodiac's Module.exec() — every interaction with the Safe goes through this
    ///      one function, so the auditor has exactly one place to verify the call shape.
    function _execVaultCall(bytes memory data) internal {
        bool success = safe.execTransactionFromModule(
            address(vault),
            0,
            data,
            ISafe.Operation.Call
        );
        if (!success) revert SafeCallFailed();
    }
}
