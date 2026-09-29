// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

/// @dev Shared roles and state file for the local Anvil demo (SPEC §10 Step 8). Every
///      demo script is a SEPARATE `forge script` process, so the addresses `DeployLocal`
///      creates are handed to later scripts through a small JSON state file rather than
///      recomputed or hardcoded (Anvil's default accounts are well-known, but which
///      contract addresses `DeployLocal` produced depends on the deployer's nonce).
///
///      Anvil's default mnemonic ("test test test test test test test test test test
///      test junk") deterministically derives 10 pre-funded accounts; this demo uses
///      every one of them by role so nothing needs separate funding. It is NEVER used for
///      anything beyond localhost:8545 -- see `DeploySepolia.s.sol` for the real-network
///      script, which uses a Foundry keystore account instead.
abstract contract DemoConstants is Script {
    string internal constant ANVIL_MNEMONIC =
        "test test test test test test test test test test test junk";

    uint256 internal constant IDX_DEPLOYER = 0;
    uint256 internal constant IDX_REGISTRAR = 1;
    uint256 internal constant IDX_PE = 2;
    uint256 internal constant IDX_AUTHORITY = 3;
    uint256 internal constant IDX_TREASURY = 4;
    uint256 internal constant IDX_EVAL1 = 5;
    uint256 internal constant IDX_EVAL2 = 6;
    uint256 internal constant IDX_EVAL3 = 7;
    uint256 internal constant IDX_BIDDER_GOOD = 8;
    uint256 internal constant IDX_BIDDER_WITHHOLDER = 9;

    string internal constant STATE_PATH = "script/demo/.demo-state.json";

    struct DemoState {
        address registry;
        address token;
        address factory;
        address tender;
        uint64 vendorIdGood;
        uint64 vendorIdWithholder;
        uint256 price;
        bytes32 docHash;
        bytes32 saltGood;
        bytes32 saltWithholder;
    }

    function _key(uint256 index) internal pure returns (uint256 privateKey, address account) {
        privateKey = vm.deriveKey(ANVIL_MNEMONIC, uint32(index));
        account = vm.addr(privateKey);
    }

    /// @dev Every field is written as a hex string via `vm.serializeAddress`/`vm.serializeBytes32`
    ///      /`vm.serializeUint`, then the whole object in one `vm.writeJson` (each
    ///      `serialize*` call only builds up an in-memory JSON object keyed by `objectKey`
    ///      until the final write).
    function _writeState(DemoState memory s) internal {
        string memory objectKey = "demoState";
        vm.serializeAddress(objectKey, "registry", s.registry);
        vm.serializeAddress(objectKey, "token", s.token);
        vm.serializeAddress(objectKey, "factory", s.factory);
        vm.serializeAddress(objectKey, "tender", s.tender);
        vm.serializeUint(objectKey, "vendorIdGood", s.vendorIdGood);
        vm.serializeUint(objectKey, "vendorIdWithholder", s.vendorIdWithholder);
        vm.serializeUint(objectKey, "price", s.price);
        vm.serializeBytes32(objectKey, "docHash", s.docHash);
        vm.serializeBytes32(objectKey, "saltGood", s.saltGood);
        string memory json = vm.serializeBytes32(objectKey, "saltWithholder", s.saltWithholder);
        vm.writeJson(json, STATE_PATH);
    }

    function _readState() internal view returns (DemoState memory s) {
        string memory json = vm.readFile(STATE_PATH);
        s.registry = vm.parseJsonAddress(json, ".registry");
        s.token = vm.parseJsonAddress(json, ".token");
        s.factory = vm.parseJsonAddress(json, ".factory");
        s.tender = vm.parseJsonAddress(json, ".tender");
        s.vendorIdGood = uint64(vm.parseJsonUint(json, ".vendorIdGood"));
        s.vendorIdWithholder = uint64(vm.parseJsonUint(json, ".vendorIdWithholder"));
        s.price = vm.parseJsonUint(json, ".price");
        s.docHash = vm.parseJsonBytes32(json, ".docHash");
        s.saltGood = vm.parseJsonBytes32(json, ".saltGood");
        s.saltWithholder = vm.parseJsonBytes32(json, ".saltWithholder");
    }
}
