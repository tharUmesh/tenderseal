// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {Tender} from "../../src/Tender.sol";
import {DemoConstants} from "../DemoConstants.sol";

/// @dev Demo stage 4/7 (AppealFiling): bidderWithholder appeals its Ineligible verdict and
///      the appeals authority upholds it, flipping the bid back to Eligible. Run while
///      `evaluationEnd <= block.timestamp < appealFilingEnd`.
contract DemoAppeal is DemoConstants {
    function run() external {
        DemoState memory s = _readState();
        Tender tender = Tender(s.tender);
        (uint256 withholderKey, address bidderWithholder) = _key(IDX_BIDDER_WITHHOLDER);
        (uint256 authorityKey,) = _key(IDX_AUTHORITY);

        console.log("== Stage 4/7: Appeal (AppealFiling) ==");
        console.log("Phase:", uint256(tender.currentPhase()));

        vm.startBroadcast(withholderKey);
        tender.fileAppeal(keccak256("demo-complaint-withholder"));
        vm.stopBroadcast();
        console.log("bidderWithholder filed an appeal:", bidderWithholder);

        vm.startBroadcast(authorityKey);
        tender.resolveAppeal(bidderWithholder, true, keccak256("demo-appeal-upheld-reason"));
        vm.stopBroadcast();
        console.log("Appeal UPHELD -> bidderWithholder is Eligible again");
    }
}
