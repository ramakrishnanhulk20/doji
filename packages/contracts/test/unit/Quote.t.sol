// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit and fuzz tests for the Quote library alone. It does NOT cover: how CreditMarkets feeds it (seconds to
// maturity, the live fee share) or how the face is stored on a loan; those are in CreditMarkets.t.sol and
// LoanManager.t.sol. Inputs above the fuzz ranges (APR over 50%, terms over 12 weeks) are not explored.

import {Test} from "forge-std/Test.sol";
import {Quote} from "../../src/libraries/Quote.sol";

contract QuoteTest is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;

    function quoteExternal(uint256 principal, uint256 aprBps, uint256 secondsToMaturity, uint256 feeShareBps)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return Quote.quote(principal, aprBps, secondsToMaturity, feeShareBps);
    }

    function test_KnownValue() public pure {
        (uint256 face, uint256 makerUnits, uint256 treasuryUnits) = Quote.quote(1_000e18, 1_000, YEAR, 1_000);
        assertEq(face, 1_100e18);
        assertEq(treasuryUnits, 10e18);
        assertEq(makerUnits, 1_090e18);
    }

    function test_InterestRoundsUp() public pure {
        (uint256 face,,) = Quote.quote(1e18, 1, 1, 0);
        // 1e18 / (10_000 * 31_536_000) = 3_170_979.19..., so the lender gets the extra wei.
        assertEq(face - 1e18, 3_170_980);
    }

    function test_ZeroAprOwesPrincipalOnly() public pure {
        (uint256 face, uint256 makerUnits, uint256 treasuryUnits) = Quote.quote(500e18, 0, 2 weeks, 2_000);
        assertEq(face, 500e18);
        assertEq(makerUnits, 500e18);
        assertEq(treasuryUnits, 0);
    }

    function test_ZeroFeeShareGivesMakerEverything() public pure {
        (uint256 face, uint256 makerUnits, uint256 treasuryUnits) = Quote.quote(500e18, 700, 3 weeks, 0);
        assertEq(makerUnits, face);
        assertEq(treasuryUnits, 0);
    }

    function test_RevertWhen_FeeShareAboveFull() public {
        vm.expectRevert(abi.encodeWithSelector(Quote.FeeShareAboveFull.selector, BPS + 1));
        this.quoteExternal(1e18, 100, 1 weeks, BPS + 1);
    }

    function testFuzz_UnitsEqualFace(uint256 principal, uint256 aprBps, uint256 secondsToMaturity, uint256 feeShareBps)
        public
        pure
    {
        principal = bound(principal, 1e18, 1e24);
        aprBps = bound(aprBps, 0, 5_000);
        secondsToMaturity = bound(secondsToMaturity, 1, 12 weeks);
        feeShareBps = bound(feeShareBps, 0, 2_000);

        (uint256 face, uint256 makerUnits, uint256 treasuryUnits) =
            Quote.quote(principal, aprBps, secondsToMaturity, feeShareBps);

        assertEq(makerUnits + treasuryUnits, face, "units must equal face");
        assertGe(face, principal, "face below principal");
        uint256 interest = face - principal;
        uint256 exact = principal * aprBps * secondsToMaturity;
        assertGe(interest * BPS * YEAR, exact, "interest rounded down");
        if (interest > 0) assertLt((interest - 1) * BPS * YEAR, exact, "interest more than one wei high");
        assertLe(treasuryUnits, interest * feeShareBps / BPS, "treasury above its share");
        assertGe(makerUnits, principal, "maker below principal");
    }
}
