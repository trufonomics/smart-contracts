// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TrufVault} from "../src/TrufVault.sol";
import {ITrufNetworkBridge} from "../src/interfaces/ITrufNetworkBridge.sol";
import {AutoBridgeModule} from "../src/automation/AutoBridgeModule.sol";
import {ISafe} from "../src/automation/ISafe.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBridge} from "./mocks/MockBridge.sol";
import {MockSafe} from "./mocks/MockSafe.sol";

/// @dev Tests for AutoBridgeModule. Verifies access control, rate limits, reserve floor,
///      cooldowns, two-step keeper rotation, and the kill switch.
///
///      Test layout mirrors TrufVault.t.sol — single contract, section headers, makeAddr,
///      vm.prank, custom error matching with vm.expectRevert(abi.encodeWithSelector(...)).
contract AutoBridgeModuleTest is Test {
    TrufVault public vault;
    MockERC20 public token;
    MockBridge public bridge;
    MockSafe public safe;
    AutoBridgeModule public module;

    address public curator = makeAddr("curator");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public keeperEOA = makeAddr("keeperEOA");
    address public newKeeperEOA = makeAddr("newKeeperEOA");
    address public attacker = makeAddr("attacker");

    uint256 constant INITIAL_BALANCE = 1_000_000e6; // 1M USDC
    uint256 constant ALICE_DEPOSIT = 100_000e6; // 100K USDC

    // Default module parameters
    uint256 constant INIT_PER_TX_BPS = 1000; // 10%
    uint256 constant INIT_DAILY_BPS = 3000; // 30%
    uint256 constant INIT_RESERVE_BPS = 1500; // 15%
    uint256 constant INIT_COOLDOWN = 1 hours;

    function setUp() public {
        token = new MockERC20("Test USDC", "USDC", 6);
        bridge = new MockBridge(address(token));
        safe = new MockSafe();

        // Vault is owned by the Safe (operator = safe)
        vault = new TrufVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(bridge)),
            address(safe),
            curator,
            "TrufVault Share",
            "tvUSDC"
        );

        // Deploy the module
        module = new AutoBridgeModule(
            ISafe(address(safe)), vault, INIT_PER_TX_BPS, INIT_DAILY_BPS, INIT_RESERVE_BPS, INIT_COOLDOWN
        );

        // Install the module on the Safe (in real life: 2-of-3 multisig signs enableModule)
        safe.enableModule(address(module));

        // Set up the keeper (in real life: 2-of-3 multisig signs transferKeeper, then bot calls acceptKeeper)
        bytes memory transferKeeperData = abi.encodeCall(AutoBridgeModule.transferKeeper, (keeperEOA));
        safe.execAsSafe(address(module), transferKeeperData);
        vm.prank(keeperEOA);
        module.acceptKeeper();

        // Fund alice and have her deposit so the vault has totalAssets > 0
        token.mint(alice, INITIAL_BALANCE);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(ALICE_DEPOSIT, alice);

        // Fund the bridge so withdrawals can succeed
        token.mint(address(this), INITIAL_BALANCE);
        token.approve(address(bridge), type(uint256).max);
        bridge.fundEscrow(INITIAL_BALANCE);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_setsImmutables() public view {
        assertEq(address(module.safe()), address(safe));
        assertEq(address(module.vault()), address(vault));
    }

    function test_constructor_setsInitialParameters() public view {
        assertEq(module.perTxBridgeBps(), INIT_PER_TX_BPS);
        assertEq(module.dailyBridgeBps(), INIT_DAILY_BPS);
        assertEq(module.minReserveBps(), INIT_RESERVE_BPS);
        assertEq(module.claimCooldown(), INIT_COOLDOWN);
    }

    function test_constructor_keeperUnsetByDefault() public {
        // Re-deploy a fresh module to test that keeper is unset before transferKeeper
        AutoBridgeModule fresh = new AutoBridgeModule(
            ISafe(address(safe)), vault, INIT_PER_TX_BPS, INIT_DAILY_BPS, INIT_RESERVE_BPS, INIT_COOLDOWN
        );
        assertEq(fresh.keeper(), address(0));
        assertEq(fresh.pendingKeeper(), address(0));
    }

    function test_constructor_alignsCurrentPeriodToUtcDay() public view {
        uint256 expected = (block.timestamp / 1 days) * 1 days;
        assertEq(module.currentPeriodStart(), expected);
    }

    function test_constructor_revertsZeroSafe() public {
        vm.expectRevert(AutoBridgeModule.ZeroAddress.selector);
        new AutoBridgeModule(ISafe(address(0)), vault, INIT_PER_TX_BPS, INIT_DAILY_BPS, INIT_RESERVE_BPS, INIT_COOLDOWN);
    }

    function test_constructor_revertsZeroVault() public {
        vm.expectRevert(AutoBridgeModule.ZeroAddress.selector);
        new AutoBridgeModule(
            ISafe(address(safe)),
            TrufVault(address(0)),
            INIT_PER_TX_BPS,
            INIT_DAILY_BPS,
            INIT_RESERVE_BPS,
            INIT_COOLDOWN
        );
    }

    function test_constructor_revertsVaultOperatorMismatch() public {
        // A second Safe that is NOT the vault's operator
        MockSafe wrongSafe = new MockSafe();

        vm.expectRevert(
            abi.encodeWithSelector(AutoBridgeModule.VaultOperatorMismatch.selector, address(safe), address(wrongSafe))
        );
        new AutoBridgeModule(
            ISafe(address(wrongSafe)), vault, INIT_PER_TX_BPS, INIT_DAILY_BPS, INIT_RESERVE_BPS, INIT_COOLDOWN
        );
    }

    function test_constructor_revertsPerTxBpsZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(AutoBridgeModule.PerTxBridgeBpsTooHigh.selector, 0, module.MAX_PER_TX_BRIDGE_BPS())
        );
        new AutoBridgeModule(ISafe(address(safe)), vault, 0, INIT_DAILY_BPS, INIT_RESERVE_BPS, INIT_COOLDOWN);
    }

    function test_constructor_revertsPerTxBpsTooHigh() public {
        uint256 bad = module.MAX_PER_TX_BRIDGE_BPS() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(AutoBridgeModule.PerTxBridgeBpsTooHigh.selector, bad, module.MAX_PER_TX_BRIDGE_BPS())
        );
        new AutoBridgeModule(ISafe(address(safe)), vault, bad, INIT_DAILY_BPS, INIT_RESERVE_BPS, INIT_COOLDOWN);
    }

    function test_constructor_revertsDailyBpsTooHigh() public {
        uint256 bad = module.MAX_DAILY_BRIDGE_BPS() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(AutoBridgeModule.DailyBridgeBpsTooHigh.selector, bad, module.MAX_DAILY_BRIDGE_BPS())
        );
        new AutoBridgeModule(ISafe(address(safe)), vault, INIT_PER_TX_BPS, bad, INIT_RESERVE_BPS, INIT_COOLDOWN);
    }

    function test_constructor_revertsReserveBpsTooLow() public {
        uint256 bad = module.MIN_ALLOWED_RESERVE_BPS() - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                AutoBridgeModule.ReserveBpsOutOfBounds.selector,
                bad,
                module.MIN_ALLOWED_RESERVE_BPS(),
                module.MAX_ALLOWED_RESERVE_BPS()
            )
        );
        new AutoBridgeModule(ISafe(address(safe)), vault, INIT_PER_TX_BPS, INIT_DAILY_BPS, bad, INIT_COOLDOWN);
    }

    function test_constructor_revertsReserveBpsTooHigh() public {
        uint256 bad = module.MAX_ALLOWED_RESERVE_BPS() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                AutoBridgeModule.ReserveBpsOutOfBounds.selector,
                bad,
                module.MIN_ALLOWED_RESERVE_BPS(),
                module.MAX_ALLOWED_RESERVE_BPS()
            )
        );
        new AutoBridgeModule(ISafe(address(safe)), vault, INIT_PER_TX_BPS, INIT_DAILY_BPS, bad, INIT_COOLDOWN);
    }

    function test_constructor_revertsCooldownTooLow() public {
        uint256 bad = module.MIN_CLAIM_COOLDOWN() - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                AutoBridgeModule.ClaimCooldownOutOfBounds.selector,
                bad,
                module.MIN_CLAIM_COOLDOWN(),
                module.MAX_CLAIM_COOLDOWN()
            )
        );
        new AutoBridgeModule(ISafe(address(safe)), vault, INIT_PER_TX_BPS, INIT_DAILY_BPS, INIT_RESERVE_BPS, bad);
    }

    function test_constructor_revertsCooldownTooHigh() public {
        uint256 bad = module.MAX_CLAIM_COOLDOWN() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                AutoBridgeModule.ClaimCooldownOutOfBounds.selector,
                bad,
                module.MIN_CLAIM_COOLDOWN(),
                module.MAX_CLAIM_COOLDOWN()
            )
        );
        new AutoBridgeModule(ISafe(address(safe)), vault, INIT_PER_TX_BPS, INIT_DAILY_BPS, INIT_RESERVE_BPS, bad);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  KEEPER ACCESS
    // ═══════════════════════════════════════════════════════════════════════

    function test_autoBridge_revertsNonKeeper() public {
        vm.prank(attacker);
        vm.expectRevert(AutoBridgeModule.OnlyKeeper.selector);
        module.autoBridgeToTN(1_000e6);
    }

    function test_autoClaim_revertsNonKeeper() public {
        bytes32[] memory proof = new bytes32[](0);
        ITrufNetworkBridge.Signature[] memory sigs = new ITrufNetworkBridge.Signature[](0);

        vm.prank(attacker);
        vm.expectRevert(AutoBridgeModule.OnlyKeeper.selector);
        module.autoClaimFromTN(1_000e6, bytes32(0), bytes32(0), proof, sigs);
    }

    function test_safeCannotCallKeeperFunctions() public {
        // Even the Safe itself cannot call keeper functions — strict single-role access
        bytes memory data = abi.encodeCall(AutoBridgeModule.autoBridgeToTN, (1_000e6));
        vm.expectRevert("MockSafe: execAsSafe failed");
        safe.execAsSafe(address(module), data);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  AUTO BRIDGE — HAPPY PATH
    // ═══════════════════════════════════════════════════════════════════════

    function test_autoBridge_executesAndUpdatesState() public {
        // Per-tx cap = 10% of 100K = 10K
        uint256 amount = 5_000e6;

        uint256 idleBefore = vault.idleBalance();
        uint256 deployedBefore = vault.deployedOnTN();

        vm.prank(keeperEOA);
        module.autoBridgeToTN(amount);

        assertEq(vault.idleBalance(), idleBefore - amount);
        assertEq(vault.deployedOnTN(), deployedBefore + amount);
        assertEq(module.bridgedThisPeriod(), amount);
        // totalAssets unchanged
        assertEq(vault.totalAssets(), ALICE_DEPOSIT);
    }

    function test_autoBridge_atPerTxCap() public {
        // Per-tx cap = 10% * 100K = 10K
        uint256 amount = 10_000e6;

        vm.prank(keeperEOA);
        module.autoBridgeToTN(amount);

        assertEq(module.bridgedThisPeriod(), amount);
    }

    function test_autoBridge_revertsZeroAmount() public {
        vm.prank(keeperEOA);
        vm.expectRevert(AutoBridgeModule.ZeroAmount.selector);
        module.autoBridgeToTN(0);
    }

    function test_autoBridge_revertsPerTxCapExceeded() public {
        // Per-tx cap = 10% * 100K = 10K. Try 10K + 1.
        uint256 amount = 10_000e6 + 1;
        uint256 expectedCap = (ALICE_DEPOSIT * INIT_PER_TX_BPS) / 10_000;

        vm.prank(keeperEOA);
        vm.expectRevert(abi.encodeWithSelector(AutoBridgeModule.PerTxCapExceeded.selector, amount, expectedCap));
        module.autoBridgeToTN(amount);
    }

    function test_autoBridge_revertsDailyCapExceeded() public {
        // Daily cap = 30% * 100K = 30K. Per-tx cap = 10% * 100K = 10K.
        // Three full per-tx bridges hit 30K total. The 4th should fail.
        vm.prank(keeperEOA);
        module.autoBridgeToTN(10_000e6);
        vm.prank(keeperEOA);
        module.autoBridgeToTN(10_000e6);
        vm.prank(keeperEOA);
        module.autoBridgeToTN(10_000e6);

        assertEq(module.bridgedThisPeriod(), 30_000e6);

        // 4th call — daily cap exhausted (remainingToday == 0)
        vm.prank(keeperEOA);
        vm.expectRevert(abi.encodeWithSelector(AutoBridgeModule.DailyCapExceeded.selector, 1, 0));
        module.autoBridgeToTN(1);
    }

    function test_autoBridge_reserveFloorActuallyBreaches() public {
        // Construct a deliberate breach: deploy a fresh module with reserve floor 50%,
        // perTxBps = 1000 (10%), dailyBps = 3000 (30%). Then have the Safe (as operator)
        // bridge funds OUT manually so totalAssets is concentrated on TN side, and have
        // the keeper try to bridge what little idle is left.

        // Manual bridge by Safe: bridge 50K out
        bytes memory depositData = abi.encodeCall(TrufVault.depositToTN, (50_000e6));
        safe.execAsSafe(address(vault), depositData);

        // State: idle = 50K, deployed = 50K, totalAssets = 100K
        assertEq(vault.idleBalance(), 50_000e6);
        assertEq(vault.deployedOnTN(), 50_000e6);

        // Per-tx cap = 10% * 100K = 10K. Daily cap = 30% * 100K = 30K. Reserve floor = 15% * 100K = 15K.
        // Bridging 10K → idleAfter = 40K, still > 15K. OK. Doesn't breach.
        // Bridge 3 times → 20K, idleAfter = 30K. Still > 15K. OK.
        // 4th time hits daily cap.
        //
        // To make reserve floor trip first, need: idle - amount < reserveFloor, but amount within caps.
        // idle = 50K, reserveFloor = 15K → must bridge > 35K in one tx → exceeds per-tx cap (10K).
        //
        // Alternative: shrink idle first. Do 2 manual bridges of 10K → idle = 30K, deployed = 70K, total = 100K.
        bytes memory depositData2 = abi.encodeCall(TrufVault.depositToTN, (10_000e6));
        safe.execAsSafe(address(vault), depositData2);
        safe.execAsSafe(address(vault), depositData2);

        assertEq(vault.idleBalance(), 30_000e6);
        assertEq(vault.deployedOnTN(), 70_000e6);

        // Now: per-tx cap = 10K, reserve floor = 15K. Bridge 10K → idleAfter = 20K, still > 15K. OK.
        // Bridge 10K twice → idle = 10K. Now < 15K → reserve floor breach.
        vm.prank(keeperEOA);
        module.autoBridgeToTN(10_000e6);

        assertEq(vault.idleBalance(), 20_000e6);

        // Next 10K bridge: idleAfter = 10K, reserveFloor = 15K → BREACH
        vm.prank(keeperEOA);
        vm.expectRevert(abi.encodeWithSelector(AutoBridgeModule.ReserveFloorBreached.selector, 10_000e6, 15_000e6));
        module.autoBridgeToTN(10_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  PERIOD ROLLOVER
    // ═══════════════════════════════════════════════════════════════════════

    function test_periodRollover_resetsAfterDay() public {
        // Bridge up to daily cap
        vm.prank(keeperEOA);
        module.autoBridgeToTN(10_000e6);
        vm.prank(keeperEOA);
        module.autoBridgeToTN(10_000e6);
        vm.prank(keeperEOA);
        module.autoBridgeToTN(10_000e6);

        assertEq(module.bridgedThisPeriod(), 30_000e6);

        // Advance to next UTC day
        uint256 oldStart = module.currentPeriodStart();
        vm.warp(oldStart + 1 days + 1);

        // Bridging now should succeed and reset the counter
        vm.prank(keeperEOA);
        module.autoBridgeToTN(5_000e6);

        assertEq(module.bridgedThisPeriod(), 5_000e6);
        assertGt(module.currentPeriodStart(), oldStart);
    }

    function test_periodRollover_alignsToUtcDay() public {
        // Warp to mid-day
        uint256 baseDay = (block.timestamp / 1 days) * 1 days;
        vm.warp(baseDay + 12 hours);

        vm.prank(keeperEOA);
        module.autoBridgeToTN(5_000e6);

        // Period start should still be the day boundary, not the bridge time
        assertEq(module.currentPeriodStart(), baseDay);

        // Warp 13 hours forward — into the next day at 01:00
        vm.warp(baseDay + 25 hours);

        vm.prank(keeperEOA);
        module.autoBridgeToTN(5_000e6);

        // Period start should now be baseDay + 1 day (aligned, not baseDay + 25 hours)
        assertEq(module.currentPeriodStart(), baseDay + 1 days);
    }

    function test_remainingBridgeable_reflectsRollover() public {
        vm.prank(keeperEOA);
        module.autoBridgeToTN(10_000e6);

        // Within period: 30K - 10K = 20K remaining
        assertEq(module.remainingBridgeableThisPeriod(), 20_000e6);

        // Advance past day boundary
        vm.warp(block.timestamp + 1 days + 1);

        // After rollover: full 30K available again (view simulates the rollover)
        assertEq(module.remainingBridgeableThisPeriod(), 30_000e6);
    }

    function test_dailyCap_doesNotExpandAfterMidPeriodDeposit() public {
        vm.prank(keeperEOA);
        module.autoBridgeToTN(10_000e6);
        vm.prank(keeperEOA);
        module.autoBridgeToTN(10_000e6);
        vm.prank(keeperEOA);
        module.autoBridgeToTN(10_000e6);

        assertEq(module.currentDailyCap(), 30_000e6);
        assertEq(module.remainingBridgeableThisPeriod(), 0);

        token.mint(bob, ALICE_DEPOSIT);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        vault.deposit(ALICE_DEPOSIT, bob);

        // Live TVL doubled, so the per-tx cap expands, but the daily budget stays fixed to the
        // period snapshot taken before the first bridge of the day.
        assertEq(module.currentPerTxCap(), 20_000e6);
        assertEq(module.currentDailyCap(), 30_000e6);
        assertEq(module.remainingBridgeableThisPeriod(), 0);

        vm.prank(keeperEOA);
        vm.expectRevert(abi.encodeWithSelector(AutoBridgeModule.DailyCapExceeded.selector, 1, 0));
        module.autoBridgeToTN(1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  AUTO CLAIM
    // ═══════════════════════════════════════════════════════════════════════

    function test_autoClaim_revertsZeroAmount() public {
        bytes32[] memory proof = new bytes32[](0);
        ITrufNetworkBridge.Signature[] memory sigs = new ITrufNetworkBridge.Signature[](0);

        // Skip past the initial cooldown so we get the right error
        vm.warp(block.timestamp + 1 days);

        vm.prank(keeperEOA);
        vm.expectRevert(AutoBridgeModule.ZeroAmount.selector);
        module.autoClaimFromTN(0, bytes32(0), bytes32(0), proof, sigs);
    }

    function test_autoClaim_executesAndUpdatesState() public {
        // First bridge some funds out so we can claim them back
        vm.prank(keeperEOA);
        module.autoBridgeToTN(10_000e6);

        // Skip past initial cooldown
        vm.warp(block.timestamp + INIT_COOLDOWN + 1);

        bytes32[] memory proof = new bytes32[](0);
        ITrufNetworkBridge.Signature[] memory sigs = new ITrufNetworkBridge.Signature[](0);

        uint256 idleBefore = vault.idleBalance();
        uint256 deployedBefore = vault.deployedOnTN();

        vm.prank(keeperEOA);
        module.autoClaimFromTN(5_000e6, bytes32(0), bytes32(0), proof, sigs);

        assertEq(vault.idleBalance(), idleBefore + 5_000e6);
        assertEq(vault.deployedOnTN(), deployedBefore - 5_000e6);
        assertEq(module.lastClaimAt(), block.timestamp);
    }

    function test_autoClaim_revertsCooldownNotElapsed() public {
        // Bridge first
        vm.prank(keeperEOA);
        module.autoBridgeToTN(10_000e6);

        // Skip past initial cooldown so first claim succeeds
        vm.warp(block.timestamp + INIT_COOLDOWN + 1);

        bytes32[] memory proof = new bytes32[](0);
        ITrufNetworkBridge.Signature[] memory sigs = new ITrufNetworkBridge.Signature[](0);

        vm.prank(keeperEOA);
        module.autoClaimFromTN(2_000e6, bytes32(0), bytes32(0), proof, sigs);

        // Immediately try again — cooldown not elapsed
        uint256 nextAllowed = module.lastClaimAt() + INIT_COOLDOWN;
        vm.prank(keeperEOA);
        vm.expectRevert(abi.encodeWithSelector(AutoBridgeModule.ClaimCooldownNotElapsed.selector, nextAllowed));
        module.autoClaimFromTN(1_000e6, bytes32(0), bytes32(0), proof, sigs);
    }

    function test_autoClaim_revertsExceedsDeployed() public {
        // Bridge a small amount
        vm.prank(keeperEOA);
        module.autoBridgeToTN(2_000e6);

        vm.warp(block.timestamp + INIT_COOLDOWN + 1);

        bytes32[] memory proof = new bytes32[](0);
        ITrufNetworkBridge.Signature[] memory sigs = new ITrufNetworkBridge.Signature[](0);

        vm.prank(keeperEOA);
        vm.expectRevert(abi.encodeWithSelector(AutoBridgeModule.ClaimExceedsDeployed.selector, 3_000e6, 2_000e6));
        module.autoClaimFromTN(3_000e6, bytes32(0), bytes32(0), proof, sigs);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  TWO-STEP KEEPER ROTATION
    // ═══════════════════════════════════════════════════════════════════════

    function test_transferKeeper_setsPending() public {
        bytes memory data = abi.encodeCall(AutoBridgeModule.transferKeeper, (newKeeperEOA));
        safe.execAsSafe(address(module), data);

        assertEq(module.pendingKeeper(), newKeeperEOA);
        // Old keeper still active until accept
        assertEq(module.keeper(), keeperEOA);
    }

    function test_transferKeeper_revertsNonSafe() public {
        vm.prank(attacker);
        vm.expectRevert(AutoBridgeModule.OnlySafe.selector);
        module.transferKeeper(newKeeperEOA);
    }

    function test_transferKeeper_revertsZeroAddress() public {
        bytes memory data = abi.encodeCall(AutoBridgeModule.transferKeeper, (address(0)));
        vm.expectRevert("MockSafe: execAsSafe failed");
        safe.execAsSafe(address(module), data);
    }

    function test_acceptKeeper_completesRotation() public {
        bytes memory data = abi.encodeCall(AutoBridgeModule.transferKeeper, (newKeeperEOA));
        safe.execAsSafe(address(module), data);

        vm.prank(newKeeperEOA);
        module.acceptKeeper();

        assertEq(module.keeper(), newKeeperEOA);
        assertEq(module.pendingKeeper(), address(0));
    }

    function test_acceptKeeper_revertsNonPending() public {
        bytes memory data = abi.encodeCall(AutoBridgeModule.transferKeeper, (newKeeperEOA));
        safe.execAsSafe(address(module), data);

        vm.prank(attacker);
        vm.expectRevert(AutoBridgeModule.OnlyPendingKeeper.selector);
        module.acceptKeeper();
    }

    function test_keeperRotation_oldKeeperLosesAccess() public {
        bytes memory data = abi.encodeCall(AutoBridgeModule.transferKeeper, (newKeeperEOA));
        safe.execAsSafe(address(module), data);

        vm.prank(newKeeperEOA);
        module.acceptKeeper();

        // Old keeper can no longer call
        vm.prank(keeperEOA);
        vm.expectRevert(AutoBridgeModule.OnlyKeeper.selector);
        module.autoBridgeToTN(1_000e6);

        // New keeper can
        vm.prank(newKeeperEOA);
        module.autoBridgeToTN(1_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  PARAMETER UPDATES (SAFE-ONLY)
    // ═══════════════════════════════════════════════════════════════════════

    function test_setPerTxBridgeBps_updates() public {
        bytes memory data = abi.encodeCall(AutoBridgeModule.setPerTxBridgeBps, (500));
        safe.execAsSafe(address(module), data);
        assertEq(module.perTxBridgeBps(), 500);
    }

    function test_setPerTxBridgeBps_revertsNonSafe() public {
        vm.prank(attacker);
        vm.expectRevert(AutoBridgeModule.OnlySafe.selector);
        module.setPerTxBridgeBps(500);
    }

    function test_setPerTxBridgeBps_revertsAboveCeiling() public {
        uint256 bad = module.MAX_PER_TX_BRIDGE_BPS() + 1;
        bytes memory data = abi.encodeCall(AutoBridgeModule.setPerTxBridgeBps, (bad));
        vm.expectRevert("MockSafe: execAsSafe failed");
        safe.execAsSafe(address(module), data);
    }

    function test_setPerTxBridgeBps_revertsZero() public {
        bytes memory data = abi.encodeCall(AutoBridgeModule.setPerTxBridgeBps, (0));
        vm.expectRevert("MockSafe: execAsSafe failed");
        safe.execAsSafe(address(module), data);
    }

    function test_setDailyBridgeBps_updates() public {
        bytes memory data = abi.encodeCall(AutoBridgeModule.setDailyBridgeBps, (2000));
        safe.execAsSafe(address(module), data);
        assertEq(module.dailyBridgeBps(), 2000);
    }

    function test_setDailyBridgeBps_revertsNonSafe() public {
        vm.prank(attacker);
        vm.expectRevert(AutoBridgeModule.OnlySafe.selector);
        module.setDailyBridgeBps(2000);
    }

    function test_setDailyBridgeBps_revertsAboveCeiling() public {
        uint256 bad = module.MAX_DAILY_BRIDGE_BPS() + 1;
        bytes memory data = abi.encodeCall(AutoBridgeModule.setDailyBridgeBps, (bad));
        vm.expectRevert("MockSafe: execAsSafe failed");
        safe.execAsSafe(address(module), data);
    }

    function test_setMinReserveBps_updates() public {
        bytes memory data = abi.encodeCall(AutoBridgeModule.setMinReserveBps, (2000));
        safe.execAsSafe(address(module), data);
        assertEq(module.minReserveBps(), 2000);
    }

    function test_setMinReserveBps_revertsNonSafe() public {
        vm.prank(attacker);
        vm.expectRevert(AutoBridgeModule.OnlySafe.selector);
        module.setMinReserveBps(2000);
    }

    function test_setMinReserveBps_revertsBelowFloor() public {
        uint256 bad = module.MIN_ALLOWED_RESERVE_BPS() - 1;
        bytes memory data = abi.encodeCall(AutoBridgeModule.setMinReserveBps, (bad));
        vm.expectRevert("MockSafe: execAsSafe failed");
        safe.execAsSafe(address(module), data);
    }

    function test_setMinReserveBps_revertsAboveCeiling() public {
        uint256 bad = module.MAX_ALLOWED_RESERVE_BPS() + 1;
        bytes memory data = abi.encodeCall(AutoBridgeModule.setMinReserveBps, (bad));
        vm.expectRevert("MockSafe: execAsSafe failed");
        safe.execAsSafe(address(module), data);
    }

    function test_setClaimCooldown_updates() public {
        bytes memory data = abi.encodeCall(AutoBridgeModule.setClaimCooldown, (30 minutes));
        safe.execAsSafe(address(module), data);
        assertEq(module.claimCooldown(), 30 minutes);
    }

    function test_setClaimCooldown_revertsNonSafe() public {
        vm.prank(attacker);
        vm.expectRevert(AutoBridgeModule.OnlySafe.selector);
        module.setClaimCooldown(30 minutes);
    }

    function test_setClaimCooldown_revertsBelowFloor() public {
        uint256 bad = module.MIN_CLAIM_COOLDOWN() - 1;
        bytes memory data = abi.encodeCall(AutoBridgeModule.setClaimCooldown, (bad));
        vm.expectRevert("MockSafe: execAsSafe failed");
        safe.execAsSafe(address(module), data);
    }

    function test_setClaimCooldown_revertsAboveCeiling() public {
        uint256 bad = module.MAX_CLAIM_COOLDOWN() + 1;
        bytes memory data = abi.encodeCall(AutoBridgeModule.setClaimCooldown, (bad));
        vm.expectRevert("MockSafe: execAsSafe failed");
        safe.execAsSafe(address(module), data);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  KILL SWITCH (disableModule)
    // ═══════════════════════════════════════════════════════════════════════

    function test_disableModule_revokesAllPower() public {
        // Bridge once to confirm the module is functional
        vm.prank(keeperEOA);
        module.autoBridgeToTN(1_000e6);

        // Multisig disables the module on the Safe
        safe.disableModule(address(module));

        // Now the keeper's call still passes the module's onlyKeeper check, but the Safe
        // refuses execTransactionFromModule, so _execVaultCall reverts.
        vm.prank(keeperEOA);
        vm.expectRevert();
        module.autoBridgeToTN(1_000e6);
    }

    function test_disableModule_doesNotAffectVault() public {
        // Disable the module
        safe.disableModule(address(module));

        // Vault still works for direct (manual) operator calls
        bytes memory data = abi.encodeCall(TrufVault.depositToTN, (5_000e6));
        safe.execAsSafe(address(vault), data);

        assertEq(vault.deployedOnTN(), 5_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  NO ESCALATION — module cannot reach forbidden vault functions
    // ═══════════════════════════════════════════════════════════════════════

    function test_module_hasNoCodePathToPause() public {
        // The module exposes no function that calls vault.pause(). The only way to
        // exercise this is to inspect the contract code — there is no test we can write
        // that demonstrates absence. But we CAN verify that calling pause as the module
        // address (without going through the Safe) fails on the vault's onlyOperator,
        // confirming the module has no operator role.
        vm.prank(address(module));
        vm.expectRevert(TrufVault.OnlyOperator.selector);
        vault.pause();
    }

    function test_module_hasNoCodePathToRecordPnL() public {
        vm.prank(address(module));
        vm.expectRevert(TrufVault.OnlyOperator.selector);
        vault.recordPnL(100);
    }

    function test_module_hasNoCodePathToTransferOperator() public {
        vm.prank(address(module));
        vm.expectRevert(TrufVault.OnlyOperator.selector);
        vault.transferOperator(attacker);
    }

    function test_module_hasNoCodePathToSetFee() public {
        vm.prank(address(module));
        vm.expectRevert(TrufVault.OnlyOperator.selector);
        vault.setFee(0.1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  VIEW HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function test_currentPerTxCap_returnsExpected() public view {
        // 10% of 100K = 10K
        assertEq(module.currentPerTxCap(), 10_000e6);
    }

    function test_currentDailyCap_returnsExpected() public view {
        // 30% of 100K = 30K
        assertEq(module.currentDailyCap(), 30_000e6);
    }

    function test_nextClaimAllowedAt_returnsExpected() public view {
        assertEq(module.nextClaimAllowedAt(), module.lastClaimAt() + INIT_COOLDOWN);
    }
}
