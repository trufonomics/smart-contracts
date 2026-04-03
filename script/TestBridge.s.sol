// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TrufVault} from "../src/TrufVault.sol";

/// @notice Test bridge flow: depositToTN (vault → bridge → TN).
contract TestBridge is Script {
    address constant VAULT = 0x349E34cf714178C1eFe87C2164d58a7184C23F30;
    address constant TT2 = 0x263CE78Fef26600e4e428CEBC91C2a52484B4FBF;
    address constant BRIDGE = 0x878D6aaeB6e746033f50B8dC268d54B4631554E7;

    function run() external {
        TrufVault vault = TrufVault(VAULT);
        IERC20 tt2 = IERC20(TT2);

        console2.log("=== Pre-Bridge State ===");
        console2.log("Vault idle balance:", vault.idleBalance());
        console2.log("Vault deployedOnTN:", vault.deployedOnTN());
        console2.log("Vault totalAssets:", vault.totalAssets());
        console2.log("Bridge TT2 balance:", tt2.balanceOf(BRIDGE));

        vm.startBroadcast();

        // Bridge 5 TT2 to TN (half of the 10 deposited)
        uint256 bridgeAmount = 5e18;
        vault.depositToTN(bridgeAmount);

        vm.stopBroadcast();

        console2.log("=== Post-Bridge State ===");
        console2.log("Vault idle balance:", vault.idleBalance());
        console2.log("Vault deployedOnTN:", vault.deployedOnTN());
        console2.log("Vault totalAssets:", vault.totalAssets());
        console2.log("Bridge TT2 balance:", tt2.balanceOf(BRIDGE));
    }
}
