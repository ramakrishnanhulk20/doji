// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Audit finding L-02. The guardian's pause is the only response C19 gives to a Mezo change that breaks
// valuation ("pause new risk and launch a new deployment"). It stops borrow and lockAndBorrow, but roll is never
// paused and roll pays out any principal above the old debt. So while paused, every open loan can still take on
// fresh debt up to maxLTV at the current, possibly wrong, value. The test stands in for such a change by doubling
// what locked() reports, pauses, shows a new borrow is refused, then shows a roll cashes out against the same
// inflated value. It fails on today's code.
// It does NOT cover: a roll that only refinances the old debt or adds a top-up, which the pause should keep
// allowing (C19's reason for never pausing roll).

import {console} from "forge-std/Test.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";

contract RollCashOutWhilePausedTest is LoanFixture {
    uint256 internal constant TOKEN_B = 8;

    function test_L02_RollTakesNewDebtWhileBorrowsArePaused() public {
        _openLoan();
        uint256 owedBefore = lm.owedOf(TOKEN);

        // A veBTC change makes locked() report twice the real BTC for both positions; the guardian pauses.
        ve.setLock(TOKEN, 2e18, m3, false);
        ve.mint(bob, TOKEN_B, 2e18, m3, false);
        _deposit(bob, TOKEN_B);
        vm.prank(guardian);
        lm.setBorrowsPaused(true);

        (uint256[] memory ids, uint128[] memory amounts) = _one(offerM2, 60_000e18);
        vm.prank(bob);
        vm.expectRevert(ILoanManager.BorrowsPaused.selector);
        lm.borrow(TOKEN_B, m2, ids, amounts, 5_000);

        uint256 aliceBefore = musd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(ILoanManager.BorrowsPaused.selector);
        lm.roll(TOKEN, m2, ids, amounts, 5_000, 0);
        uint256 cashedOut = musd.balanceOf(alice) - aliceBefore;

        console.log("debt before the pause (MUSD wei)", owedBefore);
        console.log("debt after a roll while paused  ", lm.owedOf(TOKEN));
        console.log("MUSD paid out while paused      ", cashedOut);

        assertEq(cashedOut, 0, "C19: new MUSD left the protocol while borrows were paused");
        assertLe(lm.owedOf(TOKEN), owedBefore, "C19: debt grew while borrows were paused");
    }
}
