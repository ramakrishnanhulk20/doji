// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Invariant tests: CreditHandler drives random sequences of posts, cancels, borrows, repays, rolls, auction
// starts and cancels, purchases, settle preparation and settles, write-offs, time and price moves,
// finalisation, redemption and claims across three maturities, and after every call the money rules of the
// threat model must hold: units equal face (C14), CreditMarkets' MUSD and BTC cover escrow plus what every
// market still owes (C14), no redemption pays above par or beyond what was collected (C15), LoanManager's
// balances cover its claimables (C28), and each market's open-loan count matches its open loans (C9).
// It does NOT cover: real Mezo contracts (test/fork), unit transfers between holders, fee-on-transfer tokens,
// more than one fill per borrow, or donations of MUSD and BTC (CreditMarkets.t.sol and Resolution.t.sol).

import {console} from "forge-std/Test.sol";
import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";
import {CreditHandler} from "../utils/CreditHandler.sol";

contract CreditInvariantsTest is LoanFixture {
    CreditHandler internal handler;

    function setUp() public override {
        super.setUp();
        // A 12-hour auction lets purchases at the floor and settles happen inside one 64-call run.
        vm.prank(owner);
        lm.setAuctionParams(PENALTY, FLOOR, 12 hours);

        uint256[] memory existing = new uint256[](3);
        (existing[0], existing[1], existing[2]) = (offerM1, offerM2, offerM3);
        handler = new CreditHandler(
            CreditHandler.Wiring({cm: cm, lm: lm, musd: musd, ve: ve, feed: feed, voter: voter, treasury: treasury}),
            [m1, m2, m3],
            existing,
            lender
        );

        // Duplicates weight the steps of a loan's life, so a 64-call run gets from borrow through an auction
        // to purchase or settle, finalisation, redemption and claims often enough to test them.
        bytes4[24] memory actions = [
            CreditHandler.postOffer.selector,
            CreditHandler.cancelOffer.selector,
            CreditHandler.borrow.selector,
            CreditHandler.borrow.selector,
            CreditHandler.borrow.selector,
            CreditHandler.repay.selector,
            CreditHandler.roll.selector,
            CreditHandler.roll.selector,
            CreditHandler.startAuction.selector,
            CreditHandler.startAuction.selector,
            CreditHandler.cancelAuction.selector,
            CreditHandler.purchase.selector,
            CreditHandler.purchase.selector,
            CreditHandler.prepareSettle.selector,
            CreditHandler.settle.selector,
            CreditHandler.settle.selector,
            CreditHandler.writeOff.selector,
            CreditHandler.warp.selector,
            CreditHandler.warp.selector,
            CreditHandler.movePrice.selector,
            CreditHandler.finalize.selector,
            CreditHandler.redeem.selector,
            CreditHandler.redeem.selector,
            CreditHandler.claim.selector
        ];
        bytes4[] memory selectors = new bytes4[](actions.length);
        for (uint256 i; i < actions.length; ++i) {
            selectors[i] = actions[i];
        }
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _holder(uint256 i) internal view returns (address) {
        return i == 3 ? treasury : handler.lenders(i);
    }

    function invariant_C14_UnitsEqualFace() public view {
        for (uint256 i; i < 3; ++i) {
            uint64 maturity = handler.maturities(i);
            uint256 units = handler.burnedUnits(maturity);
            for (uint256 j; j < 4; ++j) {
                units += cm.pendingUnits(_holder(j), maturity) + cm.balanceOf(_holder(j), maturity);
            }
            assertEq(units, cm.marketOf(maturity).faceTotal, "C14: maker plus treasury units equal face");
        }
    }

    function invariant_C14_MusdBacked() public view {
        uint256 escrow;
        for (uint256 i; i < handler.offerCount(); ++i) {
            escrow += cm.offerOf(handler.offerIds(i)).remaining;
        }
        uint256 stillOwed;
        for (uint256 i; i < 3; ++i) {
            uint64 maturity = handler.maturities(i);
            stillOwed += cm.marketOf(maturity).collectedMusd - handler.redeemedMusd(maturity);
        }
        assertGe(musd.balanceOf(address(cm)), escrow + stillOwed, "C14: MUSD covers escrow and markets");
    }

    function invariant_C14_BtcBacked() public view {
        uint256 stillOwed;
        for (uint256 i; i < 3; ++i) {
            uint64 maturity = handler.maturities(i);
            stillOwed += cm.marketOf(maturity).collectedBtc - handler.redeemedBtc(maturity);
        }
        assertGe(btc.balanceOf(address(cm)), stillOwed, "C14: BTC covers markets");
    }

    function invariant_C15_RedemptionsBounded() public view {
        assertFalse(handler.paidAboveParMusd(), "C15: a redemption paid above one MUSD per unit");
        for (uint256 i; i < 3; ++i) {
            uint64 maturity = handler.maturities(i);
            ICreditMarkets.Market memory market = cm.marketOf(maturity);
            if (market.isFinal) {
                assertLe(handler.redeemedMusd(maturity), market.musdAtFinal, "C15: MUSD paid beyond collected");
                assertLe(handler.redeemedBtc(maturity), market.btcAtFinal, "C15: BTC paid beyond collected");
                assertEq(market.musdAtFinal, market.collectedMusd);
                assertEq(market.btcAtFinal, market.collectedBtc);
            } else {
                assertEq(handler.redeemedMusd(maturity) + handler.redeemedBtc(maturity), 0, "C15: paid before final");
            }
        }
    }

    function invariant_C28_ClaimablesBacked() public view {
        uint256 musdOwed;
        uint256 btcOwed;
        for (uint256 i; i < 3; ++i) {
            musdOwed += lm.claimableMusd(handler.borrowers(i));
            btcOwed += lm.claimableBtc(handler.borrowers(i));
        }
        assertEq(lm.totalClaimableMusd(), musdOwed, "C28: MUSD total matches the claimables");
        assertEq(lm.totalClaimableBtc(), btcOwed, "C28: BTC total matches the claimables");
        assertGe(musd.balanceOf(address(lm)), lm.totalClaimableMusd(), "C28: MUSD claimables unbacked");
        assertGe(btc.balanceOf(address(lm)), lm.totalClaimableBtc(), "C28: BTC claimables unbacked");
    }

    function invariant_C9_OpenLoansMatchLoans() public view {
        for (uint256 i; i < 3; ++i) {
            uint64 maturity = handler.maturities(i);
            uint256 open;
            for (uint256 j; j < handler.tokenCount(); ++j) {
                ILoanManager.Loan memory loan = lm.loanOf(handler.tokenIds(j));
                if (loan.state != ILoanManager.LoanState.None && loan.maturity == maturity) ++open;
            }
            assertEq(open, cm.marketOf(maturity).openLoans, "C9: open-loan count drifted");
        }
    }

    /// @dev Prints how far each run got, so a green result can be checked for real coverage (run with -vv).
    function afterInvariant() external view {
        string[17] memory names = [
            "postOffer",
            "cancelOffer",
            "borrow",
            "repay",
            "roll",
            "startAuction",
            "cancelAuction",
            "purchase",
            "prepareSettle",
            "settle",
            "writeOff",
            "warp",
            "movePrice",
            "finalize",
            "redeem",
            "claim",
            "tokens"
        ];
        for (uint256 i; i < 16; ++i) {
            console.log(names[i], handler.successes(bytes32(bytes(names[i]))));
        }
        console.log(names[16], handler.tokenCount());
    }
}
