// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {Tender} from "../../src/Tender.sol";
import {DemoConstants} from "../DemoConstants.sol";

/// @dev Demo stage 2/7 (TechReveal): notes that the submission deadline has now passed
///      (deadlines are enforced by chain time, SPEC claim 2) -- `demo.ps1` demonstrates the
///      actual revert as a real `cast send` right before this script runs, since `forge
///      script`'s `--broadcast` mode runs a second, separate simulation pass to prepare
///      the transaction bundle that does not honor `vm.expectRevert` from the first pass,
///      so a revert placed inside this script's own traced execution (even one a
///      try/catch or `vm.expectRevert` "handles" in the first pass) surfaces as
///      "Simulated execution failed" in that second pass and aborts the whole script.
///      `ScriptSmokeTest` covers the revert itself directly (a plain `forge test` has no
///      such second pass to lose it in). Both bidders then post their key envelopes.
///      Run while `submissionDeadline <= block.timestamp < techRevealEnd`.
contract DemoTechReveal is DemoConstants {
    function run() external {
        DemoState memory s = _readState();
        Tender tender = Tender(s.tender);

        console.log("== Stage 2/7: TechReveal ==");
        console.log("Phase:", uint256(tender.currentPhase()));
        console.log("(submissionDeadline has passed -- see the cast send attempt just above)");

        (uint256 goodKey, address bidderGood) = _key(IDX_BIDDER_GOOD);
        (uint256 withholderKey, address bidderWithholder) = _key(IDX_BIDDER_WITHHOLDER);

        vm.startBroadcast(goodKey);
        tender.postKeyEnvelope(keccak256("demo-key-envelope-good"));
        vm.stopBroadcast();
        console.log("bidderGood posted key envelope:", bidderGood);

        vm.startBroadcast(withholderKey);
        tender.postKeyEnvelope(keccak256("demo-key-envelope-withholder"));
        vm.stopBroadcast();
        console.log("bidderWithholder posted key envelope:", bidderWithholder);
    }
}
