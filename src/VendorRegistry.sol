// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title VendorRegistry
/// @notice Registrar-maintained registry of vendors eligible to bid in TenderSeal tenders.
/// @dev Security properties this contract provides to tenders:
///      - A vendor ID is assigned once and never changes (no re-binding function exists).
///      - One address maps to exactly one vendor ID, and one vendor ID to exactly one address.
///      - One identity hash (e.g. hash of a business registration number) maps to one vendor ID,
///        so the registrar cannot accidentally register the same legal entity twice.
///      - `registeredAt` lets a tender enforce a registration cutoff (vendors must be registered
///        before the tender was created) -> invariant I8.
///      - `debarredAt` lets a tender apply debarment deterministically (only debarments recorded
///        before the tender's price-reveal start affect it) -> invariant I9.
///      - Debarment is permanent in the MVP.
///      Trust assumption (external, not enforceable on-chain): the registrar verifies that each
///      identity hash corresponds to one real legal entity.
contract VendorRegistry is AccessControl {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    struct Vendor {
        address account; // the vendor's bidding address (immutable)
        bytes32 identityHash; // hash of off-chain legal identity (immutable)
        uint64 registeredAt; // block timestamp of registration (immutable, never 0 once set)
        uint64 debarredAt; // 0 = not debarred; otherwise block timestamp of debarment
        bytes32 debarReasonHash; // hash of the off-chain debarment decision document
    }

    /// @dev vendorId => Vendor. vendorId 0 is reserved to mean "not registered".
    mapping(uint64 => Vendor) private _vendors;
    /// @dev account => vendorId
    mapping(address => uint64) private _idOfAccount;
    /// @dev identityHash => vendorId
    mapping(bytes32 => uint64) private _idOfIdentity;

    uint64 private _nextId = 1;

    event VendorRegistered(
        uint64 indexed vendorId, address indexed account, bytes32 identityHash, uint64 registeredAt
    );
    event VendorDebarred(uint64 indexed vendorId, bytes32 reasonHash, uint64 debarredAt);

    error ZeroAddress();
    error ZeroHash();
    error AccountAlreadyRegistered(address account, uint64 vendorId);
    error IdentityAlreadyRegistered(bytes32 identityHash, uint64 vendorId);
    error UnknownVendor(uint64 vendorId);
    error AlreadyDebarred(uint64 vendorId, uint64 debarredAt);

    /// @param admin Receives DEFAULT_ADMIN_ROLE (can grant/revoke the registrar role).
    /// @param registrar Receives REGISTRAR_ROLE (can register and debar vendors).
    constructor(address admin, address registrar) {
        if (admin == address(0) || registrar == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRAR_ROLE, registrar);
    }

    // ---------------------------------------------------------------------
    // Registrar actions
    // ---------------------------------------------------------------------

    /// @notice Register a new vendor. The assigned ID can never change.
    /// @param account The vendor's bidding address.
    /// @param identityHash Hash of the vendor's off-chain legal identity (must be unique).
    /// @return vendorId The newly assigned vendor ID (starts at 1).
    function registerVendor(address account, bytes32 identityHash)
        external
        onlyRole(REGISTRAR_ROLE)
        returns (uint64 vendorId)
    {
        if (account == address(0)) revert ZeroAddress();
        if (identityHash == bytes32(0)) revert ZeroHash();

        uint64 existing = _idOfAccount[account];
        if (existing != 0) revert AccountAlreadyRegistered(account, existing);
        existing = _idOfIdentity[identityHash];
        if (existing != 0) revert IdentityAlreadyRegistered(identityHash, existing);

        vendorId = _nextId++;
        // casting to uint64 is safe: block timestamps fit in uint64 for ~584 billion years
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 nowTs = uint64(block.timestamp);

        _vendors[vendorId] = Vendor({
            account: account,
            identityHash: identityHash,
            registeredAt: nowTs,
            debarredAt: 0,
            debarReasonHash: bytes32(0)
        });
        _idOfAccount[account] = vendorId;
        _idOfIdentity[identityHash] = vendorId;

        emit VendorRegistered(vendorId, account, identityHash, nowTs);
    }

    /// @notice Permanently debar a vendor. Tenders decide the effect using `debarredAt`.
    /// @param vendorId The vendor to debar.
    /// @param reasonHash Hash of the off-chain debarment decision (evidence it was recorded,
    ///        not proof that it was justified).
    function debarVendor(uint64 vendorId, bytes32 reasonHash) external onlyRole(REGISTRAR_ROLE) {
        if (reasonHash == bytes32(0)) revert ZeroHash();
        Vendor storage v = _vendors[vendorId];
        if (v.registeredAt == 0) revert UnknownVendor(vendorId);
        if (v.debarredAt != 0) revert AlreadyDebarred(vendorId, v.debarredAt);

        // casting to uint64 is safe: block timestamps fit in uint64 for ~584 billion years
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 nowTs = uint64(block.timestamp);
        v.debarredAt = nowTs;
        v.debarReasonHash = reasonHash;

        emit VendorDebarred(vendorId, reasonHash, nowTs);
    }

    // ---------------------------------------------------------------------
    // Views used by tenders and the public verifier
    // ---------------------------------------------------------------------

    /// @notice Vendor ID of an account, or 0 if unregistered.
    function vendorIdOf(address account) external view returns (uint64) {
        return _idOfAccount[account];
    }

    /// @notice Full vendor record. Reverts for unknown IDs.
    function getVendor(uint64 vendorId) external view returns (Vendor memory) {
        Vendor memory v = _vendors[vendorId];
        if (v.registeredAt == 0) revert UnknownVendor(vendorId);
        return v;
    }

    /// @notice True if the vendor exists and was registered strictly before `cutoff`.
    /// @dev Tenders call this with their creation timestamp (registration cutoff, I8).
    function isRegisteredBefore(uint64 vendorId, uint64 cutoff) external view returns (bool) {
        uint64 registeredAt = _vendors[vendorId].registeredAt;
        return registeredAt != 0 && registeredAt < cutoff;
    }

    /// @notice True if the vendor is currently debarred (at any time up to now).
    function isDebarred(uint64 vendorId) external view returns (bool) {
        return _vendors[vendorId].debarredAt != 0;
    }

    /// @notice True if the vendor was debarred strictly before `time`.
    /// @dev Tenders call this with their priceRevealStart (deterministic debarment effect, I9).
    function isDebarredBefore(uint64 vendorId, uint64 time) external view returns (bool) {
        uint64 debarredAt = _vendors[vendorId].debarredAt;
        return debarredAt != 0 && debarredAt < time;
    }

    /// @notice Number of vendors registered so far.
    function vendorCount() external view returns (uint64) {
        return _nextId - 1;
    }
}
