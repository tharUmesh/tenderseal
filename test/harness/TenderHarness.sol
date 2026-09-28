// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Tender} from "../../src/Tender.sol";
import {Bid, BidState} from "../../src/TenderTypes.sol";

/// @dev TEST-ONLY. Exposes setters for recorded facts (SPEC §4) so a unit can be tested
///      before the functions that produce those facts exist. Never deploy this contract.
contract TenderHarness is Tender {
    mapping(address => bool) private _h_tracked;

    constructor(TenderConfig memory config) Tender(config) {}

    function h_setCancelledByPE(bool value) external {
        _cancelledByPE = value;
    }

    function h_setCancelledAt(uint64 value) external {
        _cancelledAt = value;
    }

    function h_setAccepted(bool value) external {
        _accepted = value;
    }

    function h_setCounts(uint256 active, uint256 unresolved, uint256 eligible) external {
        _activeBidCount = active;
        _unresolvedCount = unresolved;
        _eligibleCount = eligible;
    }

    /// @dev Marks an existing bid opened at `price`. Add the bid with `h_addBid` first.
    function h_setOpened(address bidder, uint256 price) external {
        _bids[bidder].opened = true;
        _bids[bidder].price = price;
    }

    function h_setWinner(address winner) external {
        _winner = winner;
    }

    /// @dev Inserts or overwrites a bid record, tracking `bidder` in `_bidders` at most once.
    function h_addBid(address bidder, uint64 vendorId, BidState state, bool opened) external {
        if (!_h_tracked[bidder]) {
            _h_tracked[bidder] = true;
            _bidders.push(bidder);
        }
        _bids[bidder] = Bid({
            vendorId: vendorId,
            state: state,
            priceCommitment: bytes32(0),
            docHash: bytes32(0),
            docCipherRef: bytes32(0),
            keyEnvelopeRef: bytes32(0),
            eligibleVotes: 0,
            ineligibleVotes: 0,
            resolvedByAuthority: false,
            appealed: false,
            opened: opened,
            settled: false,
            price: 0
        });
    }
}
