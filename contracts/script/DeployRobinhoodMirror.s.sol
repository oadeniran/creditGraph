// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AccessController} from "../src/governance/AccessController.sol";
import {RobinhoodScoreMirror} from "../src/crosschain/RobinhoodScoreMirror.sol";
import {Roles} from "../src/libraries/Roles.sol";

/// @title DeployRobinhoodMirror
/// @notice Deploys the read-only score mirror on Robinhood Chain and grants the
///         bridge endpoint BRIDGE_ROLE so it can push score updates.
///
/// @dev Usage:
///   forge script script/DeployRobinhoodMirror.s.sol:DeployRobinhoodMirror \
///     --rpc-url $ROBINHOOD_RPC --broadcast
///
/// Environment:
///   PRIVATE_KEY        deployer/admin key
///   BRIDGE_ENDPOINT    LayerZero/CCIP receiver allowed to write (defaults to deployer for demo)
///   SOURCE_CHAIN_ID    canonical chain id (Arbitrum One = 42161)
contract DeployRobinhoodMirror is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address bridge = vm.envOr("BRIDGE_ENDPOINT", deployer);
        uint256 sourceChainId = vm.envOr("SOURCE_CHAIN_ID", uint256(42161));

        vm.startBroadcast(pk);

        AccessController access = new AccessController(deployer);
        RobinhoodScoreMirror mirror = new RobinhoodScoreMirror(address(access), sourceChainId);

        // Grant the bridge endpoint permission to write mirrored scores.
        bytes32[] memory roles = new bytes32[](1);
        address[] memory accts = new address[](1);
        roles[0] = Roles.BRIDGE_ROLE;
        accts[0] = bridge;
        access.grantRoles(roles, accts);

        vm.stopBroadcast();

        console2.log("=== Robinhood Chain mirror ===");
        console2.log("AccessController     ", address(access));
        console2.log("RobinhoodScoreMirror ", address(mirror));
        console2.log("Bridge endpoint      ", bridge);
        console2.log("Source chain id      ", sourceChainId);
    }
}
