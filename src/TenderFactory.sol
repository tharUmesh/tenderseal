// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Tender} from "./Tender.sol";

/// @title TenderFactory
/// @notice Deploys and records `Tender` instances that all share one `VendorRegistry` and
///         one deposit token. See docs/SPEC.md §6.12.
/// @dev No upgradeability, no proxies, no `selfdestruct`, no `delegatecall`, no `tx.origin`.
///      Makes no external calls itself: it only deploys `Tender` (a `CREATE`, not a call)
///      and records the result.
contract TenderFactory {
    /// @notice The `VendorRegistry` every tender created here must use.
    address public immutable registry;
    /// @notice The deposit token every tender created here must use.
    address public immutable token;

    address[] private _tenders;
    mapping(address => bool) public isTender;

    event TenderDeployed(address indexed tender, address indexed pe, uint64 createdAt);

    error ZeroAddress();
    error RegistryMismatch(address got, address expected);
    error TokenMismatch(address got, address expected);
    error NotPE(address caller, address pe);

    /// @param registry_ The `VendorRegistry` every tender created here must be configured with.
    /// @param token_ The deposit token every tender created here must be configured with.
    constructor(address registry_, address token_) {
        if (registry_ == address(0) || token_ == address(0)) revert ZeroAddress();
        registry = registry_;
        token = token_;
    }

    /// @notice Deploy a new `Tender` pinned to this factory's registry and token.
    /// @dev Reverts unless `config.registry`/`config.token` match this factory's, and
    ///      unless the caller is `config.pe` (the PE deploys its own tender).
    /// @param config Full tender configuration (SPEC §3); forwarded unchanged to `Tender`.
    /// @return tender The newly deployed `Tender`.
    function createTender(Tender.TenderConfig calldata config) external returns (Tender tender) {
        if (config.registry != registry) revert RegistryMismatch(config.registry, registry);
        if (config.token != token) revert TokenMismatch(config.token, token);
        if (config.pe != msg.sender) revert NotPE(msg.sender, config.pe);

        tender = new Tender(config);

        _tenders.push(address(tender));
        isTender[address(tender)] = true;

        // Avoids an extra external call: `Tender`'s constructor sets `createdAt` from
        // `block.timestamp` in this same transaction, so it is already known here.
        // casting to uint64 is safe: block timestamps fit in uint64 for ~584 billion years
        //
        // The lint below flags this as "after an external call" because deploying `Tender`
        // (line above) counts as one, and the event needs the new address -- there is no
        // way to emit it any earlier. `Tender`'s constructor makes no external calls and
        // cannot call back into this function, and both `_tenders`/`isTender` are already
        // updated above, so there is no state for a reentrant call to observe inconsistently.
        // forge-lint: disable-next-line(unsafe-typecast,reentrancy-events)
        emit TenderDeployed(address(tender), config.pe, uint64(block.timestamp));
    }

    /// @notice Every tender ever deployed by this factory, in deployment order.
    function tenders() external view returns (address[] memory) {
        return _tenders;
    }

    /// @notice Number of tenders deployed by this factory.
    function tenderCount() external view returns (uint256) {
        return _tenders.length;
    }
}
