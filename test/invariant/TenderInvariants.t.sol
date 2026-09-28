// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TenderInvariantsBase} from "./TenderInvariantsBase.sol";

/// @dev Cold-start invariant suite (SPEC §9, I1-I12): handler-driven from tender creation,
///      5 registered bidders, the tender's own 3 evaluators/PE/authority, bounded
///      forward-only time warps. `foundry.toml` sets runs = 256, fail_on_revert = false;
///      depth is raised to 500 for this contract specifically (Step 7b item 1).
///
///      Vacuity check (see `afterInvariant`): even after depth 64->500, four separate
///      warp-collapse guards (`_clampWarpTarget`), and guided bidder/evaluator targeting
///      (`_bidderWithState`/`_evaluatorWhoHasntVoted`) -- each of which measurably helped
///      (vote successes went 0 -> 10 -> 56 across these changes) -- PriceReveal/
///      Acceptance/Final are still reached in well under 20% of runs (see the Step 7b
///      report for the exact numbers). This is a genuine, reported limitation of
///      unguided action-level fuzzing for a protocol this deep (5 actors x 3 evaluators
///      x ~19 actions x 6 sequential preconditions before any late phase is reachable at
///      all), not a defect papered over: the late-phase/settlement properties this
///      handler under-explores (award-to-lowest, F2/F3 forfeiture, re-award after lapse)
///      are instead covered deterministically by TenderAward.t.sol, TenderScenarios.t.sol
///      and TenderSettle.t.sol, and -- for random late-phase sequences specifically -- by
///      the checkpoint suites (TenderInvariantsCP1..CP4Test, Step 7d) that start the
///      handler already past this suite's weakest stretch. This suite's own real
///      contribution is checking I1/I3/I6/I7/I8/I10/I11 hold under genuinely random
///      *early/mid*-lifecycle sequences, which it does exercise heavily (Open 93%,
///      TechReveal 30%, Evaluation 12%).
/// forge-config: default.invariant.depth = 500
contract TenderInvariantsTest is TenderInvariantsBase {
    function setUp() public override {
        super.setUp();
        _deployTenderAndHandler();
    }

    function _suiteTag() internal pure override returns (string memory) {
        return "CP0";
    }
}
