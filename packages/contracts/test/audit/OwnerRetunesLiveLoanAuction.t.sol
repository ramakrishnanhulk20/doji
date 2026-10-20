// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Audit finding L-01. The floor, duration and penalty a loan will be auctioned on are read when the auction
// starts, not when the loan opens. Within the C19 bounds the owner can, after a loan opens, lower the global line
// so that a lower floor is accepted, then move the floor to 50%, the penalty to 10% and the duration to one hour.
// A loan opened at a 65% line then auctions on a floor below its own line, and an overdue borrower keeps far
// less than the terms they borrowed under. DECISIONS.md settles threat-model F7 with "per-loan snapshots of
// rate, liquidation line and auction terms"; the code snapshots the auction terms per auction only.
// It does NOT cover: an owner acting beyond the hard-coded bounds (a stated non-goal).

import {console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {Resolution} from "../../src/libraries/Resolution.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";

contract OwnerRetunesLiveLoanAuctionTest is LoanFixture {
    function test_L01_OwnerCutsTheFloorAndDurationOfAnOpenLoan() public {
        _openLoan();
        ILoanManager.Loan memory loan = lm.loanOf(TOKEN);
        uint16 floorAtOpen = lm.auctionFloorBps();
        uint16 penaltyAtOpen = lm.penaltyBps();
        uint32 durationAtOpen = lm.auctionDuration();

        // Two setter calls, each inside its bounds: the global line drops first so the lower floor passes its check.
        vm.startPrank(owner);
        lm.setRiskParams(1_000, 4_900);
        lm.setAuctionParams(1_000, 5_000, 1 hours);
        vm.stopPrank();

        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
        ILoanManager.Auction memory auction = lm.auctionOf(TOKEN);
        uint256 owed = lm.owedOf(TOKEN);
        uint256 floorAtOpenTerms = Resolution.floorPrice(auction.startValue, owed, floorAtOpen);
        uint256 borrowerAtOpenTerms =
            floorAtOpenTerms - owed - Math.min(Resolution.penalty(owed, penaltyAtOpen), floorAtOpenTerms - owed);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(buyer);
        uint256 paid = lm.purchase(TOKEN, type(uint256).max, block.timestamp);

        console.log("loan's own line (bps)                 ", loan.liqLtvBps);
        console.log("auction floor applied (bps of start)  ", lm.auctionFloorBps());
        console.log("duration at open / applied (s)        ", durationAtOpen, auction.duration);
        console.log("price paid one hour in                ", paid);
        console.log("borrower keeps under the open terms   ", borrowerAtOpenTerms);
        console.log("borrower keeps now                    ", lm.claimableMusd(alice));

        assertGe(lm.claimableMusd(alice), borrowerAtOpenTerms, "F7: auction terms changed on an open loan");
    }
}
