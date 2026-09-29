// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {VendorRegistry} from "../src/VendorRegistry.sol";
import {MockTLKR} from "../src/MockTLKR.sol";
import {TenderFactory} from "../src/TenderFactory.sol";
import {DemoConstants} from "./DemoConstants.sol";

/// @dev Local Anvil demo deploy, part 1/2 (SPEC §10 Step 8): registry, tLKR, factory, and
///      the two demo vendors. Writes their addresses/IDs to `DemoConstants.STATE_PATH` for
///      `CreateDemoTender.s.sol` (a SEPARATE script/broadcast, see that file's doc comment
///      for why) and the `script/demo/*.s.sol` stage scripts to pick up.
///
///      Run against a local Anvil node:
///        forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
contract DeployLocal is DemoConstants {
    function run() external {
        console.log("== TenderSeal local demo deploy (1/2): infra + vendors ==");

        (VendorRegistry registry, MockTLKR token, TenderFactory factory) = _deployCore();
        (uint64 vendorIdGood, uint64 vendorIdWithholder) = _registerVendors(registry);

        DemoState memory s;
        s.registry = address(registry);
        s.token = address(token);
        s.factory = address(factory);
        s.vendorIdGood = vendorIdGood;
        s.vendorIdWithholder = vendorIdWithholder;
        _writeState(s);

        console.log("== Part 1/2 complete; run CreateDemoTender.s.sol next ==");
    }

    function _deployCore()
        internal
        returns (VendorRegistry registry, MockTLKR token, TenderFactory factory)
    {
        (uint256 deployerKey, address deployer) = _key(IDX_DEPLOYER);
        (, address registrarAddr) = _key(IDX_REGISTRAR);

        vm.startBroadcast(deployerKey);
        registry = new VendorRegistry(deployer, registrarAddr);
        token = new MockTLKR(deployer);
        factory = new TenderFactory(address(registry), address(token));
        vm.stopBroadcast();

        console.log("VendorRegistry:", address(registry));
        console.log("MockTLKR:", address(token));
        console.log("TenderFactory:", address(factory));
    }

    function _registerVendors(VendorRegistry registry)
        internal
        returns (uint64 vendorIdGood, uint64 vendorIdWithholder)
    {
        (, address bidderGood) = _key(IDX_BIDDER_GOOD);
        (, address bidderWithholder) = _key(IDX_BIDDER_WITHHOLDER);

        vm.startBroadcast(vm.deriveKey(ANVIL_MNEMONIC, uint32(IDX_REGISTRAR)));
        vendorIdGood = registry.registerVendor(bidderGood, keccak256("demo-vendor-good"));
        vendorIdWithholder =
            registry.registerVendor(bidderWithholder, keccak256("demo-vendor-withholder"));
        vm.stopBroadcast();

        console.log("Registered bidderGood as vendor", vendorIdGood);
        console.log("Registered bidderWithholder as vendor", vendorIdWithholder);
    }
}
