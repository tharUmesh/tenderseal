// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Tender} from "../src/Tender.sol";
import {TenderFactory} from "../src/TenderFactory.sol";
import {TenderTestBase} from "./utils/TenderTestBase.sol";

/// @dev `TenderFactory` tests (SPEC §6.12): pinned registry/token, `pe == msg.sender`,
///      recording, and events.
contract TenderFactoryTest is TenderTestBase {
    TenderFactory internal factory;

    event TenderDeployed(address indexed tender, address indexed pe, uint64 createdAt);

    function setUp() public override {
        super.setUp();
        factory = new TenderFactory(address(registry), address(token));
    }

    // ------------------------------------------------------------------ constructor

    function test_Constructor_PinsRegistryAndToken() public view {
        assertEq(factory.registry(), address(registry));
        assertEq(factory.token(), address(token));
    }

    function test_Constructor_RevertsOnZeroRegistry() public {
        vm.expectRevert(TenderFactory.ZeroAddress.selector);
        new TenderFactory(address(0), address(token));
    }

    function test_Constructor_RevertsOnZeroToken() public {
        vm.expectRevert(TenderFactory.ZeroAddress.selector);
        new TenderFactory(address(registry), address(0));
    }

    // ------------------------------------------------------------------ createTender reverts

    function test_CreateTender_RevertsOnRegistryMismatch() public {
        address otherRegistry = makeAddr("otherRegistry");
        Tender.TenderConfig memory config = _defaultConfig();
        config.registry = otherRegistry;

        vm.prank(pe);
        vm.expectRevert(
            abi.encodeWithSelector(
                TenderFactory.RegistryMismatch.selector, otherRegistry, address(registry)
            )
        );
        factory.createTender(config);
    }

    function test_CreateTender_RevertsOnTokenMismatch() public {
        address otherToken = makeAddr("otherToken");
        Tender.TenderConfig memory config = _defaultConfig();
        config.token = otherToken;

        vm.prank(pe);
        vm.expectRevert(
            abi.encodeWithSelector(TenderFactory.TokenMismatch.selector, otherToken, address(token))
        );
        factory.createTender(config);
    }

    function test_CreateTender_RevertsWhenCallerIsNotPE() public {
        Tender.TenderConfig memory config = _defaultConfig(); // config.pe == pe

        vm.prank(admin); // not config.pe
        vm.expectRevert(abi.encodeWithSelector(TenderFactory.NotPE.selector, admin, pe));
        factory.createTender(config);
    }

    // ------------------------------------------------------------------ createTender success

    function test_CreateTender_DeploysRecordsAndEmits() public {
        Tender.TenderConfig memory config = _defaultConfig();

        vm.warp(T0 + 1 hours);
        // casting to uint64 is safe: block timestamps fit in uint64 for ~584 billion years
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 expectedCreatedAt = uint64(block.timestamp);

        vm.prank(pe);
        vm.expectEmit(false, true, false, false); // tender address not known ahead of time
        emit TenderDeployed(address(0), pe, expectedCreatedAt);
        Tender tender = factory.createTender(config);

        assertTrue(address(tender) != address(0));
        assertEq(tender.pe(), pe);
        assertEq(tender.createdAt(), expectedCreatedAt);

        assertTrue(factory.isTender(address(tender)));
        assertEq(factory.tenderCount(), 1);
        address[] memory all = factory.tenders();
        assertEq(all.length, 1);
        assertEq(all[0], address(tender));
    }

    function test_CreateTender_MultipleTendersAccumulate() public {
        Tender.TenderConfig memory config = _defaultConfig();

        vm.prank(pe);
        Tender first = factory.createTender(config);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(pe);
        Tender second = factory.createTender(config);

        assertEq(factory.tenderCount(), 2);
        address[] memory all = factory.tenders();
        assertEq(all.length, 2);
        assertEq(all[0], address(first));
        assertEq(all[1], address(second));
        assertTrue(factory.isTender(address(first)));
        assertTrue(factory.isTender(address(second)));
        assertTrue(first != second);
    }

    function test_IsTender_FalseForUnknownAddress() public {
        assertFalse(factory.isTender(makeAddr("random")));
    }
}
