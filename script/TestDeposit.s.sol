// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TrufVault} from "../src/TrufVault.sol";

/// @notice Test deposit flow on Hoodi: mint TT2 → approve → deposit → check shares.
contract TestDeposit is Script {
    address constant VAULT = 0x349E34cf714178C1eFe87C2164d58a7184C23F30;
    address constant TT2 = 0x263CE78Fef26600e4e428CEBC91C2a52484B4FBF;

    function run() external {
        address deployer = msg.sender;
        TrufVault vault = TrufVault(VAULT);
        IERC20 tt2 = IERC20(TT2);

        console2.log("Deployer:", deployer);
        console2.log("TT2 balance before:", tt2.balanceOf(deployer));

        vm.startBroadcast();

        // Step 1: Try to mint 100 TT2 (if mint is public)
        (bool mintOk,) = TT2.call(abi.encodeWithSignature("mint(address,uint256)", deployer, 100e18));
        console2.log("Mint success:", mintOk);

        uint256 balance = tt2.balanceOf(deployer);
        console2.log("TT2 balance after mint:", balance);

        if (balance > 0) {
            // Step 2: Approve vault
            uint256 depositAmount = balance > 10e18 ? 10e18 : balance;
            tt2.approve(VAULT, depositAmount);
            console2.log("Approved vault for:", depositAmount);

            // Step 3: Deposit
            uint256 shares = vault.deposit(depositAmount, deployer);
            console2.log("Shares received:", shares);
            console2.log("Vault totalAssets:", vault.totalAssets());
            console2.log("Vault share balance:", vault.balanceOf(deployer));
        } else {
            console2.log("No TT2 balance - need to get TT2 from faucet or TN team");
        }

        vm.stopBroadcast();
    }
}
