// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Invariant tests: CreditHandler drives random sequences of plain and parked posts, cancels, borrows, repays,
// rolls, auction starts and cancels, purchases, settle preparation and settles, write-offs, time and price
// moves, finalisation, redemption, early withdrawals, claims, yield lumps into the sMUSD vault, vault index
// jumps and falls, pull-outs, resumed parking and offer-yield withdrawals across three maturities, and after every call the money rules of
// the threat model must hold: units in balances, Claims, pending and redeemed equal face (C14), CreditMarkets'
// MUSD covers the escrow of offers not in the vault plus what every market still owes plus yield delivered and
// not yet paid, its sMUSD covers parked principal, and yield paid never exceeds yield delivered (C14, C30, C31),
// no market pays out more than it collected and no redemption or Claim pays above par (C15), LoanManager's
// balances cover its claimables (C28), and each market's open-loan count matches its open loans (C9).
// It does NOT cover: real Mezo contracts (test/fork), unit transfers between holders, fee-on-transfer tokens,
// more than one fill per borrow, donations of MUSD and BTC (CreditMarkets.t.sol and Resolution.t.sol), stopParking
// on its own, or a vault that pays short or refuses calls (ParkedOffers.t.sol and OfferYield.t.sol).

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
            CreditHandler.Wiring({
                cm: cm,
                lm: lm,
                musd: musd,
                ve: ve,
                feed: feed,
                voter: voter,
                treasury: treasury,
                vault: vault,
                owner: owner,
                guardian: guardian
            }),
            [m1, m2, m3],
            existing,
            lender
        );

        // Duplicates weight the steps of a loan's life, so a 64-call run gets from borrow through an auction
        // to purchase or settle, finalisation, redemption and claims often enough to test them.
        bytes4[34] memory actions = [
            CreditHandler.postOffer.selector,
            CreditHandler.postParkedOffer.selector,
            CreditHandler.postParkedOffer.selector,
            CreditHandler.yieldLump.selector,
            CreditHandler.yieldLump.selector,
            CreditHandler.jumpIndex.selector,
            CreditHandler.pullOut.selector,
            CreditHandler.resumeParking.selector,
            CreditHandler.withdrawOfferYield.selector,
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
            CreditHandler.withdrawCollected.selector,
            CreditHandler.withdrawCollected.selector,
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

    /// @dev Splits unfilled offer MUSD into what sits in CreditMarkets (plain offers, and parked offers of an era
    ///      already pulled out) and what sits in the vault (parked offers of the current era), using the era the
    ///      handler saw at posting rather than anything the contract derives.
    function _escrow() internal view returns (uint256 plain, uint256 inVault) {
        uint32 era = cm.parkingEra();
        for (uint256 i; i < handler.offerCount(); ++i) {
            uint256 id = handler.offerIds(i);
            ICreditMarkets.Offer memory offer = cm.offerOf(id);
            if (offer.parked && handler.parkedEra(id) == era) inVault += offer.remaining;
            else plain += offer.remaining;
        }
    }

    function _unpaidYield() internal view returns (uint256) {
        return cm.yieldDelivered() - cm.yieldPaid();
    }

    /// @dev Units sit in four places: minted balances, Claims, pending, and burned by redeem (the handler's ghost).
    function invariant_C14_UnitsEqualFace() public view {
        for (uint256 i; i < 3; ++i) {
            uint64 maturity = handler.maturities(i);
            uint256 units = handler.burnedUnits(maturity);
            for (uint256 j; j < 4; ++j) {
                address holder = _holder(j);
                units += cm.pendingUnits(holder, maturity) + cm.balanceOf(holder, maturity)
                    + cm.claimOf(holder, maturity).units;
            }
            assertEq(units, cm.marketOf(maturity).faceTotal, "C14: maker plus treasury units equal face");
        }
    }

    /// @dev Money leaves a market only through redeem and early withdrawals, both tracked by the handler's ghosts.
    ///      Wave 2's line: MUSD held covers plain escrow, every market's unpaid collections and yield delivered but
    ///      not yet paid; sMUSD held covers parked principal.
    function invariant_C14_MusdBacked() public view {
        uint256 stillOwed;
        for (uint256 i; i < 3; ++i) {
            uint64 maturity = handler.maturities(i);
            stillOwed += cm.marketOf(maturity).collectedMusd - handler.redeemedMusd(maturity)
                - handler.withdrawnMusd(maturity);
        }
        assertLe(cm.yieldPaid(), cm.yieldDelivered(), "C31: yield paid above yield delivered");
        (uint256 plain,) = _escrow();
        assertGe(
            musd.balanceOf(address(cm)),
            plain + stillOwed + _unpaidYield(),
            "C14: MUSD covers plain escrow, markets and unpaid yield"
        );
        assertGe(vault.balanceOf(address(cm)), cm.parkedPrincipal(), "C14: sMUSD covers parked principal");
    }

    /// @dev parkedPrincipal is checked against the offers themselves, and every yield payout against the ghost.
    function invariant_C30_ParkedPrincipalMatchesOffers() public view {
        (, uint256 inVault) = _escrow();
        assertEq(cm.parkedPrincipal(), inVault, "C30: parked principal is the sum of in-vault remainders");
        assertEq(musd.allowance(address(cm), address(vault)), 0, "C34: no standing allowance");
        assertEq(cm.yieldPaid(), handler.yieldWithdrawn(), "C31: yield paid only by withdrawOfferYield");
    }

    function invariant_C14_BtcBacked() public view {
        uint256 stillOwed;
        for (uint256 i; i < 3; ++i) {
            uint64 maturity = handler.maturities(i);
            stillOwed +=
                cm.marketOf(maturity).collectedBtc - handler.redeemedBtc(maturity) - handler.withdrawnBtc(maturity);
        }
        assertGe(btc.balanceOf(address(cm)), stillOwed, "C14: BTC covers markets");
    }

    /// @dev The contract's own paid-out record: never above what a market collected, equal to everything the
    ///      handler saw leave through redeem and early withdrawals, and backed by the balances with escrow.
    function invariant_C15_PaidOutBoundedAndBacked() public view {
        uint256 musdOwed;
        uint256 btcOwed;
        for (uint256 i; i < 3; ++i) {
            uint64 maturity = handler.maturities(i);
            ICreditMarkets.Market memory market = cm.marketOf(maturity);
            (uint256 paidMusd, uint256 paidBtc) = cm.paidOutOf(maturity);
            assertLe(paidMusd, market.collectedMusd, "C15: MUSD paid out above collected");
            assertLe(paidBtc, market.collectedBtc, "C15: BTC paid out above collected");
            assertEq(paidMusd, handler.redeemedMusd(maturity) + handler.withdrawnMusd(maturity), "MUSD record drifted");
            assertEq(paidBtc, handler.redeemedBtc(maturity) + handler.withdrawnBtc(maturity), "BTC record drifted");
            musdOwed += market.collectedMusd - paidMusd;
            btcOwed += market.collectedBtc - paidBtc;
        }
        (uint256 plain,) = _escrow();
        assertGe(
            musd.balanceOf(address(cm)),
            plain + musdOwed + _unpaidYield(),
            "C14: MUSD covers plain escrow, unpaid collections and unpaid yield"
        );
        assertGe(btc.balanceOf(address(cm)), btcOwed, "C14: BTC covers unpaid collections");
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
        // Borrowers hold surpluses and leftovers; the treasury holds the penalties from sales and settles.
        uint256 musdOwed = lm.claimableMusd(treasury);
        uint256 btcOwed = lm.claimableBtc(treasury);
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

    /// @dev Prints how often each action succeeded across every run so far, so a green result can be checked for
    ///      real coverage (run with -vv; the last run's print holds the campaign's totals). Every run starts again
    ///      from setUp's state, so the running totals are carried between runs in the process environment.
    function afterInvariant() external {
        string[25] memory names = [
            "postOffer",
            "postParkedOffer",
            "yieldLump",
            "jumpIndex",
            "pullOut",
            "resumeParking",
            "withdrawOfferYield",
            "yieldPaidOut",
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
            "withdrawCollected",
            "claim",
            "tokens"
        ];
        for (uint256 i; i < 24; ++i) {
            console.log(names[i], _carry(names[i], handler.successes(bytes32(bytes(names[i])))));
        }
        console.log(names[24], _carry(names[24], handler.tokenCount()));
        console.log("yield paid to makers, MUSD wei", _carry("yieldWithdrawn", handler.yieldWithdrawn()));
    }

    function _carry(string memory name, uint256 thisRun) internal returns (uint256 total) {
        string memory key = string.concat("DOJI_INVARIANT_TOTAL_", name);
        total = vm.envOr(key, uint256(0)) + thisRun;
        vm.setEnv(key, vm.toString(total));
    }
}
