// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TenderInvariantsBase} from "./TenderInvariantsBase.sol";

/// @dev Checkpoint suite (Step 7d): starts the SAME handler, exercising the SAME
///      invariant_I1..I12 checks as `TenderInvariantsTest`, from a fixed point at the
///      *start of Evaluation* with all 5 bidders committed and their key envelopes
///      posted (all Revealed) -- i.e. right past the cold-start suite's weakest stretch
///      (Open/TechReveal), so randomness gets a full budget to reach Evaluation ->
///      AppealFiling -> AppealResolution -> PriceReveal -> Acceptance -> Final/Cancelled/
///      Failed instead of spending most of its depth just getting bidders committed and
///      revealed.
///
///      `setUp` builds the checkpoint by calling ONLY the handler's own functions
///      (`commit`, `postKeyEnvelope`) -- never `TenderHarness` setters -- so the
///      handler's shadow state machine (shadow_state, the three counters,
///      ghost_commitSuccesses/ghost_*) records every step exactly as if the fuzzer itself
///      had produced this sequence. Time is advanced with `vm.warp` directly (not
///      `handler.warp`/`warpToNextBoundary`) purely to land on the exact checkpoint
///      timestamp; nothing about the checkpoint sequence touches the handler's shadow
///      time-tracking, which is re-synced by `_syncPhase()` on the first randomized call.
///      Randomness then continues unmodified from this state.
///
/// forge-config: default.invariant.runs = 150
/// forge-config: default.invariant.depth = 300
contract TenderInvariantsCP1Test is TenderInvariantsBase {
    function setUp() public override {
        super.setUp();
        (address[] memory bidderAddrs,) = _deployTenderAndHandler();
        _buildCheckpoint(bidderAddrs);
    }

    /// @dev All 5 bidders: commit (Open) -> postKeyEnvelope (TechReveal) -> warp to
    ///      exactly techRevealEnd, the start of Evaluation. `seed = 0` on every call is
    ///      deliberate: the handler always picks the earliest-index bidder still in the
    ///      wanted state, so repeating 0 walks bidderAddrs[0..4] in order without needing
    ///      per-call index arithmetic.
    function _buildCheckpoint(address[] memory bidderAddrs) internal {
        for (uint256 i = 0; i < bidderAddrs.length; i++) {
            handler.commit(0, i + 1, i, i);
        }

        vm.warp(handler.shadowSubmissionDeadline());
        for (uint256 i = 0; i < bidderAddrs.length; i++) {
            handler.postKeyEnvelope(0);
        }

        vm.warp(handler.shadowTechRevealEnd());
    }

    function _suiteTag() internal pure override returns (string memory) {
        return "CP1";
    }
}
