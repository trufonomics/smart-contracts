// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TrufVault} from "../src/TrufVault.sol";
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
    address public attacker = makeAddr("attacker");

    uint256 constant INITIAL_BALANCE = 100_000e6; // 100K USDC (6 decimals)

    function setUp() public {
        token = new MockERC20("Test USDC", "USDC", 6);
        bridge = new MockBridge(address(token));
        vault = new TrufVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(bridge)),
            operator,
            curator
        );

        // Fund users
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);

        // Approve vault
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    function test_constructor_setsState() public view {
        assertEq(vault.operator(), operator);
        assertEq(address(vault.bridge()), address(bridge));
        assertEq(vault.curatorTNAddress(), curator);
        assertEq(vault.asset(), address(token));
        assertEq(vault.deployedOnTN(), 0);
    }

    function test_constructor_revertsZeroBridge() public {
        vm.expectRevert(TrufVault.ZeroAddress.selector);
        new TrufVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(0)),
            operator,
            curator
        );
    }

    function test_constructor_revertsZeroOperator() public {
        vm.expectRevert(TrufVault.ZeroAddress.selector);
        new TrufVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(bridge)),
            address(0),
            curator
        );
    }

    function test_constructor_revertsZeroCurator() public {
        vm.expectRevert(TrufVault.ZeroAddress.selector);
        new TrufVault(
            IERC20(address(token)),
            ITrufNetworkBridge(address(bridge)),
            operator,
            address(0)
        );
    }

    // ─── Deposit (ERC4626) ───────────────────────────────────────────────

    function test_deposit_mintsShares() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        assertEq(shares, depositAmount); // 1:1 initially
        assertEq(vault.balanceOf(alice), depositAmount);
        assertEq(vault.totalAssets(), depositAmount);
        assertEq(token.balanceOf(address(vault)), depositAmount);
    }

    function test_deposit_multipleUsers() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(bob);
        vault.deposit(5_000e6, bob);

        assertEq(vault.totalAssets(), 15_000e6);
        assertEq(vault.balanceOf(alice), 10_000e6);
        assertEq(vault.balanceOf(bob), 5_000e6);
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(operator);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(10_000e6, alice);
    }

    // ─── Withdraw (ERC4626) ──────────────────────────────────────────────

    function test_withdraw_returnsAssets() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(alice);
        vault.withdraw(5_000e6, alice, alice);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 5_000e6);
        assertEq(vault.balanceOf(alice), 5_000e6);
        assertEq(vault.totalAssets(), 5_000e6);
    }

    function test_withdraw_revertsInsufficientIdle() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Operator bridges 80% to TN
        vm.prank(operator);
        vault.depositToTN(8_000e6);

        // Alice tries to withdraw more than idle (2000)
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

    // ─── Redeem ──────────────────────────────────────────────────────────

    function test_redeem_returnsAssets() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(alice);
        uint256 assets = vault.redeem(5_000e6, alice, alice);

        assertEq(assets, 5_000e6);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 5_000e6);
    }

    function test_redeem_revertsInsufficientIdle() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(operator);
        vault.depositToTN(8_000e6);

        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(5_000e6, alice, alice);
    }

    // ─── Mint (ERC4626) ──────────────────────────────────────────────────

    function test_mint_depositsAssets() public {
        vm.prank(alice);
        uint256 assets = vault.mint(10_000e6, alice);

        assertEq(assets, 10_000e6);
        assertEq(vault.balanceOf(alice), 10_000e6);
    }

    function test_mint_revertsWhenPaused() public {
        vm.prank(operator);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.mint(10_000e6, alice);
    }

    // ─── depositToTN ─────────────────────────────────────────────────────

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
        // totalAssets unchanged (idle + deployed)
        assertEq(vault.totalAssets(), 10_000e6);
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

    // ─── claimFromTN ─────────────────────────────────────────────────────

    function test_claimFromTN_receivesFunds() public {
        // Setup: deposit and bridge
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(8_000e6);

        // Claim back 5000
        bytes32[] memory proof = new bytes32[](0);
        ITrufNetworkBridge.Signature[] memory sigs = new ITrufNetworkBridge.Signature[](0);

        vm.prank(operator);
        vault.claimFromTN(5_000e6, bytes32(0), bytes32(0), proof, sigs);

        assertEq(vault.deployedOnTN(), 3_000e6);
        assertEq(token.balanceOf(address(vault)), 7_000e6); // 2000 idle + 5000 claimed
        assertEq(vault.totalAssets(), 10_000e6); // unchanged
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

    // ─── recordPnL ───────────────────────────────────────────────────────

    function test_recordPnL_positiveGain() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(8_000e6);

        // Curator made 1000 USDC profit
        vm.prank(operator);
        vault.recordPnL(1_000e6);

        assertEq(vault.deployedOnTN(), 9_000e6);
        assertEq(vault.totalAssets(), 11_000e6); // 2000 idle + 9000 deployed
    }

    function test_recordPnL_negativeLoss() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(8_000e6);

        // Curator lost 2000
        vm.prank(operator);
        vault.recordPnL(-2_000e6);

        assertEq(vault.deployedOnTN(), 6_000e6);
        assertEq(vault.totalAssets(), 8_000e6);
    }

    function test_recordPnL_lossExceedsDeployed() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(5_000e6);

        // Loss larger than deployed — floors at 0
        vm.prank(operator);
        vault.recordPnL(-10_000e6);

        assertEq(vault.deployedOnTN(), 0);
        assertEq(vault.totalAssets(), 5_000e6); // only idle remains
    }

    function test_recordPnL_revertsNotOperator() public {
        vm.prank(attacker);
        vm.expectRevert(TrufVault.OnlyOperator.selector);
        vault.recordPnL(1_000e6);
    }

    function test_recordPnL_sharePriceChanges() public {
        // Alice deposits 10K, gets 10K shares
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(operator);
        vault.depositToTN(8_000e6);

        // Curator profits 2K → totalAssets = 12K, shares = 10K → price = 1.2
        vm.prank(operator);
        vault.recordPnL(2_000e6);

        // Bob deposits 12K → should get 10K shares (12K / 1.2)
        vm.prank(bob);
        uint256 bobShares = vault.deposit(12_000e6, bob);
        assertEq(bobShares, 10_000e6);

        // Both have 10K shares, total assets = 24K → each worth 12K
        assertEq(vault.totalAssets(), 24_000e6);
    }

    // ─── Admin Functions ─────────────────────────────────────────────────

    function test_transferOperator() public {
        address newOp = makeAddr("newOperator");

        vm.prank(operator);
        vault.transferOperator(newOp);

        assertEq(vault.operator(), newOp);

        // Old operator can no longer act
        vm.prank(operator);
        vm.expectRevert(TrufVault.OnlyOperator.selector);
        vault.pause();

        // New operator works
        vm.prank(newOp);
        vault.pause();
        assertTrue(vault.paused());
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

    // ─── Pause / Unpause ─────────────────────────────────────────────────

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

    // ─── View Functions ──────────────────────────────────────────────────

    function test_idleBalance() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        assertEq(vault.idleBalance(), 10_000e6);

        vm.prank(operator);
        vault.depositToTN(6_000e6);

        assertEq(vault.idleBalance(), 4_000e6);
    }

    function test_reserveRatioBps() public {
        // Empty vault = 100%
        assertEq(vault.reserveRatioBps(), 10000);

        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        assertEq(vault.reserveRatioBps(), 10000); // all idle

        vm.prank(operator);
        vault.depositToTN(8_000e6);
        assertEq(vault.reserveRatioBps(), 2000); // 20% idle
    }

    // ─── Security: No Arbitrary Transfers ────────────────────────────────

    function test_noArbitraryTransfer_operatorCannotSteal() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Operator has no function to send tokens to arbitrary address
        // Only depositToTN (goes to bridge) and claimFromTN (comes from bridge)
        // There is literally no code path to drain funds elsewhere

        // Verify: vault holds the tokens
        assertEq(token.balanceOf(address(vault)), 10_000e6);

        // Verify: operator can only bridge to TN
        vm.prank(operator);
        vault.depositToTN(5_000e6);
        assertEq(token.balanceOf(address(bridge)), 5_000e6);
        assertEq(bridge.lastDepositRecipient(), curator); // goes to curator, not operator
    }

    // ─── Full Lifecycle ──────────────────────────────────────────────────

    function test_fullLifecycle() public {
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
        assertEq(vault.reserveRatioBps(), 2000);

        // 4. Curator makes 3K profit (20% return)
        vm.prank(operator);
        vault.recordPnL(3_000e6);
        assertEq(vault.totalAssets(), 18_000e6);

        // 5. Operator claims ALL deployed back from TN (15K including 3K profit)
        bytes32[] memory proof = new bytes32[](0);
        ITrufNetworkBridge.Signature[] memory sigs = new ITrufNetworkBridge.Signature[](0);

        // Fund bridge escrow for withdrawal simulation (deployed = 15K after PnL)
        token.mint(address(bridge), 15_000e6);

        vm.prank(operator);
        vault.claimFromTN(15_000e6, bytes32(0), bytes32(0), proof, sigs);
        assertEq(vault.idleBalance(), 18_000e6); // 3K idle + 15K claimed
        assertEq(vault.deployedOnTN(), 0);

        // 6. Alice redeems all shares — gets proportional (including profit)
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceAssets = vault.redeem(aliceShares, alice, alice);
        // Alice had 10K/15K = 66.67% of shares → 66.67% of 18K ≈ 12K (±1 wei rounding)
        assertApproxEqAbs(aliceAssets, 12_000e6, 1);

        // 7. Bob redeems all shares
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 bobAssets = vault.redeem(bobShares, bob, bob);
        // Bob had 5K/15K = 33.33% of shares → 33.33% of 18K ≈ 6K (±1 wei rounding)
        assertApproxEqAbs(bobAssets, 6_000e6, 1);

        // 8. Vault is empty
        assertEq(vault.totalSupply(), 0);
    }

    // ─── Fuzz Tests ──────────────────────────────────────────────────────

    function testFuzz_deposit_withdraw(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, INITIAL_BALANCE);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(vault.totalSupply(), 0);
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
}
