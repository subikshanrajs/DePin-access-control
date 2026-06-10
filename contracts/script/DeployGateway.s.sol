// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AccessGateway} from "../src/AccessGateway.sol";
import {SessionRegistry} from "../src/SessionRegistry.sol";

/// @title DeployGateway
/// @notice Foundry deployment script for the AccessGateway protocol.
///         Supports both local Anvil, Arbitrum Sepolia testnet, and Arbitrum One mainnet.
///
/// @dev Usage:
///   Local:    forge script script/DeployGateway.s.sol --rpc-url localhost --broadcast
///   Testnet:  forge script script/DeployGateway.s.sol --rpc-url arbitrum_sepolia --broadcast --verify
///   Mainnet:  forge script script/DeployGateway.s.sol --rpc-url arbitrum --broadcast --verify
contract DeployGateway is Script {

    // =========================================================================
    //                         DEPLOYMENT CONFIGURATION
    // =========================================================================

    /// @dev Override these via environment variables for different networks
    struct DeployConfig {
        address owner;          // Protocol owner / multisig
        address payable treasury; // ETH withdrawal destination
    }

    function _loadConfig(address defaultOwner) internal view returns (DeployConfig memory config) {
        config.owner = defaultOwner;
        config.treasury = payable(defaultOwner);

        if (vm.envExists("DEPLOY_OWNER")) {
            config.owner = vm.envAddress("DEPLOY_OWNER");
        }
        if (vm.envExists("DEPLOY_TREASURY")) {
            config.treasury = payable(vm.envAddress("DEPLOY_TREASURY"));
        }
    }

    // =========================================================================
    //                              RUN
    // =========================================================================

    function run() public {
        uint256 deployerPrivKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivKey);
        DeployConfig memory config = _loadConfig(deployerAddress);

        console2.log("=== DePIN Access Protocol Deployment ===");
        console2.log("Network:  ", block.chainid);
        console2.log("Deployer: ", msg.sender);
        console2.log("Owner:    ", config.owner);
        console2.log("Treasury: ", config.treasury);
        console2.log("Block:    ", block.number);

        vm.startBroadcast(deployerPrivKey);

        // 1. Deploy SessionRegistry (pure data store)
        SessionRegistry registry = new SessionRegistry(config.owner);
        console2.log("\n[1/2] SessionRegistry deployed at:", address(registry));

        // 2. Deploy AccessGateway (logic layer)
        AccessGateway gateway = new AccessGateway(
            address(registry),
            config.treasury,
            config.owner
        );
        console2.log("[2/2] AccessGateway deployed at:  ", address(gateway));

        // 3. Wire: authorize gateway to write sessions
        registry.setGateway(address(gateway));
        console2.log("\n[OK] Gateway authorized in SessionRegistry");

        vm.stopBroadcast();

        // =====================================================================
        //                          VERIFICATION OUTPUT
        // =====================================================================
        console2.log("\n=== Deployment Summary ===");
        console2.log("SessionRegistry:", address(registry));
        console2.log("AccessGateway:  ", address(gateway));
        console2.log("Owner:          ", config.owner);
        console2.log("Treasury:       ", config.treasury);
        console2.log("\n=== Verify Commands ===");
        console2.log(string(abi.encodePacked(
            "forge verify-contract ", vm.toString(address(registry)), " ",
            "src/SessionRegistry.sol:SessionRegistry ", "--chain ", vm.toString(block.chainid)
        )));
        console2.log(string(abi.encodePacked(
            "forge verify-contract ", vm.toString(address(gateway)), " ",
            "src/AccessGateway.sol:AccessGateway ", "--chain ", vm.toString(block.chainid)
        )));

        // Write addresses to JSON for downstream use (frontend, worker)
        string memory json = _buildDeployJson(address(registry), address(gateway), config);
        vm.writeFile("./deployments/latest.json", json);
        console2.log(unicode"\n[✓] Deployment addresses saved to ./deployments/latest.json");
    }

    // =========================================================================
    //                         INTERACTION SCRIPTS
    // =========================================================================

    /// @notice Convenience script to add a custom tier post-deployment
    /// @dev    forge script script/DeployGateway.s.sol:AddTier --sig "run(address,uint256,uint256,string)"
    function addTier(
        address payable gatewayAddr,
        uint256 durationSeconds,
        uint256 priceWei,
        string calldata label
    ) public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        AccessGateway(gatewayAddr).addTier(durationSeconds, priceWei, label);
        vm.stopBroadcast();
        console2.log(string(abi.encodePacked("Tier added: ", label, " ", vm.toString(durationSeconds), " sec @ ", vm.toString(priceWei), " wei")));
    }

    /// @notice Emergency pause
    function pause(address payable gatewayAddr) public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        AccessGateway(gatewayAddr).togglePause();
        vm.stopBroadcast();
        console2.log("Emergency pause toggled on:", gatewayAddr);
    }

    /// @notice Withdraw accumulated ETH to treasury
    function withdrawRevenue(address payable gatewayAddr) public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        AccessGateway(gatewayAddr).withdraw();
        vm.stopBroadcast();
        console2.log("Withdrawal executed from:", gatewayAddr);
    }

    // =========================================================================
    //                              HELPERS
    // =========================================================================

    function _buildDeployJson(
        address registry,
        address gateway,
        DeployConfig memory config
    ) internal view returns (string memory) {
        return string(
            abi.encodePacked(
                '{"chainId":', vm.toString(block.chainid),
                ',"blockNumber":', vm.toString(block.number),
                ',"SessionRegistry":"', vm.toString(registry),
                '","AccessGateway":"', vm.toString(gateway),
                '","owner":"', vm.toString(config.owner),
                '","treasury":"', vm.toString(config.treasury),
                '"}'
            )
        );
    }
}
