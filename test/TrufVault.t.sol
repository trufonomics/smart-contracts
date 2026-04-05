// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TrufVault} from "../src/TrufVault.sol";
import {TrufVaultFactory} from "../src/TrufVaultFactory.sol";
import {ITrufNetworkBridge} from "../src/interfaces/ITrufNetworkBridge.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBridge} from "./mocks/MockBridge.sol";

contract TrufVaultTest is Test {
    TrufVault public vault;
    MockERC20 public token;
    MockBridge public bridge;

    address public operator = makeAddr("operator");
    address public curator = makeAddr("curator");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public attacker = makeAddr("attacker");
    address public feeReceiver = makeAddr("feeReceiver");

    uint256 constant INITIAL_BALANCE = 100_000e6; // 100K USDC (6 decimals)

    function setUp() public {
        token = new MockERC20("Test USDC", "USDC", 6);
        bridge = new MockBridge(address(token));
        vault = new TrufVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(bridge)),
            operator,
            curator,
            "TrufVault Share",
            "tvUSDC"
        );

        // Fund users
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        token.mint(charlie, INITIAL_BALANCE);

        // Approve vault
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.prank(charlie);
        token.approve(address(vault), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_setsState() public view {
        assertEq(vault.operator(), operator);
        assertEq(address(vault.bridge()), address(bridge));
        assertEq(vault.curatorTNAddress(), curator);
        assertEq(vault.asset(), address(token));
        assertEq(vault.deployedOnTN(), 0);
        assertEq(vault.fee(), 0);
        assertEq(vault.feeRecipient(), address(0));
        assertEq(vault.pendingOperator(), address(0));
        assertEq(vault.highWaterMarkPPS(), 0);
    }

    function test_constructor_setsDecimalsOffset() public view {
        // USDC = 6 decimals → offset = 12
        assertEq(vault.DECIMALS_OFFSET(), 12);
        // ERC4626 decimals = asset decimals + offset = 6 + 12 = 18
        assertEq(vault.decimals(), 18);
    }

    function test_constructor_decimalsOffset18() public {
        // 18-decimal token → offset = 0
        MockERC20 token18 = new MockERC20("DAI", "DAI", 18);
        MockBridge bridge18 = new MockBridge(address(token18));
        TrufVault vault18 = new TrufVault(
            IERC20(address(token18)),
            ITrufNetworkBridge(address(bridge18)),
            operator, curator, "TrufVault DAI", "tvDAI"
        );
        assertEq(vault18.DECIMALS_OFFSET(), 0);
        assertEq(vault18.decimals(), 18);
    }

    function test_constructor_revertsBridgeAssetMismatch() public {
        MockERC20 wrongToken = new MockERC20("Wrong", "WRG", 18);
        MockBridge wrongBridge = new MockBridge(address(wrongToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                TrufVault.BridgeAssetMismatch.selector,
                address(wrongToken),
                address(token)
            )
        );
        new TrufVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(wrongBridge)),
            operator, curator, "V", "V"
        );
    }

    function test_constructor_bridgeMaxApproval() public view {
        uint256 allowance = token.allowance(address(vault), address(bridge));
        assertEq(allowance, type(uint256).max);
    }

    function test_constructor_revertsZeroBridge() public {
        vm.expectRevert(TrufVault.ZeroAddress.selector);
        new TrufVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(0)),
            operator, curator, "V", "V"
        );
    }

    function test_constructor_revertsZeroOperator() public {
        vm.expectRevert(TrufVault.ZeroAddress.selector);
        new TrufVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(bridge)),
            address(0), curator, "V", "V"
        );
    }

    function test_constructor_revertsZeroCurator() public {
        vm.expectRevert(TrufVault.ZeroAddress.selector);
        new TrufVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(bridge)),
            operator, address(0), "V", "V"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  DECIMALS OFFSET — INFLATION ATTACK PROTECTION
    // ═══════════════════════════════════════════════════════════════════════

    function test_decimalsOffset_preventsInflationAttack() public {
        // Classic inflation attack scenario for USDC (6 decimals):
        // 1. Attacker deposits 1 wei of USDC → gets shares
        // 2. Attacker donates large USDC directly to vault
        // 3. Victim deposits → gets 0 shares due to rounding
        //
        // With DECIMALS_OFFSET=12, the virtual offset prevents this.

        // Attacker deposits 1 wei
        token.mint(attacker, 1);
        vm.prank(attacker);
        token.approve(address(vault), type(uint256).max);
        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(1, attacker);
        assertTrue(attackerShares > 0, "Attacker should get shares");

        // Attacker donates 10K USDC directly to vault (the "donation" attack)
        token.mint(address(vault), 10_000e6);

        // Victim deposits 10K USDC
        vm.prank(alice);
        uint256 victimShares = vault.deposit(10_000e6, alice);

        // With offset, victim gets non-zero shares and doesn't lose to rounding
        assertTrue(victimShares > 0, "Victim must get shares (offset protects)");

        // Victim should get back approximately what they deposited
        uint256 victimAssets = vault.previewRedeem(victimShares);
        // Allow some rounding loss but victim shouldn't lose more than a tiny fraction
        assertGt(victimAssets, 9_999e6, "Victim should recover nearly all deposited assets");
    }

    function test_decimalsOffset_firstDepositCorrect() public {
        // With offset, first deposit of 1 USDC should work correctly
        vm.prank(alice);
        uint256 shares = vault.deposit(1e6, alice);

        // Shares should be 1e6 * 10^12 = 1e18 (due to offset)
        assertEq(shares, 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  DEPOSIT (ERC4626)
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_mintsShares() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // With offset: shares = 10_000e6 * 10^12 = 10_000e18
        assertEq(shares, 10_000e18);
        assertEq(vault.balanceOf(alice), 10_000e18);
        assertEq(vault.totalAssets(), depositAmount);
        assertEq(token.balanceOf(address(vault)), depositAmount);
    }

    function test_deposit_multipleUsers() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(bob);
        vault.deposit(5_000e6, bob);

        assertEq(vault.totalAssets(), 15_000e6);
        assertEq(vault.balanceOf(alice), 10_000e18);
        assertEq(vault.balanceOf(bob), 5_000e18);
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(operator);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(10_000e6, alice);
    }

    function test_deposit_initializesHWM() public {
        // First deposit creates shares. Next _accrueFee call (with fee active) initializes HWM.
        vm.prank(operator);
        vault.setFeeRecipient(feeReceiver);
        vm.prank(operator);
        vault.setFee(0.1e18);

        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // HWM not yet initialized (first _accrueFee during deposit saw supply=0 pre-mint)
        // A second deposit will trigger _accrueFee with supply > 0, initializing HWM
        vm.prank(bob);
        vault.deposit(1_000e6, bob);

        assertTrue(vault.highWaterMarkPPS() > 0, "HWM should be initialized");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  WITHDRAW (ERC4626)
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdraw_returnsAssets() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(alice);
        vault.withdraw(5_000e6, alice, alice);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 5_000e6);
        assertEq(vault.totalAssets(), 5_000e6);
    }

    function test_withdraw_revertsInsufficientIdle() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(operator);
        vault.depositToTN(8_000e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TrufVault.InsufficientIdle.selector, 5_000e6, 2_000e6));
        vault.withdraw(5_000e6, alice, alice);
    }

    function test_withdraw_revertsWhenPaused() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(operator);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(5_000e6, alice, alice);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  REDEEM
    // ═══════════════════════════════════════════════════════════════════════

    function test_redeem_returnsAssets() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares / 2, alice, alice);

        assertEq(assets, 5_000e6);
    }

    function test_redeem_revertsInsufficientIdle() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(operator);
        vault.depositToTN(8_000e6);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(shares, alice, alice);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  MINT (ERC4626)
    // ═══════════════════════════════════════════════════════════════════════

    function test_mint_depositsAssets() public {
        vm.prank(alice);
        uint256 assets = vault.mint(10_000e18, alice); // 10K shares (with offset)

        assertEq(assets, 10_000e6);
        assertEq(vault.balanceOf(alice), 10_000e18);
    }

    function test_mint_revertsWhenPaused() public {
        vm.prank(operator);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.mint(10_000e18, alice);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  maxWithdraw / maxRedeem OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════

    function test_maxWithdraw_capsToIdle() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // All idle → maxWithdraw = full assets
        assertEq(vault.maxWithdraw(alice), 10_000e6);

        // Bridge 80% → only 2K idle
        vm.prank(operator);
        vault.depositToTN(8_000e6);

        assertEq(vault.maxWithdraw(alice), 2_000e6);
    }

    function test_maxWithdraw_capsToOwnerBalance() public {
        vm.prank(alice);
        vault.deposit(5_000e6, alice);

        vm.prank(bob);
        vault.deposit(10_000e6, bob);

        // Idle = 15K, alice owns 5K worth → maxWithdraw = 5K (capped by ownership, not idle)
        assertEq(vault.maxWithdraw(alice), 5_000e6);
    }

    function test_maxRedeem_capsToIdle() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(operator);
        vault.depositToTN(8_000e6);

        uint256 maxShares = vault.maxRedeem(alice);
        uint256 maxAssets = vault.previewRedeem(maxShares);

        // Max redeemable assets should be close to idle (2K)
        assertLe(maxAssets, 2_000e6);
        assertGt(maxAssets, 1_999e6); // allow tiny rounding
    }

    function test_maxWithdraw_zeroForNonHolder() public view {
        assertEq(vault.maxWithdraw(attacker), 0);
    }

    function test_maxRedeem_zeroForNonHolder() public view {
        assertEq(vault.maxRedeem(attacker), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  depositToTN
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositToTN_bridgesFunds() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(operator);
        vault.depositToTN(8_000e6);

        assertEq(vault.deployedOnTN(), 8_000e6);
        assertEq(token.balanceOf(address(vault)), 2_000e6);
        assertEq(token.balanceOf(address(bridge)), 8_000e6);
        assertEq(bridge.lastDepositAmount(), 8_000e6);
        assertEq(bridge.lastDepositRecipient(), curator);
        assertEq(vault.totalAssets(), 10_000e6); // unchanged
    }

    function test_depositToTN_revertsNotOperator() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(attacker);
        vm.expectRevert(TrufVault.OnlyOperator.selector);
        vault.depositToTN(8_000e6);
    }

    function test_depositToTN_revertsZeroAmount() public {
        vm.prank(operator);
        vm.expectRevert(TrufVault.ZeroAmount.selector);
        vault.depositToTN(0);
    }

    function test_depositToTN_revertsInsufficientIdle() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TrufVault.InsufficientIdle.selector, 20_000e6, 10_000e6));
        vault.depositToTN(20_000e6);
    }

    function test_depositToTN_multipleBridges() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(operator);
        vault.depositToTN(3_000e6);
        vm.prank(operator);
        vault.depositToTN(4_000e6);

        assertEq(vault.deployedOnTN(), 7_000e6);
        assertEq(token.balanceOf(address(vault)), 3_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  claimFromTN
    // ═══════════════════════════════════════════════════════════════════════

    function test_claimFromTN_receivesFunds() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(8_000e6);

        bytes32[] memory proof = new bytes32[](0);
        ITrufNetworkBridge.Signature[] memory sigs = new ITrufNetworkBridge.Signature[](0);

        vm.prank(operator);
        vault.claimFromTN(5_000e6, bytes32(0), bytes32(0), proof, sigs);

        assertEq(vault.deployedOnTN(), 3_000e6);
        assertEq(token.balanceOf(address(vault)), 7_000e6);
        assertEq(vault.totalAssets(), 10_000e6);
    }

    function test_claimFromTN_revertsNotOperator() public {
        bytes32[] memory proof = new bytes32[](0);
        ITrufNetworkBridge.Signature[] memory sigs = new ITrufNetworkBridge.Signature[](0);

        vm.prank(attacker);
        vm.expectRevert(TrufVault.OnlyOperator.selector);
        vault.claimFromTN(1_000e6, bytes32(0), bytes32(0), proof, sigs);
    }

    function test_claimFromTN_revertsZeroAmount() public {
        bytes32[] memory proof = new bytes32[](0);
        ITrufNetworkBridge.Signature[] memory sigs = new ITrufNetworkBridge.Signature[](0);

        vm.prank(operator);
        vm.expectRevert(TrufVault.ZeroAmount.selector);
        vault.claimFromTN(0, bytes32(0), bytes32(0), proof, sigs);
    }

    function test_claimFromTN_revertsInsufficientDeployed() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(5_000e6);

        bytes32[] memory proof = new bytes32[](0);
        ITrufNetworkBridge.Signature[] memory sigs = new ITrufNetworkBridge.Signature[](0);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TrufVault.InsufficientDeployed.selector, 8_000e6, 5_000e6));
        vault.claimFromTN(8_000e6, bytes32(0), bytes32(0), proof, sigs);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  recordPnL + maxPnLDeltaBps
    // ═══════════════════════════════════════════════════════════════════════

    function test_recordPnL_positiveGain() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(8_000e6);

        // 5% gain on 8K deployed = 400 USDC (within 10% cap)
        vm.prank(operator);
        vault.recordPnL(400e6);

        assertEq(vault.deployedOnTN(), 8_400e6);
        assertEq(vault.totalAssets(), 10_400e6);
    }

    function test_recordPnL_negativeLoss() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(8_000e6);

        // 5% loss on 8K = 400 USDC
        vm.prank(operator);
        vault.recordPnL(-400e6);

        assertEq(vault.deployedOnTN(), 7_600e6);
        assertEq(vault.totalAssets(), 9_600e6);
    }

    function test_recordPnL_revertsExceedsMaxBps() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(8_000e6);

        // 15% gain = 1200 USDC → 1500 bps > 1000 bps max
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TrufVault.PnLDeltaExceedsMax.selector, 1500, 1000));
        vault.recordPnL(1_200e6);
    }

    function test_recordPnL_revertsExceedsMaxBpsNegative() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(8_000e6);

        // 15% loss = 1200 USDC → 1500 bps > 1000 bps max
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TrufVault.PnLDeltaExceedsMax.selector, 1500, 1000));
        vault.recordPnL(-1_200e6);
    }

    function test_recordPnL_exactlyAtMax() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(10_000e6);

        // Exactly 10% of 10K = 1000 USDC → 1000 bps = MAX_PNL_DELTA_BPS (should pass)
        vm.prank(operator);
        vault.recordPnL(1_000e6);

        assertEq(vault.deployedOnTN(), 11_000e6);
    }

    function test_recordPnL_revertsNonZeroWithNothingDeployed() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        // Don't deploy anything to TN

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TrufVault.PnLDeltaExceedsMax.selector, type(uint256).max, 1000));
        vault.recordPnL(100e6);
    }

    function test_recordPnL_zeroAllowed() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(5_000e6);

        // Zero PnL should always work
        vm.prank(operator);
        vault.recordPnL(0);

        assertEq(vault.deployedOnTN(), 5_000e6);
    }

    function test_recordPnL_revertsNotOperator() public {
        vm.prank(attacker);
        vm.expectRevert(TrufVault.OnlyOperator.selector);
        vault.recordPnL(1_000e6);
    }

    function test_recordPnL_sharePriceChanges() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(10_000e6);

        // 10% gain → totalAssets = 11K, shares = 10K*1e12 → price = 1.1
        vm.prank(operator);
        vault.recordPnL(1_000e6);

        // Bob deposits 11K → should get ~10K shares (11K / 1.1)
        vm.prank(bob);
        uint256 bobShares = vault.deposit(11_000e6, bob);
        uint256 aliceShares = vault.balanceOf(alice);

        // Both should have approximately equal shares
        assertApproxEqRel(bobShares, aliceShares, 0.01e18); // within 1%
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  TWO-STEP OPERATOR TRANSFER
    // ═══════════════════════════════════════════════════════════════════════

    function test_transferOperator_twoStep() public {
        address newOp = makeAddr("newOperator");

        // Step 1: current operator starts transfer
        vm.prank(operator);
        vault.transferOperator(newOp);

        assertEq(vault.pendingOperator(), newOp);
        assertEq(vault.operator(), operator); // still current operator

        // Step 2: new operator accepts
        vm.prank(newOp);
        vault.acceptOperator();

        assertEq(vault.operator(), newOp);
        assertEq(vault.pendingOperator(), address(0));
    }

    function test_transferOperator_oldOperatorCanStillActBeforeAccept() public {
        address newOp = makeAddr("newOperator");

        vm.prank(operator);
        vault.transferOperator(newOp);

        // Old operator can still act
        vm.prank(operator);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(operator);
        vault.unpause();
    }

    function test_acceptOperator_revertsWrongCaller() public {
        address newOp = makeAddr("newOperator");

        vm.prank(operator);
        vault.transferOperator(newOp);

        // Attacker tries to accept
        vm.prank(attacker);
        vm.expectRevert(TrufVault.OnlyPendingOperator.selector);
        vault.acceptOperator();
    }

    function test_acceptOperator_revertsNoPending() public {
        // No pending set → attacker can't accept
        vm.prank(attacker);
        vm.expectRevert(TrufVault.OnlyPendingOperator.selector);
        vault.acceptOperator();
    }

    function test_transferOperator_revertsZeroAddress() public {
        vm.prank(operator);
        vm.expectRevert(TrufVault.ZeroAddress.selector);
        vault.transferOperator(address(0));
    }

    function test_transferOperator_revertsNotOperator() public {
        vm.prank(attacker);
        vm.expectRevert(TrufVault.OnlyOperator.selector);
        vault.transferOperator(attacker);
    }

    function test_transferOperator_canOverwritePending() public {
        address newOp1 = makeAddr("newOp1");
        address newOp2 = makeAddr("newOp2");

        vm.prank(operator);
        vault.transferOperator(newOp1);

        // Change mind, set different pending
        vm.prank(operator);
        vault.transferOperator(newOp2);

        assertEq(vault.pendingOperator(), newOp2);

        // Old pending can't accept
        vm.prank(newOp1);
        vm.expectRevert(TrufVault.OnlyPendingOperator.selector);
        vault.acceptOperator();

        // New pending can accept
        vm.prank(newOp2);
        vault.acceptOperator();
        assertEq(vault.operator(), newOp2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  PERFORMANCE FEE
    // ═══════════════════════════════════════════════════════════════════════

    function test_setFee() public {
        // Must set feeRecipient first
        vm.prank(operator);
        vault.setFeeRecipient(feeReceiver);

        vm.prank(operator);
        vault.setFee(0.1e18); // 10%

        assertEq(vault.fee(), 0.1e18);
    }

    function test_setFee_revertsExceedsMax() public {
        vm.prank(operator);
        vault.setFeeRecipient(feeReceiver);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TrufVault.FeeExceedsMax.selector, 0.6e18, 0.5e18));
        vault.setFee(0.6e18); // 60% > 50% max
    }

    function test_setFee_revertsNoRecipient() public {
        // feeRecipient is zero
        vm.prank(operator);
        vm.expectRevert(TrufVault.ZeroFeeRecipient.selector);
        vault.setFee(0.1e18);
    }

    function test_setFee_zeroAllowedWithoutRecipient() public {
        // Setting fee to 0 with no recipient is fine
        vm.prank(operator);
        vault.setFee(0);
        assertEq(vault.fee(), 0);
    }

    function test_fee_accruesOnPnLGain() public {
        // Setup: 10% fee
        vm.prank(operator);
        vault.setFeeRecipient(feeReceiver);
        vm.prank(operator);
        vault.setFee(0.1e18);

        // Alice deposits 10K
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(10_000e6);

        uint256 feeReceiverSharesBefore = vault.balanceOf(feeReceiver);
        assertEq(feeReceiverSharesBefore, 0);

        // Record 10% gain (1K USDC)
        vm.prank(operator);
        vault.recordPnL(1_000e6);

        // Fee = 10% of 1K gain = 100 USDC worth of shares minted to feeReceiver
        uint256 feeReceiverSharesAfter = vault.balanceOf(feeReceiver);
        assertTrue(feeReceiverSharesAfter > 0, "Fee receiver should have shares");

        // feeReceiver's shares should be worth ~100 USDC
        uint256 feeValue = vault.previewRedeem(feeReceiverSharesAfter);
        assertApproxEqRel(feeValue, 100e6, 0.05e18); // within 5%
    }

    function test_fee_noAccrualOnLoss() public {
        vm.prank(operator);
        vault.setFeeRecipient(feeReceiver);
        vm.prank(operator);
        vault.setFee(0.1e18);

        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(10_000e6);

        // Record loss
        vm.prank(operator);
        vault.recordPnL(-500e6);

        // No fee shares minted on loss
        assertEq(vault.balanceOf(feeReceiver), 0);
    }

    function test_fee_noAccrualWhenZeroFee() public {
        // Fee is 0 (default)
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(10_000e6);

        vm.prank(operator);
        vault.recordPnL(500e6);

        // No fee receiver, no shares minted
        assertEq(vault.balanceOf(feeReceiver), 0);
    }

    function test_fee_noFeeOnRecoveryBelowHWM() public {
        // Setup: 10% fee
        vm.prank(operator);
        vault.setFeeRecipient(feeReceiver);
        vm.prank(operator);
        vault.setFee(0.1e18);

        // Alice deposits 10K, bridge to TN
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(10_000e6);

        // Record 5% gain → establishes HWM
        vm.prank(operator);
        vault.recordPnL(500e6);
        uint256 feeSharesAfterGain = vault.balanceOf(feeReceiver);
        assertTrue(feeSharesAfterGain > 0, "Should have fee shares from initial gain");

        // Record 10% loss → drops below HWM
        vm.prank(operator);
        vault.recordPnL(-1_000e6);
        // totalAssets now: 0 idle + 9500 deployed = 9500 (below original 10000)

        // Record 3% recovery → still below the HWM set after the 5% gain
        vm.prank(operator);
        vault.recordPnL(300e6);

        // No NEW fee shares should be minted — still underwater from the HWM
        uint256 feeSharesAfterRecovery = vault.balanceOf(feeReceiver);
        assertEq(feeSharesAfterRecovery, feeSharesAfterGain, "No fee on recovery below HWM");
    }

    function test_fee_feeOnlyAboveHWM() public {
        // Setup: 10% fee
        vm.prank(operator);
        vault.setFeeRecipient(feeReceiver);
        vm.prank(operator);
        vault.setFee(0.1e18);

        // Alice deposits 10K, bridge to TN
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(10_000e6);

        // Gain 5% → HWM set
        vm.prank(operator);
        vault.recordPnL(500e6);
        uint256 feeSharesFirst = vault.balanceOf(feeReceiver);

        // Loss 8% → underwater
        vm.prank(operator);
        vault.recordPnL(-800e6);
        // deployed now: 9700

        // Recover in two steps (each within 10% of current deployed)
        vm.prank(operator);
        vault.recordPnL(900e6); // 9.27% of 9700 → deployed = 10600
        // PPS now above old HWM → fee should accrue

        uint256 feeSharesSecond = vault.balanceOf(feeReceiver);
        // Should have MORE fee shares now (exceeded HWM)
        assertTrue(feeSharesSecond > feeSharesFirst, "Fee should accrue when exceeding HWM");
    }

    function test_fee_depositDoesNotTriggerFee() public {
        // Setup: 10% fee
        vm.prank(operator);
        vault.setFeeRecipient(feeReceiver);
        vm.prank(operator);
        vault.setFee(0.1e18);

        // Alice deposits 10K, bridge to TN
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(10_000e6);

        // Small gain to establish HWM
        vm.prank(operator);
        vault.recordPnL(100e6);
        uint256 feeSharesBefore = vault.balanceOf(feeReceiver);

        // Bob deposits 50K — large deposit, should NOT trigger additional fees
        // because per-share price doesn't change from a deposit
        vm.prank(bob);
        vault.deposit(50_000e6, bob);

        uint256 feeSharesAfter = vault.balanceOf(feeReceiver);
        assertEq(feeSharesAfter, feeSharesBefore, "Deposit must not trigger fee accrual");
    }

    function test_fee_lossThenFullRecoveryNoFee() public {
        // The critical test: loss → exact recovery → NO fee
        vm.prank(operator);
        vault.setFeeRecipient(feeReceiver);
        vm.prank(operator);
        vault.setFee(0.1e18);

        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(10_000e6);

        // Loss 5% (within 10% cap)
        vm.prank(operator);
        vault.recordPnL(-500e6);
        // deployed = 9500
        assertEq(vault.balanceOf(feeReceiver), 0, "No fee on loss");

        // Exact recovery: +500 on 9500 deployed = 5.26% (within cap)
        vm.prank(operator);
        vault.recordPnL(500e6);
        // deployed = 10000, back to original PPS → no fee (at HWM, not above it)
        assertEq(vault.balanceOf(feeReceiver), 0, "No fee on recovery to original level");
    }

    function test_fee_noRetroactiveChargeOnFeeActivation() public {
        // Gain happens while fee == 0, then fee is turned on.
        // The new fee must NOT retroactively charge on old gains.
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(10_000e6);

        // Gain 10% while fee is 0
        vm.prank(operator);
        vault.recordPnL(1_000e6);
        // Share price is now ~1.1, no fee was ever active

        // Now enable 10% fee
        vm.prank(operator);
        vault.setFeeRecipient(feeReceiver);
        vm.prank(operator);
        vault.setFee(0.1e18);

        // HWM should have been reset to current PPS when fee activated
        // So no retroactive fee on the 1000 gain that happened pre-fee

        // Small additional gain to trigger accrual check
        vm.prank(operator);
        vault.recordPnL(100e6);

        // Fee should only be on the 100 gain, not the 1000+100 total
        uint256 feeValue = vault.previewRedeem(vault.balanceOf(feeReceiver));
        // 10% of 100 = 10 USDC worth (not 10% of 1100 = 110)
        assertApproxEqRel(feeValue, 10e6, 0.1e18); // within 10% tolerance
    }

    function test_fee_noRetroactiveChargeOnRecipientActivation() public {
        // Scenario: fee is active, recipient exists, operator clears fee to 0,
        // then clears recipient, gains happen, then re-enables recipient + fee.
        // Old gains should not be charged retroactively.

        // Step 1: Set up active fee
        vm.prank(operator);
        vault.setFeeRecipient(feeReceiver);
        vm.prank(operator);
        vault.setFee(0.1e18);

        // Step 2: Deposit and deploy
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(10_000e6);

        // Step 3: Disable fee (must set fee to 0 before clearing recipient)
        vm.prank(operator);
        vault.setFee(0);
        vm.prank(operator);
        vault.setFeeRecipient(address(0));

        // Step 4: Gain happens while fee is effectively inactive
        vm.prank(operator);
        vault.recordPnL(1_000e6);

        // Step 5: Re-enable fee recipient (with fee still 0)
        vm.prank(operator);
        vault.setFeeRecipient(feeReceiver);
        // Re-enable fee — this triggers HWM reset since fee was 0 → non-zero
        vm.prank(operator);
        vault.setFee(0.1e18);

        // HWM should be reset to current PPS — old 1000 gain is not charged

        // Step 6: Small additional gain
        vm.prank(operator);
        vault.recordPnL(100e6);

        // Fee should only be on the 100 gain, not the 1000+100 total
        uint256 feeValue = vault.previewRedeem(vault.balanceOf(feeReceiver));
        assertApproxEqRel(feeValue, 10e6, 0.1e18); // ~10 USDC (10% of 100)
    }

    function test_setFeeRecipient_revertsZeroWithActiveFee() public {
        vm.prank(operator);
        vault.setFeeRecipient(feeReceiver);
        vm.prank(operator);
        vault.setFee(0.1e18);

        // Can't set recipient to zero while fee is active
        vm.prank(operator);
        vm.expectRevert(TrufVault.ZeroFeeRecipient.selector);
        vault.setFeeRecipient(address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SKIM (Token Recovery)
    // ═══════════════════════════════════════════════════════════════════════

    function test_skim_recoversWrongToken() public {
        MockERC20 wrongToken = new MockERC20("Wrong", "WRG", 18);
        wrongToken.mint(address(vault), 1_000e18);

        vm.prank(operator);
        vault.setSkimRecipient(operator);

        vault.skim(address(wrongToken));

        assertEq(wrongToken.balanceOf(operator), 1_000e18);
        assertEq(wrongToken.balanceOf(address(vault)), 0);
    }

    function test_skim_revertsNoRecipient() public {
        vm.expectRevert(TrufVault.NoSkimRecipient.selector);
        vault.skim(address(token));
    }

    function test_skim_doesNotTouchAccountedAssets() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(operator);
        vault.setSkimRecipient(operator);

        // Skim the vault asset — should not remove accounted idle balance
        vault.skim(address(token));
        assertEq(token.balanceOf(address(vault)), 10_000e6); // untouched
    }

    function test_skim_donatedVaultAssetBenefitsDepositors() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Someone accidentally sends 500 USDC directly to vault
        token.mint(address(vault), 500e6);

        // totalAssets() reads balanceOf + deployedOnTN, so the 500 is already "accounted"
        // This means donations increase share value (benefit depositors) — correct behavior
        assertEq(vault.totalAssets(), 10_500e6);

        vm.prank(operator);
        vault.setSkimRecipient(operator);

        // Skim sees no excess for vault asset (all accounted in totalAssets)
        vault.skim(address(token));
        assertEq(token.balanceOf(address(vault)), 10_500e6); // untouched

        // The 500 donation benefits Alice when she redeems
        uint256 aliceShares = vault.maxRedeem(alice);
        vm.prank(alice);
        uint256 aliceAssets = vault.redeem(aliceShares, alice, alice);
        assertApproxEqAbs(aliceAssets, 10_500e6, 1); // gets donation too
    }

    function test_skim_anyoneCanCall() public {
        MockERC20 wrongToken = new MockERC20("Wrong", "WRG", 18);
        wrongToken.mint(address(vault), 1_000e18);

        vm.prank(operator);
        vault.setSkimRecipient(operator);

        // Anyone can trigger skim — tokens go to designated recipient
        vm.prank(attacker);
        vault.skim(address(wrongToken));

        assertEq(wrongToken.balanceOf(operator), 1_000e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ADMIN: Curator, Pause
    // ═══════════════════════════════════════════════════════════════════════

    function test_updateCurator() public {
        address newCurator = makeAddr("newCurator");

        vm.prank(operator);
        vault.updateCurator(newCurator);

        assertEq(vault.curatorTNAddress(), newCurator);
    }

    function test_updateCurator_revertsZeroAddress() public {
        vm.prank(operator);
        vm.expectRevert(TrufVault.ZeroAddress.selector);
        vault.updateCurator(address(0));
    }

    function test_pause_unpause() public {
        vm.prank(operator);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(operator);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_pause_revertsNotOperator() public {
        vm.prank(attacker);
        vm.expectRevert(TrufVault.OnlyOperator.selector);
        vault.pause();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function test_idleBalance() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        assertEq(vault.idleBalance(), 10_000e6);

        vm.prank(operator);
        vault.depositToTN(6_000e6);

        assertEq(vault.idleBalance(), 4_000e6);
    }

    function test_reserveRatioBps() public {
        assertEq(vault.reserveRatioBps(), 10000); // empty vault

        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        assertEq(vault.reserveRatioBps(), 10000); // all idle

        vm.prank(operator);
        vault.depositToTN(8_000e6);
        assertEq(vault.reserveRatioBps(), 2000); // 20% idle
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECURITY: No Arbitrary Transfers
    // ═══════════════════════════════════════════════════════════════════════

    function test_noArbitraryTransfer_operatorCannotSteal() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        assertEq(token.balanceOf(address(vault)), 10_000e6);

        vm.prank(operator);
        vault.depositToTN(5_000e6);
        assertEq(token.balanceOf(address(bridge)), 5_000e6);
        assertEq(bridge.lastDepositRecipient(), curator);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  FULL LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════

    function test_fullLifecycle() public {
        // Setup 10% fee
        vm.prank(operator);
        vault.setFeeRecipient(feeReceiver);
        vm.prank(operator);
        vault.setFee(0.1e18);

        // 1. Alice deposits 10K
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        assertEq(vault.totalAssets(), 10_000e6);

        // 2. Bob deposits 5K
        vm.prank(bob);
        vault.deposit(5_000e6, bob);
        assertEq(vault.totalAssets(), 15_000e6);

        // 3. Operator bridges 80% to TN
        vm.prank(operator);
        vault.depositToTN(12_000e6);
        assertEq(vault.idleBalance(), 3_000e6);
        assertEq(vault.deployedOnTN(), 12_000e6);

        // 4. Curator makes 10% gain = 1200 profit on 12K deployed
        vm.prank(operator);
        vault.recordPnL(1_200e6);
        // totalAssets = 3000 idle + 13200 deployed = 16200
        assertEq(vault.totalAssets(), 16_200e6);

        // Fee receiver got shares for 10% of 1200 = 120 USDC worth
        assertTrue(vault.balanceOf(feeReceiver) > 0);

        // 5. Operator claims ALL back from TN
        bytes32[] memory proof = new bytes32[](0);
        ITrufNetworkBridge.Signature[] memory sigs = new ITrufNetworkBridge.Signature[](0);
        token.mint(address(bridge), 13_200e6); // fund bridge escrow

        vm.prank(operator);
        vault.claimFromTN(13_200e6, bytes32(0), bytes32(0), proof, sigs);
        assertEq(vault.deployedOnTN(), 0);

        // 6. Alice redeems — gets proportional share of gains minus fees
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceAssets = vault.redeem(aliceShares, alice, alice);

        // Alice had 2/3 of original deposits, should get ~2/3 of (15K + 1200 - fees)
        assertGt(aliceAssets, 10_000e6); // more than deposited (gained)

        // 7. Bob redeems
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 bobAssets = vault.redeem(bobShares, bob, bob);
        assertGt(bobAssets, 5_000e6); // more than deposited

        // 8. Fee receiver redeems
        uint256 feeShares = vault.balanceOf(feeReceiver);
        if (feeShares > 0) {
            vm.prank(feeReceiver);
            vault.redeem(feeShares, feeReceiver, feeReceiver);
        }

        // 9. Vault should be nearly empty (tiny rounding dust at most)
        assertLe(vault.totalSupply(), 1); // allow 1 wei dust
    }

    function test_fullLifecycle_lossScenario() public {
        // 1. Alice and Bob deposit
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(bob);
        vault.deposit(5_000e6, bob);

        // 2. Bridge to TN
        vm.prank(operator);
        vault.depositToTN(12_000e6);

        // 3. Curator loses 10% = 1200 on deployed
        vm.prank(operator);
        vault.recordPnL(-1_200e6);
        assertEq(vault.totalAssets(), 13_800e6); // 3K idle + 10800 deployed

        // 4. Claim back
        bytes32[] memory proof = new bytes32[](0);
        ITrufNetworkBridge.Signature[] memory sigs = new ITrufNetworkBridge.Signature[](0);
        token.mint(address(bridge), 10_800e6);

        vm.prank(operator);
        vault.claimFromTN(10_800e6, bytes32(0), bytes32(0), proof, sigs);

        // 5. Both users take a proportional loss
        // Use maxRedeem to account for rounding with DECIMALS_OFFSET
        uint256 aliceRedeemable = vault.maxRedeem(alice);
        vm.prank(alice);
        uint256 aliceAssets = vault.redeem(aliceRedeemable, alice, alice);
        assertLt(aliceAssets, 10_000e6); // lost money

        uint256 bobRedeemable = vault.maxRedeem(bob);
        vm.prank(bob);
        uint256 bobAssets = vault.redeem(bobRedeemable, bob, bob);
        assertLt(bobAssets, 5_000e6); // lost money
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ERC20Permit
    // ═══════════════════════════════════════════════════════════════════════

    function test_permit_works() public {
        // Verify permit domain separator exists (ERC20Permit is functional)
        bytes32 domainSeparator = vault.DOMAIN_SEPARATOR();
        assertTrue(domainSeparator != bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function testFuzz_deposit_withdraw(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, INITIAL_BALANCE);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        // Alice should get back within 1 wei of what she deposited
        assertApproxEqAbs(token.balanceOf(alice), INITIAL_BALANCE, 1);
    }

    function testFuzz_depositToTN_bounded(uint256 depositAmount, uint256 bridgePercent) public {
        depositAmount = bound(depositAmount, 1e6, INITIAL_BALANCE);
        bridgePercent = bound(bridgePercent, 1, 100);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        uint256 bridgeAmount = (depositAmount * bridgePercent) / 100;
        if (bridgeAmount == 0) bridgeAmount = 1;

        vm.prank(operator);
        vault.depositToTN(bridgeAmount);

        assertEq(vault.totalAssets(), depositAmount);
        assertEq(vault.deployedOnTN(), bridgeAmount);
    }

    function testFuzz_maxWithdraw_neverExceedsIdle(uint256 depositAmount, uint256 bridgePercent) public {
        depositAmount = bound(depositAmount, 1e6, INITIAL_BALANCE);
        bridgePercent = bound(bridgePercent, 0, 100);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        if (bridgePercent > 0) {
            uint256 bridgeAmount = (depositAmount * bridgePercent) / 100;
            if (bridgeAmount > 0) {
                vm.prank(operator);
                vault.depositToTN(bridgeAmount);
            }
        }

        uint256 idle = token.balanceOf(address(vault));
        uint256 maxW = vault.maxWithdraw(alice);
        assertLe(maxW, idle, "maxWithdraw must never exceed idle");
    }

    function testFuzz_pnlDeltaWithinBounds(uint256 deployed, uint256 deltaPct) public {
        deployed = bound(deployed, 1e6, INITIAL_BALANCE);
        deltaPct = bound(deltaPct, 1, 10); // 1-10%

        vm.prank(alice);
        vault.deposit(deployed, alice);
        vm.prank(operator);
        vault.depositToTN(deployed);

        int256 delta = int256((deployed * deltaPct) / 100);

        vm.prank(operator);
        vault.recordPnL(delta); // should not revert

        assertEq(vault.deployedOnTN(), deployed + uint256(delta));
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  FACTORY TESTS
// ═══════════════════════════════════════════════════════════════════════════

contract TrufVaultFactoryTest is Test {
    TrufVaultFactory public factory;
    MockERC20 public token;
    MockBridge public bridge;

    address public operator = makeAddr("operator");
    address public curator = makeAddr("curator");

    function setUp() public {
        token = new MockERC20("Test USDC", "USDC", 6);
        bridge = new MockBridge(address(token));
        factory = new TrufVaultFactory();
    }

    function test_createVault() public {
        address vaultAddr = factory.createVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(bridge)),
            operator,
            curator,
            "TrufVault USDC",
            "tvUSDC",
            bytes32(uint256(1))
        );

        assertTrue(factory.isVault(vaultAddr));
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaults(0), vaultAddr);

        TrufVault v = TrufVault(vaultAddr);
        assertEq(v.operator(), operator);
        assertEq(v.curatorTNAddress(), curator);
        assertEq(v.asset(), address(token));
    }

    function test_createVault_multipleVaults() public {
        address v1 = factory.createVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(bridge)),
            operator, curator, "Vault 1", "tv1", bytes32(uint256(1))
        );

        MockERC20 token2 = new MockERC20("DAI", "DAI", 18);
        MockBridge bridge2 = new MockBridge(address(token2));

        address v2 = factory.createVault(
            IERC20(address(token2)),
            ITrufNetworkBridge(address(bridge2)),
            operator, curator, "Vault 2", "tv2", bytes32(uint256(2))
        );

        assertTrue(factory.isVault(v1));
        assertTrue(factory.isVault(v2));
        assertFalse(factory.isVault(address(this))); // random address
        assertEq(factory.vaultCount(), 2);
    }

    function test_createVault_deterministicAddress() public {
        bytes32 salt = bytes32(uint256(42));

        address v1 = factory.createVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(bridge)),
            operator, curator, "V1", "tv1", salt
        );

        // Same salt + same params from same factory → would revert (CREATE2 collision)
        // Different salt → different address
        address v2 = factory.createVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(bridge)),
            operator, curator, "V2", "tv2", bytes32(uint256(43))
        );

        assertTrue(v1 != v2);
    }

    function test_createVault_revertsZeroAsset() public {
        vm.expectRevert(TrufVaultFactory.ZeroAddress.selector);
        factory.createVault(
            IERC20(address(0)),
            ITrufNetworkBridge(address(bridge)),
            operator, curator, "V", "V", bytes32(0)
        );
    }

    function test_createVault_vaultIsFunctional() public {
        address vaultAddr = factory.createVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(bridge)),
            operator, curator, "TrufVault USDC", "tvUSDC", bytes32(uint256(1))
        );

        TrufVault v = TrufVault(vaultAddr);

        // Fund and deposit
        address user = makeAddr("user");
        token.mint(user, 10_000e6);

        vm.prank(user);
        token.approve(vaultAddr, type(uint256).max);
        vm.prank(user);
        uint256 shares = v.deposit(10_000e6, user);

        assertTrue(shares > 0);
        assertEq(v.totalAssets(), 10_000e6);
    }
}
