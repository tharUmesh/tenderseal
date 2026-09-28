// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {VendorRegistry} from "../src/VendorRegistry.sol";

contract VendorRegistryTest is Test {
    VendorRegistry internal registry;

    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");
    address internal outsider = makeAddr("outsider");
    address internal vendorA = makeAddr("vendorA");
    address internal vendorB = makeAddr("vendorB");

    bytes32 internal constant ID_A = keccak256("BRN:PV-00001");
    bytes32 internal constant ID_B = keccak256("BRN:PV-00002");
    bytes32 internal constant REASON = keccak256("debarment-order-2026-001.pdf");

    uint64 internal constant T0 = 1_790_000_000; // realistic 2026 timestamp

    event VendorRegistered(
        uint64 indexed vendorId, address indexed account, bytes32 identityHash, uint64 registeredAt
    );
    event VendorDebarred(uint64 indexed vendorId, bytes32 reasonHash, uint64 debarredAt);

    function setUp() public {
        vm.warp(T0);
        registry = new VendorRegistry(admin, registrar);
    }

    function _register(address account, bytes32 identity) internal returns (uint64) {
        vm.prank(registrar);
        return registry.registerVendor(account, identity);
    }

    // ------------------------------------------------------------------ constructor

    function test_Constructor_RevertsOnZeroAdmin() public {
        vm.expectRevert(VendorRegistry.ZeroAddress.selector);
        new VendorRegistry(address(0), registrar);
    }

    function test_Constructor_RevertsOnZeroRegistrar() public {
        vm.expectRevert(VendorRegistry.ZeroAddress.selector);
        new VendorRegistry(admin, address(0));
    }

    function test_Constructor_GrantsRoles() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.REGISTRAR_ROLE(), registrar));
        assertFalse(registry.hasRole(registry.REGISTRAR_ROLE(), admin));
    }

    // ------------------------------------------------------------------ registration

    function test_Register_AssignsSequentialIdsAndStoresRecord() public {
        vm.expectEmit(true, true, false, true);
        emit VendorRegistered(1, vendorA, ID_A, T0);
        uint64 idA = _register(vendorA, ID_A);

        vm.warp(T0 + 10);
        uint64 idB = _register(vendorB, ID_B);

        assertEq(idA, 1);
        assertEq(idB, 2);
        assertEq(registry.vendorCount(), 2);
        assertEq(registry.vendorIdOf(vendorA), 1);
        assertEq(registry.vendorIdOf(vendorB), 2);
        assertEq(registry.vendorIdOf(outsider), 0);

        VendorRegistry.Vendor memory v = registry.getVendor(idB);
        assertEq(v.account, vendorB);
        assertEq(v.identityHash, ID_B);
        assertEq(v.registeredAt, T0 + 10);
        assertEq(v.debarredAt, 0);
        assertEq(v.debarReasonHash, bytes32(0));
    }

    function test_Register_OnlyRegistrar() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                outsider,
                registry.REGISTRAR_ROLE()
            )
        );
        vm.prank(outsider);
        registry.registerVendor(vendorA, ID_A);
    }

    function test_Register_AdminIsNotRegistrar() public {
        vm.expectRevert();
        vm.prank(admin);
        registry.registerVendor(vendorA, ID_A);
    }

    function test_Register_RevertsOnZeroAccount() public {
        vm.expectRevert(VendorRegistry.ZeroAddress.selector);
        _register(address(0), ID_A);
    }

    function test_Register_RevertsOnZeroIdentity() public {
        vm.expectRevert(VendorRegistry.ZeroHash.selector);
        _register(vendorA, bytes32(0));
    }

    function test_Register_RevertsOnDuplicateAccount() public {
        _register(vendorA, ID_A);
        vm.expectRevert(
            abi.encodeWithSelector(VendorRegistry.AccountAlreadyRegistered.selector, vendorA, 1)
        );
        _register(vendorA, ID_B);
    }

    function test_Register_RevertsOnDuplicateIdentity() public {
        // Same legal entity cannot obtain a second eligible identity via another address.
        _register(vendorA, ID_A);
        vm.expectRevert(
            abi.encodeWithSelector(VendorRegistry.IdentityAlreadyRegistered.selector, ID_A, 1)
        );
        _register(vendorB, ID_A);
    }

    function test_GetVendor_RevertsForUnknownId() public {
        vm.expectRevert(abi.encodeWithSelector(VendorRegistry.UnknownVendor.selector, 7));
        registry.getVendor(7);
    }

    function test_RevokedRegistrarCannotRegister() public {
        bytes32 role = registry.REGISTRAR_ROLE();
        vm.prank(admin);
        registry.revokeRole(role, registrar);
        vm.expectRevert();
        _register(vendorA, ID_A);
    }

    // ------------------------------------------------------------------ registration cutoff (I8)

    function test_IsRegisteredBefore_StrictBoundary() public {
        uint64 id = _register(vendorA, ID_A); // registeredAt = T0
        assertFalse(registry.isRegisteredBefore(id, T0 - 1));
        assertFalse(registry.isRegisteredBefore(id, T0)); // same second: NOT before
        assertTrue(registry.isRegisteredBefore(id, T0 + 1));
    }

    function test_IsRegisteredBefore_FalseForUnknownVendor() public view {
        assertFalse(registry.isRegisteredBefore(0, type(uint64).max));
        assertFalse(registry.isRegisteredBefore(42, type(uint64).max));
    }

    // ------------------------------------------------------------------ debarment (I9)

    function test_Debar_RecordsTimestampAndReason() public {
        uint64 id = _register(vendorA, ID_A);
        vm.warp(T0 + 100);

        vm.expectEmit(true, false, false, true);
        emit VendorDebarred(id, REASON, T0 + 100);
        vm.prank(registrar);
        registry.debarVendor(id, REASON);

        VendorRegistry.Vendor memory v = registry.getVendor(id);
        assertEq(v.debarredAt, T0 + 100);
        assertEq(v.debarReasonHash, REASON);
        assertTrue(registry.isDebarred(id));
    }

    function test_Debar_OnlyRegistrar() public {
        uint64 id = _register(vendorA, ID_A);
        vm.expectRevert();
        vm.prank(outsider);
        registry.debarVendor(id, REASON);
    }

    function test_Debar_RevertsForUnknownVendor() public {
        vm.expectRevert(abi.encodeWithSelector(VendorRegistry.UnknownVendor.selector, 9));
        vm.prank(registrar);
        registry.debarVendor(9, REASON);
    }

    function test_Debar_RevertsOnZeroReason() public {
        uint64 id = _register(vendorA, ID_A);
        vm.expectRevert(VendorRegistry.ZeroHash.selector);
        vm.prank(registrar);
        registry.debarVendor(id, bytes32(0));
    }

    function test_Debar_IsPermanentAndCannotBeRewritten() public {
        // A second debarment would let the registrar move `debarredAt` across a tender's
        // priceRevealStart cutoff after prices are known. It must be impossible.
        uint64 id = _register(vendorA, ID_A);
        vm.warp(T0 + 100);
        vm.prank(registrar);
        registry.debarVendor(id, REASON);

        vm.warp(T0 + 200);
        vm.expectRevert(
            abi.encodeWithSelector(VendorRegistry.AlreadyDebarred.selector, id, T0 + 100)
        );
        vm.prank(registrar);
        registry.debarVendor(id, keccak256("another reason"));
        assertEq(registry.getVendor(id).debarredAt, T0 + 100);
    }

    function test_IsDebarredBefore_StrictBoundary() public {
        uint64 id = _register(vendorA, ID_A);
        assertFalse(registry.isDebarredBefore(id, type(uint64).max)); // never debarred

        vm.warp(T0 + 500);
        vm.prank(registrar);
        registry.debarVendor(id, REASON); // debarredAt = T0 + 500

        assertFalse(registry.isDebarredBefore(id, T0 + 499));
        assertFalse(registry.isDebarredBefore(id, T0 + 500)); // same second: NOT before
        assertTrue(registry.isDebarredBefore(id, T0 + 501));
    }

    function test_Debar_DoesNotChangeIdentityFields() public {
        uint64 id = _register(vendorA, ID_A);
        vm.prank(registrar);
        registry.debarVendor(id, REASON);

        VendorRegistry.Vendor memory v = registry.getVendor(id);
        assertEq(v.account, vendorA);
        assertEq(v.identityHash, ID_A);
        assertEq(v.registeredAt, T0);
        assertEq(registry.vendorIdOf(vendorA), id);
    }

    // ------------------------------------------------------------------ fuzz: bijection

    /// @dev Registering n distinct accounts yields IDs 1..n with a one-to-one
    ///      account <-> ID mapping, and no identity can be reused.
    function testFuzz_RegistrationIsBijective(uint8 n, uint256 seed) public {
        n = uint8(bound(n, 1, 40));
        address[] memory accounts = new address[](n);

        for (uint256 i = 0; i < n; i++) {
            accounts[i] = address(uint160(uint256(keccak256(abi.encode(seed, i))) | 1));
            bytes32 identity = keccak256(abi.encode("identity", seed, i));
            uint64 id = _register(accounts[i], identity);
            assertEq(id, i + 1);
        }

        assertEq(registry.vendorCount(), n);
        for (uint256 i = 0; i < n; i++) {
            uint64 id = registry.vendorIdOf(accounts[i]);
            assertEq(id, i + 1);
            assertEq(registry.getVendor(id).account, accounts[i]);
        }

        // Any attempt to reuse an existing identity with a fresh address must fail.
        bytes32 reused = keccak256(abi.encode("identity", seed, uint256(0)));
        vm.expectRevert();
        _register(address(uint160(uint256(keccak256(abi.encode("fresh", seed))) | 1)), reused);
    }
}
