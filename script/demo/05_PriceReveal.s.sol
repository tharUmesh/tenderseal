// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {Tender} from "../../src/Tender.sol";
import {DemoConstants} from "../DemoConstants.sol";

/// @dev Demo stage 5/7 (PriceReveal): bidderGood opens its price. bidderWithholder is
///      Eligible (its appeal was upheld) but DELIBERATELY never reveals -- demonstrating
///      SPEC claim 6 (strategic withholding is possible, but costly: it forfeits its
///      deposit under F2 once the tender resolves; see stage 7). Run while
///      `priceRevealStart <= block.timestamp < priceRevealEnd`.
contract DemoPriceReveal is DemoConstants {
    function run() external {
        DemoState memory s = _readState();
        Tender tender = Tender(s.tender);
        (, address bidderGood) = _key(IDX_BIDDER_GOOD);
        (, address bidderWithholder) = _key(IDX_BIDDER_WITHHOLDER);

        console.log("== Stage 5/7: PriceReveal ==");
        console.log("Phase:", uint256(tender.currentPhase()));

        // Anyone may call revealPrice; the broadcaster's identity is irrelevant to the
        // commitment check, so this uses the same actor as the rest of the script.
        (uint256 goodKey,) = _key(IDX_BIDDER_GOOD);
        vm.startBroadcast(goodKey);
        tender.revealPrice(bidderGood, s.price, s.saltGood);
        vm.stopBroadcast();
        console.log("bidderGood revealed price:", s.price);

        console.log(
            "bidderWithholder (Eligible) deliberately withholds its reveal -- no call made for",
            bidderWithholder
        );
    }
}
