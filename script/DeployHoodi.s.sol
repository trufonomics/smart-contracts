// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TrufVault} from "../src/TrufVault.sol";
import {ITrufNetworkBridge} from "../src/interfaces/ITrufNetworkBridge.sol";

/// @notice Deploy TrufVault to Hoodi testnet.
/// @dev Usage:
///   forge script script/DeployHoodi.s.sol:DeployHoodi \
///     --rpc-url https://rpc.hoodi.ethpandaops.io \
///     --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY
contract DeployHoodi is Script {
    // Hoodi testnet addresses (confirmed Mar 13 2026)
    address constant TT2_TOKEN = 0x263CE78Fef26600e4e428CEBC91C2a52484B4FBF;
    address constant TRUF_BRIDGE = 0x878D6aaeB6e746033f50B8dC268d54B4631554E7;

    function run() external {
        // Deployer = operator for testnet (will be Gnosis Safe on mainnet)
        address deployer = msg.sender;

        // Curator TN address — the bot wallet that trades on TN prediction markets
        // TODO: Replace with actual curator wallet before deployment
        address curatorTN = deployer;

        vm.startBroadcast();

        TrufVault vault = new TrufVault(
            IERC20(TT2_TOKEN),
            ITrufNetworkBridge(TRUF_BRIDGE),
            deployer, // operator (EOA for testnet)
            curatorTN, // curator TN wallet
            "TrufVault Share",
            "tvUSDC"
        );

        console2.log("TrufVault deployed at:", address(vault));
        console2.log("  asset (TT2):", TT2_TOKEN);
        console2.log("  bridge:", TRUF_BRIDGE);
        console2.log("  operator:", deployer);
        console2.log("  curator:", curatorTN);

        vm.stopBroadcast();
    }
}
