// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tender} from "../../src/Tender.sol";
import {VendorRegistry} from "../../src/VendorRegistry.sol";
import {MockTLKR} from "../../src/MockTLKR.sol";

/// @dev Shared fixture for Tender tests: actors, a live VendorRegistry and MockTLKR, a
///      default valid TenderConfig (n=3, k=2), and small helpers. See docs/SPEC.md.
abstract contract TenderTestBase is Test {
    uint64 internal constant T0 = 1_790_000_000; // realistic 2026 timestamp
    uint256 internal constant DEPOSIT = 100_000_00; // LKR 100,000.00 (2 decimals)

    bytes32 internal constant DOCS_HASH = keccak256("bidding-docs-v1");

    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");
    address internal pe = makeAddr("pe");
    address internal appealsAuthority = makeAddr("appealsAuthority");
    address internal treasury = makeAddr("treasury");
    address internal eval1 = makeAddr("eval1");
    address internal eval2 = makeAddr("eval2");
    address internal eval3 = makeAddr("eval3");

    VendorRegistry internal registry;
    MockTLKR internal token;

    function setUp() public virtual {
        vm.warp(T0);
        registry = new VendorRegistry(admin, registrar);
        token = new MockTLKR(admin);
    }

    /// @dev Default schedule relative to T0: +1d, +2d, +4d, +5d, +7d, +8d, window 1d.
    function _defaultSchedule() internal pure returns (Tender.Schedule memory) {
        return Tender.Schedule({
            submissionDeadline: T0 + 1 days,
            techRevealEnd: T0 + 2 days,
            evaluationEnd: T0 + 4 days,
            appealFilingEnd: T0 + 5 days,
            priceRevealStart: T0 + 7 days,
            priceRevealEnd: T0 + 8 days,
            acceptanceWindow: 1 days
        });
    }

    /// @dev n = 3 evaluators (eval1..eval3), k = 2 threshold, maxBidders = 20.
    function _defaultConfig() internal view returns (Tender.TenderConfig memory) {
        address[] memory evals = new address[](3);
        evals[0] = eval1;
        evals[1] = eval2;
        evals[2] = eval3;

        bytes[] memory encKeys = new bytes[](3);
        encKeys[0] = _encKey(1);
        encKeys[1] = _encKey(2);
        encKeys[2] = _encKey(3);

        return Tender.TenderConfig({
            registry: address(registry),
            token: address(token),
            pe: pe,
            appealsAuthority: appealsAuthority,
            treasury: treasury,
            evaluators: evals,
            evaluatorEncKeys: encKeys,
            threshold: 2,
            depositAmount: DEPOSIT,
            maxBidders: 20,
            biddingDocsHash: DOCS_HASH,
            schedule: _defaultSchedule()
        });
    }

    /// @dev A deterministic, correctly-sized (33-byte) mock evaluator encryption key.
    function _encKey(uint256 seed) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x02), keccak256(abi.encode("enc-key", seed)));
    }

    function _registerVendor(address account, bytes32 identity) internal returns (uint64 vendorId) {
        vm.prank(registrar);
        vendorId = registry.registerVendor(account, identity);
    }
}
