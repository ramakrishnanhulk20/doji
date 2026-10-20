// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit and fuzz tests for early payouts: once a date has passed, a lender moves units into a Claim with
// withdrawCollected and is paid its share of what that date's market has collected so far, then more as each
// remaining loan closes, without waiting for finalize. An early lender and a lender who waits for redeem end with
// the same total per unit, in MUSD and BTC, whatever the order and kind of closings and whoever withdraws first.
// Runs on the real CreditMarkets and LoanManager with the LoanFixture mocks.
// It does NOT cover: real Mezo contracts (test/fork), unit transfers between holders before a withdrawal,
// fee-on-transfer tokens, or randomised sequences across dates (CreditInvariants.t.sol).

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
}
