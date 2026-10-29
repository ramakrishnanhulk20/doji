// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit and fuzz tests for early payouts: once a date has passed, a lender moves units into a Claim with
// withdrawCollected and is paid its share of what that date's market has collected so far, then more as each
// remaining loan closes, without waiting for finalize. An early lender and a lender who waits for redeem end with
// the same total per unit, in MUSD and BTC, whatever the order and kind of closings and whoever withdraws first.
// One holder that mixes both paths, part early and the rest by redeem, gets its share and never more.
// Runs on the real CreditMarkets and LoanManager with the LoanFixture mocks.
// It does NOT cover: real Mezo contracts (test/fork), unit transfers between holders before a withdrawal,
// fee-on-transfer tokens, or randomised sequences across dates (CreditInvariants.t.sol).

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";

contract EarlyPayoutsTest is LoanFixture {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant TOKEN_B = 8;
    uint256 internal constant TOKEN_C = 9;

    address internal carol = makeAddr("carol");
    address internal thief = makeAddr("thief");
    address internal lenderA = makeAddr("lenderA");
    address internal lenderB = makeAddr("lenderB");
    address internal lenderC = makeAddr("lenderC");

    uint256[3] internal tokens;
    address[3] internal borrowers;
    uint256 internal musdA;
    uint256 internal btcA;
    uint256 internal withdrawalsA;

    /// @dev What one mixed-holder run paid each holder in MUSD and BTC, the units each held, and how many redeem
    ///      and withdrawCollected calls paid out.
    struct MixedRun {
        uint256 musdA;
        uint256 btcA;
        uint256 musdB;
        uint256 btcB;
        uint256 musdT;
        uint256 btcT;
        uint256 unitsA;
        uint256 unitsB;
        uint256 unitsT;
        uint256 payouts;
    }

    function setUp() public override {
        super.setUp();
        musd.mint(carol, 1_000_000e18);
        vm.prank(carol);
        musd.approve(address(lm), type(uint256).max);
        tokens = [TOKEN, TOKEN_B, TOKEN_C];
        borrowers = [alice, bob, carol];
    }

    function _post(address maker, uint128 amount) internal returns (uint256 offerId) {
        musd.mint(maker, amount);
        vm.startPrank(maker);
        musd.approve(address(cm), amount);
        offerId = cm.postOffer(m1, APR, amount);
        vm.stopPrank();
    }

    function _position(address who, uint256 tokenId) internal {
        ve.mint(who, tokenId, LOCK_BTC, m3, false);
        _deposit(who, tokenId);
    }

    /// @dev The amount is worked out by the caller before the prank, so the prank lands on repay itself.
    function _repay(address who, uint256 tokenId, uint256 amount) internal {
        vm.prank(who);
        lm.repay(tokenId, amount);
    }

    function _three(uint128 amount) internal pure returns (uint128[] memory amounts) {
        amounts = new uint128[](3);
        (amounts[0], amounts[1], amounts[2]) = (amount, amount, amount);
    }

    function _withdraw(address who, uint256 units) internal returns (uint256 musdOut, uint256 btcOut) {
        vm.prank(who);
        (musdOut, btcOut) = cm.withdrawCollected(m1, units);
        _assertPaidOutCovered();
    }

    function _assertPaidOutCovered() internal view {
        (uint256 paidMusd, uint256 paidBtc) = cm.paidOutOf(m1);
        ICreditMarkets.Market memory market = cm.marketOf(m1);
        assertLe(paidMusd, market.collectedMusd, "MUSD paid out above what was collected");
        assertLe(paidBtc, market.collectedBtc, "BTC paid out above what was collected");
    }

    /// @dev Alice borrows 30,000 and bob 10,000 at m1 from the fixture lender's offer; alice repays in full and
    ///      the clock moves past the date with bob's loan still open. Returns the lender's minted units.
    function _oneRepaidOneOpenPastTheDate() internal returns (uint256 units) {
        uint256 faceA = _openLoan();
        _position(bob, TOKEN_B);
        _borrow(bob, TOKEN_B, m1, offerM1, 10_000e18);
        vm.prank(alice);
        lm.repay(TOKEN, faceA);
        vm.warp(m1 + 1);
        vm.prank(lender);
        units = cm.claimUnits(m1);
    }

    /// @dev Three loans at m1, each filled from lender A's and lender B's offers in seeded sizes.
    function _threeLoansFromTwoLenders(uint256 sizeSeed) internal returns (uint256 unitsA, uint256 unitsB) {
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (_post(lenderA, 50_000e18), _post(lenderB, 50_000e18));
        _deposit(alice, TOKEN);
        _position(bob, TOKEN_B);
        _position(carol, TOKEN_C);
        for (uint256 i; i < 3; ++i) {
            uint256 seed = uint256(keccak256(abi.encode(sizeSeed, i)));
            uint128[] memory amounts = new uint128[](2);
            amounts[0] = uint128(bound(seed, 5e18, 15_000e18));
            amounts[1] = uint128(bound(seed >> 128, 5e18, 15_000e18));
            vm.prank(borrowers[i]);
            lm.borrow(tokens[i], m1, ids, amounts, 5_000);
        }
        vm.prank(lenderA);
        unitsA = cm.claimUnits(m1);
        vm.prank(lenderB);
        unitsB = cm.claimUnits(m1);
    }

    /// @dev Ends loan `i` one of four ways: 0 repaid in full, 1 a third repaid then sold below the debt, 2 settled
    ///      in BTC, 3 written off with nothing recovered.
    function _closeLoan(uint256 i, uint256 kind) internal {
        uint256 tokenId = tokens[i];
        if (kind == 0) {
            _repay(borrowers[i], tokenId, lm.owedOf(tokenId));
        } else if (kind == 1) {
            _repay(borrowers[i], tokenId, lm.owedOf(tokenId) / 3);
            // Bitcoin falls until the collateral is worth 80% of what is left, so the sale pays less than the debt.
            (uint256 btcAmount,,) = lm.lockOf(tokenId);
            feed.setPrice(lm.owedOf(tokenId) * 8_000 * 1e18 / (BPS * btcAmount));
            lm.startAuction(tokenId);
            vm.prank(buyer);
            lm.purchase(tokenId, type(uint256).max, vm.getBlockTimestamp());
            feed.setPrice(PRICE);
        } else if (kind == 2) {
            lm.startAuction(tokenId);
            ILoanManager.Auction memory a = lm.auctionOf(tokenId);
            vm.warp(Math.max(vm.getBlockTimestamp(), Math.max(uint256(a.startTime) + a.duration, m3)) + 1);
            lm.settle(tokenId);
        } else {
            ve.forceTransfer(address(lm), thief, tokenId);
            lm.writeOff(tokenId);
        }
    }

    function _withdrawA(uint256 units) internal {
        (uint256 musdOut, uint256 btcOut) = _withdraw(lenderA, units);
        musdA += musdOut;
        btcA += btcOut;
        ++withdrawalsA;
    }

    function _withdrawInOrder(
        address[3] memory lenders,
        uint8[3] memory order,
        uint256 units,
        uint256[3] memory musdOut,
        uint256[3] memory btcOut
    ) internal {
        for (uint256 i; i < 3; ++i) {
            (uint256 m, uint256 b) = _withdraw(lenders[order[i]], units);
            musdOut[order[i]] += m;
            btcOut[order[i]] += b;
        }
    }

    /// @dev Lender A moves part of its units into a Claim right after the date and takes payouts as the three
    ///      loans close in a fuzzed order and in fuzzed ways, redeems its plain units after finalize, then tries to
    ///      be paid again. Lender B only redeems. The treasury splits its units across both paths after finalize.
    function _mixedHolderScenario(
        uint256 sizeSeed,
        uint256 kindSeed,
        uint256 orderSeed,
        uint256 splitSeed,
        uint256 pokeMask
    ) internal returns (MixedRun memory run) {
        (run.unitsA, run.unitsB) = _threeLoansFromTwoLenders(sizeSeed);
        if (cm.pendingUnits(treasury, m1) > 0) {
            vm.prank(treasury);
            run.unitsT = cm.claimUnits(m1);
        }
        vm.assume(run.unitsA >= 2);

        vm.warp(m1 + 1);
        uint256 splitA = bound(splitSeed, 1, run.unitsA - 1);
        _withdraw(lenderA, splitA);
        run.payouts = 1;
        uint256 first = orderSeed % 3;
        uint256 flip = (orderSeed / 3) % 2;
        uint256[3] memory order = [first, (first + 1 + flip) % 3, (first + 2 - flip) % 3];
        for (uint256 i; i < 3; ++i) {
            _closeLoan(order[i], (kindSeed >> (8 * order[i])) % 4);
            if ((pokeMask >> i) & 1 == 1) {
                _withdraw(lenderA, 0);
                ++run.payouts;
            }
        }
        cm.finalize(m1);

        vm.prank(lenderA);
        cm.redeem(m1, run.unitsA - splitA);
        _assertPaidOutCovered();
        _withdraw(lenderA, 0);
        run.payouts += 2;

        // Every unit A held is now burned by redeem or sits in its Claim, so neither path can pay it twice.
        bytes memory noUnits =
            abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, lenderA, 0, 1, uint256(m1));
        vm.expectRevert(noUnits);
        vm.prank(lenderA);
        cm.redeem(m1, 1);
        vm.expectRevert(noUnits);
        vm.prank(lenderA);
        cm.withdrawCollected(m1, 1);
        (uint256 againMusd, uint256 againBtc) = _withdraw(lenderA, 0);
        ++run.payouts;
        assertEq(againMusd, 0, "a Claim already paid in full pays no more MUSD");
        assertEq(againBtc, 0, "a Claim already paid in full pays no more BTC");

        vm.prank(lenderB);
        cm.redeem(m1, run.unitsB);
        _assertPaidOutCovered();
        ++run.payouts;
        if (run.unitsT > 0) {
            uint256 splitT = Math.max(run.unitsT / 2, 1);
            _withdraw(treasury, splitT);
            ++run.payouts;
            if (run.unitsT > splitT) {
                vm.prank(treasury);
                cm.redeem(m1, run.unitsT - splitT);
                _assertPaidOutCovered();
                ++run.payouts;
            }
            _withdraw(treasury, 0);
            ++run.payouts;
        }

        // Both lenders' offers took every MUSD they were minted and the treasury starts empty, so each balance is
        // the real tokens this date sent out. Any other income would break the bounds, never hide a breach.
        (run.musdA, run.btcA) = (musd.balanceOf(lenderA), btc.balanceOf(lenderA));
        (run.musdB, run.btcB) = (musd.balanceOf(lenderB), btc.balanceOf(lenderB));
        (run.musdT, run.btcT) = (musd.balanceOf(treasury), btc.balanceOf(treasury));
    }

    /// @dev Lender A's share is taken against everything the date collected, so a mixed holder is held to the same
    ///      figure whichever path paid each unit. Lender B is held to redeem's own formula.
    function _assertWithinShares(MixedRun memory run) internal view {
        ICreditMarkets.Market memory market = cm.marketOf(m1);
        uint256 shareMusd = Math.mulDiv(run.unitsA, market.collectedMusd, market.faceTotal);
        uint256 shareBtc = Math.mulDiv(run.unitsA, market.collectedBtc, market.faceTotal);
        assertLe(run.musdA, shareMusd, "A's MUSD above its share of what was collected");
        assertLe(run.btcA, shareBtc, "A's BTC above its share of what was collected");
        assertGe(run.musdA + 2, shareMusd, "A's MUSD short of its share beyond rounding");
        assertGe(run.btcA + 2, shareBtc, "A's BTC short of its share beyond rounding");

        uint256 redeemMusdB = Math.min(run.unitsB, Math.mulDiv(run.unitsB, market.musdAtFinal, market.unitsAtFinal));
        assertEq(run.musdB, redeemMusdB, "B's MUSD is what redeem pays");
        assertEq(run.btcB, Math.mulDiv(run.unitsB, market.btcAtFinal, market.unitsAtFinal), "B's BTC is redeem's");

        (uint256 paidMusd, uint256 paidBtc) = cm.paidOutOf(m1);
        assertEq(paidMusd, run.musdA + run.musdB + run.musdT, "paidOutOf matches the MUSD that left");
        assertEq(paidBtc, run.btcA + run.btcB + run.btcT, "paidOutOf matches the BTC that left");
        // Every holder has taken everything, so what stays is rounding, under one wei per payout.
        assertLe(market.collectedMusd - paidMusd, run.payouts, "MUSD locked in beyond rounding");
        assertLe(market.collectedBtc - paidBtc, run.payouts, "BTC locked in beyond rounding");
        assertEq(cm.balanceOf(lenderA, m1), 0, "A kept units");
        assertEq(cm.balanceOf(lenderB, m1), 0, "B kept units");
        assertEq(cm.balanceOf(treasury, m1), 0, "the treasury kept units");
    }

    function test_WithdrawBeforeTheDateReverts() public {
        _openLoan();
        vm.prank(lender);
        uint256 units = cm.claimUnits(m1);

        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.NotMatured.selector, m1));
        vm.prank(lender);
        cm.withdrawCollected(m1, units);
        vm.warp(m1);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.NotMatured.selector, m1));
        vm.prank(lender);
        cm.withdrawCollected(m1, units);
        assertEq(cm.balanceOf(lender, m1), units, "nothing was burned");

        vm.warp(m2 + 1);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.EmptyMarket.selector, m2));
        vm.prank(lender);
        cm.withdrawCollected(m2, 0);
    }

    function test_WithdrawPaysTheShareCollectedSoFar() public {
        uint256 units = _oneRepaidOneOpenPastTheDate();
        ICreditMarkets.Market memory market = cm.marketOf(m1);
        assertEq(market.openLoans, 1, "bob's loan is still open after the date");
        uint256 expected = Math.mulDiv(units, market.collectedMusd, market.faceTotal);
        uint256 before = musd.balanceOf(lender);

        vm.expectEmit(true, true, false, true, address(cm));
        emit ICreditMarkets.CollectedWithdrawn(lender, m1, units, expected, 0);
        (uint256 musdOut, uint256 btcOut) = _withdraw(lender, units);

        assertEq(musdOut, expected, "units x collected / faceTotal");
        assertEq(btcOut, 0);
        assertGt(expected, 0);
        assertLt(expected, units, "a share of the face, not all of it, while a loan is open");
        assertEq(musd.balanceOf(lender) - before, expected);
        assertEq(cm.balanceOf(lender, m1), 0, "the units moved into the Claim");
        ICreditMarkets.Claim memory claim = cm.claimOf(lender, m1);
        assertEq(claim.units, units);
        assertEq(claim.musdPaid, expected);
        assertEq(claim.btcPaid, 0);
        (uint256 paidMusd, uint256 paidBtc) = cm.paidOutOf(m1);
        assertEq(paidMusd, expected);
        assertEq(paidBtc, 0);
    }

    function test_WithdrawAgainPaysOnlyWhatArrivedSince() public {
        uint256 units = _oneRepaidOneOpenPastTheDate();
        (uint256 firstMusd,) = _withdraw(lender, units);

        // Bob pays part of his debt in MUSD, then the rest of his loan settles in BTC.
        vm.prank(bob);
        lm.repay(TOKEN_B, 2_000e18);
        lm.startAuction(TOKEN_B);
        vm.warp(m3 + 1);
        lm.settle(TOKEN_B);
        ICreditMarkets.Market memory market = cm.marketOf(m1);
        assertGt(market.collectedBtc, 0);
        uint256 musdDue = Math.mulDiv(units, market.collectedMusd, market.faceTotal);
        uint256 btcDue = Math.mulDiv(units, market.collectedBtc, market.faceTotal);

        (uint256 musdOut, uint256 btcOut) = _withdraw(lender, 0);
        assertEq(musdOut, musdDue - firstMusd, "only the MUSD that arrived since");
        assertEq(btcOut, btcDue, "and the BTC from the settle");
        assertEq(btc.balanceOf(lender), btcDue);

        (musdOut, btcOut) = _withdraw(lender, 0);
        assertEq(musdOut + btcOut, 0, "nothing new arrived, so nothing is paid");
    }

    /// @dev Lender A withdraws after the date at fuzzed points, moving units in pieces; lender B waits for
    ///      finalize and redeems. The three loans close in a fuzzed order and in fuzzed ways.
    function testFuzz_EarlyAndLateLendersGetTheSameTotalPerUnit(
        uint256 sizeSeed,
        uint256 kindSeed,
        uint256 orderSeed,
        uint256 withdrawMask,
        uint256 firstUnitsSeed
    ) public {
        (uint256 unitsA, uint256 unitsB) = _threeLoansFromTwoLenders(sizeSeed);
        vm.warp(m1 + 1);
        uint256 first = orderSeed % 3;
        uint256 flip = (orderSeed / 3) % 2;
        uint256[3] memory order = [first, (first + 1 + flip) % 3, (first + 2 - flip) % 3];
        for (uint256 step; step < 4; ++step) {
            if ((withdrawMask >> step) & 1 == 1) {
                uint256 held = cm.balanceOf(lenderA, m1);
                _withdrawA(withdrawalsA == 0 ? bound(firstUnitsSeed, 1, held) : held / 2);
            }
            if (step < 3) _closeLoan(order[step], (kindSeed >> (8 * order[step])) % 4);
        }
        cm.finalize(m1);
        _withdrawA(cm.balanceOf(lenderA, m1));
        vm.prank(lenderB);
        (uint256 musdB, uint256 btcB) = cm.redeem(m1, unitsB);

        ICreditMarkets.Market memory market = cm.marketOf(m1);
        uint256 slack = 2 * withdrawalsA;
        assertApproxEqAbs(musdA, Math.mulDiv(unitsA, market.collectedMusd, market.faceTotal), slack, "A's MUSD");
        assertApproxEqAbs(btcA, Math.mulDiv(unitsA, market.collectedBtc, market.faceTotal), slack, "A's BTC");
        assertApproxEqAbs(musdB, Math.mulDiv(unitsB, market.collectedMusd, market.faceTotal), 2, "B's MUSD");
        assertApproxEqAbs(btcB, Math.mulDiv(unitsB, market.collectedBtc, market.faceTotal), 2, "B's BTC");
        // Per unit, cross-multiplied so nothing is rounded away: A's total x B's units against B's total x A's.
        uint256 crossSlack = slack * unitsB + 2 * unitsA;
        assertApproxEqAbs(musdA * unitsB, musdB * unitsA, crossSlack, "same MUSD per unit early and late");
        assertApproxEqAbs(btcA * unitsB, btcB * unitsA, crossSlack, "same BTC per unit early and late");

        (uint256 paidMusd, uint256 paidBtc) = cm.paidOutOf(m1);
        assertEq(paidMusd, musdA + musdB, "paidOutOf counts both paths");
        assertEq(paidBtc, btcA + btcB);
        _assertPaidOutCovered();
    }

    function test_NoFirstMoverAdvantage() public {
        address[3] memory lenders = [lenderA, lenderB, lenderC];
        uint256[] memory ids = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            ids[i] = _post(lenders[i], 20_000e18);
        }
        _deposit(alice, TOKEN);
        _position(bob, TOKEN_B);
        vm.prank(alice);
        lm.borrow(TOKEN, m1, ids, _three(10_000e18), 5_000);
        vm.prank(bob);
        lm.borrow(TOKEN_B, m1, ids, _three(5_000e18), 5_000);
        uint256 units;
        for (uint256 i; i < 3; ++i) {
            vm.prank(lenders[i]);
            uint256 minted = cm.claimUnits(m1);
            if (i == 0) units = minted;
            assertEq(minted, units, "equal fills give equal units");
        }

        uint256[3] memory musdOut;
        uint256[3] memory btcOut;
        _repay(alice, TOKEN, lm.owedOf(TOKEN));
        vm.warp(m1 + 1);
        _withdrawInOrder(lenders, [0, 1, 2], units, musdOut, btcOut);
        vm.prank(bob);
        lm.repay(TOKEN_B, 3_000e18);
        _withdrawInOrder(lenders, [2, 0, 1], 0, musdOut, btcOut);
        lm.startAuction(TOKEN_B);
        vm.warp(m3 + 1);
        lm.settle(TOKEN_B);
        _withdrawInOrder(lenders, [1, 2, 0], 0, musdOut, btcOut);

        ICreditMarkets.Market memory market = cm.marketOf(m1);
        assertGt(btcOut[0], 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(musdOut[i], Math.mulDiv(units, market.collectedMusd, market.faceTotal), "same MUSD in any order");
            assertEq(btcOut[i], Math.mulDiv(units, market.collectedBtc, market.faceTotal), "same BTC in any order");
        }
    }

    function test_ClaimAfterFinalPaysTheRest() public {
        uint256 units = _oneRepaidOneOpenPastTheDate();
        (uint256 early,) = _withdraw(lender, units);
        _repay(bob, TOKEN_B, lm.owedOf(TOKEN_B));
        cm.finalize(m1);
        ICreditMarkets.Market memory market = cm.marketOf(m1);

        (uint256 rest,) = _withdraw(lender, 0);
        assertGt(rest, 0);
        assertEq(early + rest, Math.mulDiv(units, market.musdAtFinal, market.unitsAtFinal), "what redeem would pay");
        assertEq(early + rest, units, "every loan repaid, so one MUSD per unit");

        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, lender, 0, 1, uint256(m1))
        );
        vm.prank(lender);
        cm.redeem(m1, 1);
    }

    function test_RedeemStillWorksForPlainUnits() public {
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (_post(lenderA, 20_000e18), _post(lenderB, 20_000e18));
        uint128[] memory amounts = new uint128[](2);
        (amounts[0], amounts[1]) = (10_000e18, 5_000e18);
        _deposit(alice, TOKEN);
        vm.prank(alice);
        lm.borrow(TOKEN, m1, ids, amounts, 5_000);
        vm.prank(lenderA);
        uint256 unitsA = cm.claimUnits(m1);
        vm.prank(lenderB);
        uint256 unitsB = cm.claimUnits(m1);

        vm.warp(m1 + 1);
        (uint256 aEarly,) = _withdraw(lenderA, unitsA);
        assertEq(aEarly, 0, "nothing collected yet");
        _repay(alice, TOKEN, lm.owedOf(TOKEN));
        cm.finalize(m1);
        ICreditMarkets.Market memory market = cm.marketOf(m1);

        vm.prank(lenderB);
        (uint256 bOut,) = cm.redeem(m1, unitsB);
        assertEq(bOut, Math.mulDiv(unitsB, market.musdAtFinal, market.unitsAtFinal), "redeem's formula unchanged");
        assertEq(cm.claimOf(lenderB, m1).units, 0, "redeem never opens a Claim");
        (uint256 aRest,) = _withdraw(lenderA, 0);
        (uint256 paidMusd,) = cm.paidOutOf(m1);
        assertEq(paidMusd, bOut + aRest, "paidOutOf counts redeem too");
    }

    function test_TreasuryUnitsCanWithdrawEarlyToo() public {
        _oneRepaidOneOpenPastTheDate();
        vm.prank(treasury);
        uint256 treasuryUnits = cm.claimUnits(m1);
        ICreditMarkets.Market memory market = cm.marketOf(m1);
        uint256 before = musd.balanceOf(treasury);

        (uint256 musdOut,) = _withdraw(treasury, treasuryUnits);
        assertGt(musdOut, 0);
        assertEq(musdOut, Math.mulDiv(treasuryUnits, market.collectedMusd, market.faceTotal));
        assertEq(musd.balanceOf(treasury) - before, musdOut);
    }

    function test_WithdrawZeroWithNoClaimReverts() public {
        _openLoan();
        vm.warp(m1 + 1);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.NothingToClaim.selector, bob, m1));
        vm.prank(bob);
        cm.withdrawCollected(m1, 0);
        // Units still waiting in claimUnits are not a Claim either.
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.NothingToClaim.selector, lender, m1));
        vm.prank(lender);
        cm.withdrawCollected(m1, 0);
    }

    function testFuzz_OneHolderMixingBothPathsGetsNoMoreThanItsShare(
        uint256 sizeSeed,
        uint256 kindSeed,
        uint256 orderSeed,
        uint256 splitSeed,
        uint256 pokeMask
    ) public {
        _assertWithinShares(_mixedHolderScenario(sizeSeed, kindSeed, orderSeed, splitSeed, pokeMask));
    }

    /// @dev The BTC a settle credits lands on a Claim that was already paid out against, so it must be added to
    ///      what A is owed, not lost, and not paid twice when A redeems the rest.
    function test_MixedHolderGetsTheBtcASettleAddsAfterItsEarlyPayout() public {
        // Loans close in the order 0, 2, 1: repaid in full, settled in BTC, repaid in full. A takes a payout after
        // each closing.
        uint256 kinds = 2 << 16;
        uint256 orderSettleSecond = 3;
        vm.recordLogs();
        MixedRun memory run = _mixedHolderScenario(42, kinds, orderSettleSecond, 4_000e18, 7);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 firstPayout = type(uint256).max;
        uint256 settle;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length < 2) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == ICreditMarkets.CreditedBtc.selector) settle = i;
            if (
                topic == ICreditMarkets.CollectedWithdrawn.selector && firstPayout == type(uint256).max
                    && logs[i].topics[1] == bytes32(uint256(uint160(lenderA)))
            ) firstPayout = i;
        }
        assertLt(firstPayout, settle, "the settle credits BTC after A's first early payout");

        ICreditMarkets.Market memory market = cm.marketOf(m1);
        assertGt(market.collectedBtc, 0, "the settle credited BTC to the date");
        assertGt(run.btcA, 0, "A was paid BTC that arrived after its early payout");
        assertApproxEqAbs(run.btcA, Math.mulDiv(run.unitsA, market.collectedBtc, market.faceTotal), 2, "A's BTC");
        _assertWithinShares(run);
    }
}
