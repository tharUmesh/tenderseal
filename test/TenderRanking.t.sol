// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BidState} from "../src/TenderTypes.sol";
import {TenderHarness} from "./harness/TenderHarness.sol";
import {TenderTestBase} from "./utils/TenderTestBase.sol";

/// @dev `ranking()` / `currentOffer()` tests (SPEC §5).
contract TenderRankingTest is TenderTestBase {
    TenderHarness internal h;

    function setUp() public override {
        super.setUp();
        h = new TenderHarness(_defaultConfig());
    }

    function _addRanked(string memory label, uint64 vendorId, uint256 price)
        internal
        returns (address bidder)
    {
        bidder = makeAddr(label);
        h.h_addBid(bidder, vendorId, BidState.Eligible, false);
        h.h_setOpened(bidder, price);
    }

    // ------------------------------------------------------------------ ranking()

    function test_Ranking_SortsByPriceAscending() public {
        address a = _addRanked("a", 1, 300);
        address b = _addRanked("b", 2, 100);
        address c = _addRanked("c", 3, 200);

        address[] memory ranked = h.ranking();
        assertEq(ranked.length, 3);
        assertEq(ranked[0], b);
        assertEq(ranked[1], c);
        assertEq(ranked[2], a);
    }

    function test_Ranking_TiesBrokenByTieRank() public {
        address a = _addRanked("a", 10, 500);
        address b = _addRanked("b", 20, 500); // same price as a

        bytes32 tieA = keccak256(abi.encode(address(h), uint64(10)));
        bytes32 tieB = keccak256(abi.encode(address(h), uint64(20)));
        address expectedFirst = tieA < tieB ? a : b;
        address expectedSecond = tieA < tieB ? b : a;

        address[] memory ranked = h.ranking();
        assertEq(ranked.length, 2);
        assertEq(ranked[0], expectedFirst);
        assertEq(ranked[1], expectedSecond);
    }

    function test_Ranking_IgnoresNonRankedBids() public {
        address ranked1 = _addRanked("ranked", 1, 100);
        address committed = makeAddr("committed");
        h.h_addBid(committed, 2, BidState.Committed, false);
        address notOpened = makeAddr("notOpened");
        h.h_addBid(notOpened, 3, BidState.Eligible, false);

        address[] memory result = h.ranking();
        assertEq(result.length, 1);
        assertEq(result[0], ranked1);
    }

    function testFuzz_RankingIndependentOfRevealOrder(uint256 seed) public {
        address[4] memory bidders = [makeAddr("r0"), makeAddr("r1"), makeAddr("r2"), makeAddr("r3")];
        uint256[4] memory prices = [uint256(500), uint256(300), uint256(700), uint256(100)];

        uint8[4] memory order = [0, 1, 2, 3];
        for (uint256 i = 3; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }

        for (uint256 k = 0; k < 4; k++) {
            uint256 idx = order[k];
            h.h_addBid(bidders[idx], uint64(idx + 1), BidState.Eligible, false);
            h.h_setOpened(bidders[idx], prices[idx]);
        }

        address[] memory ranked = h.ranking();
        assertEq(ranked.length, 4);
        assertEq(ranked[0], bidders[3]); // 100
        assertEq(ranked[1], bidders[1]); // 300
        assertEq(ranked[2], bidders[0]); // 500
        assertEq(ranked[3], bidders[2]); // 700
    }

    function test_RankedCount_MatchesRankingLength() public {
        _addRanked("a", 1, 100);
        _addRanked("b", 2, 200);
        assertEq(h.rankedCount(), h.ranking().length);
        assertEq(h.rankedCount(), 2);
    }

    // ------------------------------------------------------------------ currentOffer()

    function test_CurrentOffer_NoneBeforePriceRevealEnd() public {
        _addRanked("a", 1, 100);
        vm.warp(h.priceRevealEnd() - 1);
        (uint256 round, address offeree, uint64 windowEnd) = h.currentOffer();
        assertEq(round, 0);
        assertEq(offeree, address(0));
        assertEq(windowEnd, 0);
    }

    function test_CurrentOffer_FirstRoundAtPriceRevealEnd() public {
        address a = _addRanked("a", 1, 100);

        vm.warp(h.priceRevealEnd());
        (uint256 round, address offeree, uint64 windowEnd) = h.currentOffer();
        assertEq(round, 1);
        assertEq(offeree, a);
        assertEq(windowEnd, h.priceRevealEnd() + h.acceptanceWindow());
    }

    function test_CurrentOffer_AdvancesToNextRoundAtWindowEnd() public {
        _addRanked("a", 1, 100);
        address b = _addRanked("b", 2, 200);

        uint64 firstWindowEnd = h.priceRevealEnd() + h.acceptanceWindow();

        vm.warp(firstWindowEnd - 1);
        (uint256 round1,,) = h.currentOffer();
        assertEq(round1, 1);

        vm.warp(firstWindowEnd);
        (uint256 round2, address offeree2, uint64 windowEnd2) = h.currentOffer();
        assertEq(round2, 2);
        assertEq(offeree2, b);
        assertEq(windowEnd2, firstWindowEnd + h.acceptanceWindow());
    }

    function test_CurrentOffer_NoneAfterAllRoundsExhausted() public {
        _addRanked("a", 1, 100); // rankedCount = 1

        uint64 lapseAt = h.priceRevealEnd() + h.acceptanceWindow();
        vm.warp(lapseAt);
        (uint256 round, address offeree, uint64 windowEnd) = h.currentOffer();
        assertEq(round, 0);
        assertEq(offeree, address(0));
        assertEq(windowEnd, 0);
    }

    function test_CurrentOffer_NoneWhenNoRankedBids() public {
        vm.warp(h.priceRevealEnd());
        (uint256 round, address offeree, uint64 windowEnd) = h.currentOffer();
        assertEq(round, 0);
        assertEq(offeree, address(0));
        assertEq(windowEnd, 0);
    }
}
