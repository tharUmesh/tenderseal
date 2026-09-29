// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {VendorRegistry} from "../src/VendorRegistry.sol";
import {MockTLKR} from "../src/MockTLKR.sol";
import {TenderFactory} from "../src/TenderFactory.sol";

/// @dev Sepolia infra deploy (SPEC §10 Step 8): `VendorRegistry`, `MockTLKR`, and
///      `TenderFactory` only -- the PE creates the actual tender afterwards (via
///      `TenderFactory.createTender`, e.g. from the Step 9 CLI/UI or `cast send`), since
///      its schedule and evaluator committee are per-tender decisions, not deployment
///      infrastructure.
///
///      Signs with a Foundry keystore account, NEVER a raw private key: run with
///        forge script script/DeploySepolia.s.sol \
///          --rpc-url $SEPOLIA_RPC_URL --account <account-name> --broadcast --verify
///      See README "Deployment" for `cast wallet import` setup.
///
///      Role addresses are read from the environment (never hardcoded, unlike the local
///      demo's well-known Anvil keys) -- set these in `.env` (gitignored) and `source` it,
///      or export them in the shell, before running:
///        SEPOLIA_ADMIN, SEPOLIA_REGISTRAR, SEPOLIA_TREASURY
contract DeploySepolia is Script {
    function run() external {
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        address registrarAddr = vm.envAddress("SEPOLIA_REGISTRAR");
        address treasuryAddr = vm.envAddress("SEPOLIA_TREASURY");

        console.log("== TenderSeal Sepolia infra deploy ==");
        console.log("admin:    ", admin);
        console.log("registrar:", registrarAddr);
        console.log("treasury: ", treasuryAddr);

        vm.startBroadcast();
        VendorRegistry registry = new VendorRegistry(admin, registrarAddr);
        MockTLKR token = new MockTLKR(admin);
        TenderFactory factory = new TenderFactory(address(registry), address(token));
        vm.stopBroadcast();

        console.log("VendorRegistry:", address(registry));
        console.log("MockTLKR:", address(token));
        console.log("TenderFactory:", address(factory));
        console.log("Next: the PE registers vendors via VendorRegistry.registerVendor, then calls");
        console.log("TenderFactory.createTender(config) with its own schedule/evaluators.");
    }
}
