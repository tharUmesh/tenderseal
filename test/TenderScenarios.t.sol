// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Tender} from "../src/Tender.sol";
import {BidState, Phase, Settlement, TerminalCause} from "../src/TenderTypes.sol";
import {TenderTestBase} from "./utils/TenderTestBase.sol";

/// @dev End-to-end scenario tests (SPEC §10 Step 7): a full happy-path lifecycle, an
///      appeal that changes who wins, and a ring attack (selective non-reveal) that
///      succeeds at manipulating the price while costing exactly the withholder's
///      forfeited deposit -- demonstrating claim 6 in SPEC §1 ("strategic withholding
///      ... detectable, attributable and costly, but NOT eliminated").
contract TenderScenariosTest is TenderTestBase {
    bytes32 internal constant DOC_HASH = keccak256("d");
    bytes32 internal constant DOC_CIPHER_REF = keccak256("c");
    bytes32 internal constant KEY_ENV_REF = keccak256("k");
    bytes32 internal constant REPORT_HASH = keccak256("r");
    uint8 internal constant REASON_COMPLIANT = 1;
    uint8 internal constant REASON_SPEC_NONCOMPLIANT = 2;

    function _fundAndApprove(Tender t, address who) internal {
        vm.prank(admin);
        token.mint(who, DEPOSIT * 10);
        vm.prank(who);
        token.approve(address(t), type(uint256).max);
    }

    function _fundAndApproveAmount(Tender t, address who, uint256 amount) internal {
        vm.prank(admin);
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(t), type(uint256).max);
    }

    function _commitment(Tender t, address bidder, uint256 price, bytes32 salt)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(t), bidder, price, DOC_HASH, salt));
    }

    // ==================================================================
    // Full lifecycle
    // ==================================================================

    function test_Scenario_FullLifecycle_LowestBidderWinsAndEveryoneSettlesCorrectly() public {
        address a = makeAddr("scenarioA"); // 100 -- wins
        address b = makeAddr("scenarioB"); // 200 -- ranked after winner
        _registerVendor(a, keccak256("scenarioA"));
        _registerVendor(b, keccak256("scenarioB"));

        vm.warp(T0 + 1 hours);
        Tender tender = new Tender(_defaultConfig());
        _fundAndApprove(tender, a);
        _fundAndApprove(tender, b);

        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        vm.prank(a);
        tender.commit(_commitment(tender, a, 100, saltA), DOC_HASH, DOC_CIPHER_REF);
        vm.prank(b);
        tender.commit(_commitment(tender, b, 200, saltB), DOC_HASH, DOC_CIPHER_REF);

        vm.warp(tender.submissionDeadline());
        vm.prank(a);
        tender.postKeyEnvelope(KEY_ENV_REF);
        vm.prank(b);
        tender.postKeyEnvelope(KEY_ENV_REF);

        vm.warp(tender.techRevealEnd());
        vm.prank(eval1);
        tender.castVote(a, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(a, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval1);
        tender.castVote(b, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(b, true, REASON_COMPLIANT, REPORT_HASH);

        vm.warp(tender.priceRevealStart());
        tender.revealPrice(a, 100, saltA);
        tender.revealPrice(b, 200, saltB);

        vm.warp(tender.priceRevealEnd());
        (uint256 round, address offeree,) = tender.currentOffer();
        assertEq(round, 1);
        assertEq(offeree, a);

        vm.prank(a);
        tender.acceptAward();
        assertEq(tender.winner(), a);

        vm.prank(pe);
        tender.acknowledgeAward();
        assertEq(uint256(tender.currentPhase()), uint256(Phase.Final));

        uint256 aBalanceBefore = token.balanceOf(a);
        uint256 bBalanceBefore = token.balanceOf(b);
        tender.settle(a);
        tender.settle(b);

        assertEq(token.balanceOf(a), aBalanceBefore + DEPOSIT); // winner refunded
        assertEq(token.balanceOf(b), bBalanceBefore + DEPOSIT); // ranked-after-winner refunded
        assertEq(tender.totalLiabilities(), 0);
        assertEq(token.balanceOf(address(tender)), 0);
    }

    // ==================================================================
    // Appeal upheld changes the winner
    // ==================================================================

    function test_Scenario_AppealUpheld_ChangesWinner() public {
        // Two independent tenders with identical bids, diverging only on whether A's
        // wrongly-Ineligible verdict is appealed and upheld.
        (Tender dismissedTender, address aDismissed, address bDismissed) = _runAppealScenario(false);
        (Tender upheldTender, address aUpheld, address bUpheld) = _runAppealScenario(true);

        // Without the appeal: A stays Ineligible, B (the only ranked bidder) wins.
        assertEq(dismissedTender.winner(), bDismissed);

        // With the appeal upheld: A is reinstated, becomes the cheaper ranked bidder,
        // and wins instead of B.
        assertEq(upheldTender.winner(), aUpheld);
        aDismissed; // referenced only for symmetry/readability
        bUpheld;
    }

    /// @dev A (price 100) is voted Ineligible by majority (contested); B (price 200) is
    ///      Eligible. A appeals; the authority either upholds or dismisses per `uphold`.
    ///      Returns the tender and the two bidder addresses once awarded.
    function _runAppealScenario(bool uphold)
        internal
        returns (Tender tender, address a, address b)
    {
        // Reset to a consistent base time first: this helper runs twice in the same
        // test, and the first run's warps would otherwise push registeredAt past the
        // second run's createdAt.
        vm.warp(T0);
        a = makeAddr(uphold ? "appealUpheldA" : "appealDismissedA");
        b = makeAddr(uphold ? "appealUpheldB" : "appealDismissedB");
        _registerVendor(a, keccak256(abi.encode("appealA", uphold)));
        _registerVendor(b, keccak256(abi.encode("appealB", uphold)));

        vm.warp(T0 + 1 hours);
        tender = new Tender(_defaultConfig());
        _fundAndApprove(tender, a);
        _fundAndApprove(tender, b);

        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        vm.prank(a);
        tender.commit(_commitment(tender, a, 100, saltA), DOC_HASH, DOC_CIPHER_REF);
        vm.prank(b);
        tender.commit(_commitment(tender, b, 200, saltB), DOC_HASH, DOC_CIPHER_REF);

        vm.warp(tender.submissionDeadline());
        vm.prank(a);
        tender.postKeyEnvelope(KEY_ENV_REF);
        vm.prank(b);
        tender.postKeyEnvelope(KEY_ENV_REF);

        vm.warp(tender.techRevealEnd());
        // A wrongly voted Ineligible by majority (e.g. a disputed compliance call).
        vm.prank(eval1);
        tender.castVote(a, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(a, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);
        vm.prank(eval1);
        tender.castVote(b, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(b, true, REASON_COMPLIANT, REPORT_HASH);
        assertEq(uint256(tender.getBid(a).state), uint256(BidState.Ineligible));

        vm.warp(tender.evaluationEnd());
        vm.prank(a);
        tender.fileAppeal(keccak256("complaint"));

        vm.prank(appealsAuthority);
        tender.resolveAppeal(a, uphold, keccak256("resolution"));
        assertEq(
            uint256(tender.getBid(a).state),
            uint256(uphold ? BidState.Eligible : BidState.Ineligible)
        );

        vm.warp(tender.priceRevealStart());
        if (uphold) tender.revealPrice(a, 100, saltA);
        tender.revealPrice(b, 200, saltB);

        vm.warp(tender.priceRevealEnd());
        (, address offeree,) = tender.currentOffer();
        vm.prank(offeree);
        tender.acceptAward();
    }

    // ==================================================================
    // Ring attack: selective non-reveal
    // ==================================================================

    /// @dev Two colluding bidders (ring): `ringLowBidder` has the true lowest price but
    ///      deliberately never reveals it, removing itself from ranking so that
    ///      `ringWinner` (the ring's designated winner) wins at a much higher price than
    ///      honest competition would have produced. `outsider` is a genuine, unrelated
    ///      competitor. Demonstrates SPEC §1 claim 6: the withholding succeeds at
    ///      manipulating the price, but costs the withholder's deposit (F2), is publicly
    ///      visible (Eligible, opened == false, forfeited), and attributable (its vendor
    ///      ID is on-chain).
    // Realistic LKR amounts (2 decimals, matching DEPOSIT = LKR 100,000.00 from the base
    // fixture): ring low bid LKR 8,000,000.00 (withheld), ring winner LKR 8,950,000.00,
    // outsider LKR 9,000,000.00.
    uint256 internal constant RING_LOW_PRICE = 8_000_000_00;
    uint256 internal constant RING_WINNER_PRICE = 8_950_000_00;
    uint256 internal constant RING_OUTSIDER_PRICE = 9_000_000_00;

    /// @dev Deploys a tender and runs the ring's collusion through price reveal:
    ///      ringLowBidder (true price 50) stays Eligible but never calls revealPrice;
    ///      ringWinner (190) and outsider (200) both reveal normally.
    function _setupRingAttack()
        internal
        returns (Tender tender, address ringLowBidder, address ringWinner, address outsider)
    {
        ringLowBidder = makeAddr("ringLow");
        ringWinner = makeAddr("ringWinner");
        outsider = makeAddr("outsider");
        _registerVendor(ringLowBidder, keccak256("ringLow"));
        _registerVendor(ringWinner, keccak256("ringWinner"));
        _registerVendor(outsider, keccak256("outsider"));

        vm.warp(T0 + 1 hours);
        tender = new Tender(_defaultConfig());
        _fundAndApprove(tender, ringLowBidder);
        _fundAndApprove(tender, ringWinner);
        _fundAndApprove(tender, outsider);

        _ringAttackCommitRevealVote(tender, ringLowBidder, ringWinner, outsider);
    }

    function _ringAttackCommitRevealVote(
        Tender tender,
        address ringLowBidder,
        address ringWinner,
        address outsider
    ) internal {
        _ringAttackCommitOne(tender, ringLowBidder, RING_LOW_PRICE, keccak256("saltLow"));
        _ringAttackCommitOne(tender, ringWinner, RING_WINNER_PRICE, keccak256("saltWinner"));
        _ringAttackCommitOne(tender, outsider, RING_OUTSIDER_PRICE, keccak256("saltOutsider"));

        vm.warp(tender.submissionDeadline());
        _ringAttackReveal(tender, ringLowBidder);
        _ringAttackReveal(tender, ringWinner);
        _ringAttackReveal(tender, outsider);

        vm.warp(tender.techRevealEnd());
        _ringAttackVoteAll(tender, ringLowBidder, ringWinner, outsider);

        vm.warp(tender.priceRevealStart());
        // The ring's move: ringLowBidder is Eligible but never calls revealPrice.
        tender.revealPrice(ringWinner, RING_WINNER_PRICE, keccak256("saltWinner"));
        tender.revealPrice(outsider, RING_OUTSIDER_PRICE, keccak256("saltOutsider"));
    }

    function _ringAttackCommitOne(Tender tender, address bidder, uint256 price, bytes32 salt)
        internal
    {
        vm.prank(bidder);
        tender.commit(_commitment(tender, bidder, price, salt), DOC_HASH, DOC_CIPHER_REF);
    }

    function _ringAttackReveal(Tender tender, address bidder) internal {
        vm.prank(bidder);
        tender.postKeyEnvelope(KEY_ENV_REF);
    }

    function _ringAttackVoteAll(
        Tender tender,
        address ringLowBidder,
        address ringWinner,
        address outsider
    ) internal {
        address[3] memory all = [ringLowBidder, ringWinner, outsider];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(eval1);
            tender.castVote(all[i], true, REASON_COMPLIANT, REPORT_HASH);
            vm.prank(eval2);
            tender.castVote(all[i], true, REASON_COMPLIANT, REPORT_HASH);
        }
    }

    function test_Scenario_RingAttack_SelectiveNonRevealSucceedsAtACost() public {
        (Tender tender, address ringLowBidder, address ringWinner, address outsider) =
            _setupRingAttack();

        // Detectable: still Eligible, on-chain, but not opened.
        assertEq(uint256(tender.getBid(ringLowBidder).state), uint256(BidState.Eligible));
        assertFalse(tender.getBid(ringLowBidder).opened);

        vm.warp(tender.priceRevealEnd());
        // ringLowBidder excluded from ranking entirely: ranking is [ringWinner, outsider].
        address[] memory ranked = tender.ranking();
        assertEq(ranked.length, 2);
        assertEq(ranked[0], ringWinner);
        assertEq(ranked[1], outsider);

        (uint256 round, address offeree,) = tender.currentOffer();
        assertEq(round, 1);
        assertEq(offeree, ringWinner); // the attack succeeded: wins instead of ringLowBidder

        vm.prank(ringWinner);
        tender.acceptAward();
        assertEq(tender.winner(), ringWinner);

        // The price advantage the ring captured: what the tender pays (LKR 8,950,000.00)
        // vs. what honest competition would have produced had ringLowBidder revealed
        // (LKR 8,000,000.00) -- LKR 950,000.00.
        assertEq(RING_WINNER_PRICE - RING_LOW_PRICE, 950_000_00);

        // The cost: ringLowBidder's deposit (LKR 100,000.00) is forfeited (F2 --
        // Eligible, never opened, terminal cause AwardAccepted) -- exactly one deposit,
        // no more, no less. Net gain to the ring: LKR 950,000.00 - LKR 100,000.00 =
        // LKR 850,000.00 -- profitable, since the price advantage exceeds the deposit.
        _assertRingLowBidderForfeits(tender, ringLowBidder);
    }

    function _assertRingLowBidderForfeits(Tender tender, address ringLowBidder) internal {
        (Settlement outcome, address recipient, uint256 amount) = tender.settlementOf(ringLowBidder);
        assertEq(uint256(outcome), uint256(Settlement.Forfeit));
        assertEq(recipient, treasury);
        assertEq(amount, DEPOSIT);

        uint256 treasuryBalanceBefore = token.balanceOf(treasury);
        tender.settle(ringLowBidder);
        assertEq(token.balanceOf(treasury), treasuryBalanceBefore + DEPOSIT);
    }

    // ==================================================================
    // Fuzz: ring net gain = (high - low) - deposit
    // ==================================================================

    /// @dev Two-bidder version of the ring attack (no outsider needed: the net-gain
    ///      formula only depends on the ring's own low/high prices and the deposit).
    ///      ringLow withholds; ringHigh reveals and wins by default. Asserts the ring's
    ///      net gain equals (high - low) - deposit, i.e. withholding is profitable
    ///      exactly when the price advantage exceeds the forfeited deposit.
    function testFuzz_RingAttack_NetGainEqualsPriceAdvantageMinusDeposit(
        uint256 lowPriceSeed,
        uint256 highPriceSeed,
        uint256 depositSeed
    ) public {
        uint256 lowPrice = bound(lowPriceSeed, 1, 10_000_000_00);
        uint256 highPrice = bound(highPriceSeed, lowPrice + 1, 10_000_000_00 + 1);
        uint256 depositAmount = bound(depositSeed, 1, 5_000_000_00);

        (Tender tender, address ringLow, address ringHigh) =
            _setupTwoBidderRing(lowPrice, highPrice, depositAmount);

        vm.warp(tender.priceRevealStart());
        tender.revealPrice(ringHigh, highPrice, keccak256("fuzzSaltHigh")); // ringLow withholds

        vm.warp(tender.priceRevealEnd());
        (, address offeree,) = tender.currentOffer();
        assertEq(offeree, ringHigh);
        vm.prank(ringHigh);
        tender.acceptAward();

        (Settlement outcome,, uint256 amount) = tender.settlementOf(ringLow);
        assertEq(uint256(outcome), uint256(Settlement.Forfeit));
        assertEq(amount, depositAmount);

        int256 netGain = int256(highPrice) - int256(lowPrice) - int256(depositAmount);
        bool profitable = highPrice - lowPrice > depositAmount;
        assertEq(netGain > 0, profitable);
    }

    function _setupTwoBidderRing(uint256 lowPrice, uint256 highPrice, uint256 depositAmount)
        internal
        returns (Tender tender, address ringLow, address ringHigh)
    {
        ringLow = makeAddr("fuzzRingLow");
        ringHigh = makeAddr("fuzzRingHigh");
        _registerVendor(ringLow, keccak256("fuzzRingLow"));
        _registerVendor(ringHigh, keccak256("fuzzRingHigh"));

        vm.warp(T0 + 1 hours);
        Tender.TenderConfig memory config = _defaultConfig();
        config.depositAmount = depositAmount;
        tender = new Tender(config);

        _fundAndApproveAmount(tender, ringLow, depositAmount);
        _fundAndApproveAmount(tender, ringHigh, depositAmount);

        _twoBidderRingCommitRevealVote(tender, ringLow, ringHigh, lowPrice, highPrice);
    }

    function _twoBidderRingCommitRevealVote(
        Tender tender,
        address ringLow,
        address ringHigh,
        uint256 lowPrice,
        uint256 highPrice
    ) internal {
        vm.prank(ringLow);
        tender.commit(
            _commitment(tender, ringLow, lowPrice, keccak256("fuzzSaltLow")),
            DOC_HASH,
            DOC_CIPHER_REF
        );
        vm.prank(ringHigh);
        tender.commit(
            _commitment(tender, ringHigh, highPrice, keccak256("fuzzSaltHigh")),
            DOC_HASH,
            DOC_CIPHER_REF
        );

        vm.warp(tender.submissionDeadline());
        vm.prank(ringLow);
        tender.postKeyEnvelope(KEY_ENV_REF);
        vm.prank(ringHigh);
        tender.postKeyEnvelope(KEY_ENV_REF);

        vm.warp(tender.techRevealEnd());
        vm.prank(eval1);
        tender.castVote(ringLow, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(ringLow, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval1);
        tender.castVote(ringHigh, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(ringHigh, true, REASON_COMPLIANT, REPORT_HASH);
    }
}
