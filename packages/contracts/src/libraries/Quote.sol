// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Quote
/// @notice The single pricing function for a fill. The debt LoanManager records and the units
///         CreditMarkets records both come out of this one call, so they can never drift apart.
library Quote {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;

    error FeeShareAboveFull(uint256 feeShareBps);

    /// @notice Prices one fill: what the borrower owes at maturity and how it splits into credit units.
    /// @dev Simple interest per second, rounded up so the lender never earns below the stated rate. The
    ///      treasury's share of the interest is rounded down and the maker takes the rest, so
    ///      makerUnits + treasuryUnits == face exactly. Reverts FeeShareAboveFull above 10,000.
    /// @param principal MUSD lent, 18 decimals.
    /// @param aprBps Yearly rate in basis points.
    /// @param secondsToMaturity Seconds from now until maturity.
    /// @param feeShareBps Treasury's share of the interest in basis points.
    /// @return face Principal plus interest.
    /// @return makerUnits Units owed to the lender.
    /// @return treasuryUnits Units owed to the treasury.
    function quote(uint256 principal, uint256 aprBps, uint256 secondsToMaturity, uint256 feeShareBps)
        internal
        pure
        returns (uint256 face, uint256 makerUnits, uint256 treasuryUnits)
    {
        // Fill calls this inside its capped loop; the guard only fires on a caller bug, never per offer.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (feeShareBps > BPS) revert FeeShareAboveFull(feeShareBps);
        uint256 interest = Math.mulDiv(principal, aprBps * secondsToMaturity, BPS * YEAR, Math.Rounding.Ceil);
        face = principal + interest;
        treasuryUnits = (interest * feeShareBps) / BPS;
        makerUnits = face - treasuryUnits;
    }
}
