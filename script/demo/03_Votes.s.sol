// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {Tender} from "../../src/Tender.sol";
import {DemoConstants} from "../DemoConstants.sol";

/// @dev Demo stage 3/7 (Evaluation): eval3 declares a conflict of interest (event only) on
///      bidderGood; eval1+eval2 (k=2 of n=3) reach a majority Eligible verdict on
///      bidderGood and a majority Ineligible verdict on bidderWithholder (reason
///      SPEC_NONCOMPLIANT) -- set up deliberately so the appeal stage has something to
///      appeal. Run while `techRevealEnd <= block.timestamp < evaluationEnd`.
contract DemoVotes is DemoConstants {
    uint8 internal constant REASON_COMPLIANT = 1;
    uint8 internal constant REASON_SPEC_NONCOMPLIANT = 2;

    function run() external {
        DemoState memory s = _readState();
        Tender tender = Tender(s.tender);
        (, address bidderGood) = _key(IDX_BIDDER_GOOD);
        (, address bidderWithholder) = _key(IDX_BIDDER_WITHHOLDER);

        console.log("== Stage 3/7: Votes (Evaluation) ==");
        console.log("Phase:", uint256(tender.currentPhase()));

        (uint256 eval3Key,) = _key(IDX_EVAL3);
        vm.startBroadcast(eval3Key);
        tender.declareConflict(keccak256("eval3-no-material-conflict"));
        vm.stopBroadcast();
        console.log("eval3 declared a conflict-of-interest disclosure (event only)");

        (uint256 eval1Key,) = _key(IDX_EVAL1);
        (uint256 eval2Key,) = _key(IDX_EVAL2);

        vm.startBroadcast(eval1Key);
        tender.castVote(bidderGood, true, REASON_COMPLIANT, keccak256("eval1-report-good"));
        vm.stopBroadcast();
        vm.startBroadcast(eval2Key);
        tender.castVote(bidderGood, true, REASON_COMPLIANT, keccak256("eval2-report-good"));
        vm.stopBroadcast();
        console.log("bidderGood: 2/3 eligible votes -> Eligible");

        vm.startBroadcast(eval1Key);
        tender.castVote(
            bidderWithholder, false, REASON_SPEC_NONCOMPLIANT, keccak256("eval1-report-withholder")
        );
        vm.stopBroadcast();
        vm.startBroadcast(eval2Key);
        tender.castVote(
            bidderWithholder, false, REASON_SPEC_NONCOMPLIANT, keccak256("eval2-report-withholder")
        );
        vm.stopBroadcast();
        console.log("bidderWithholder: 2/3 ineligible votes -> Ineligible (will appeal)");
    }
}
