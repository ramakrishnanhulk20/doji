// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Invariant tests: UnitMarketHandler drives random sequences of listings, buys, cancels, after-expiry returns, time
// moves, fee changes, pauses and fee claims across two maturities and three holders, on real units from the
// LoanFixture contracts. After every call: for each maturity, the units UnitMarket holds equal the units left on
// its open listings (C43); MUSD held equals the fees owed, and fees owed plus fees claimed equal what every buy
// should have charged by the C45 rounding (C45, C46); no listing field except unitsLeft ever changes and ids are
// never reused (C44); every buy moved exactly its cost and units (C45); and no seller's cancel of an open listing,
// and no return after expiry, ever reverted (C46).
// It does NOT cover: re-entering buyers, look-alike ERC-1155 contracts, batch or malformed arrivals and rescue
// (UnitMarket.t.sol), MUSD or units sent to UnitMarket unasked, real Mezo contracts (test/fork), or listings past
// the units' maturity while a market resolves.

import {console} from "forge-std/Test.sol";
import {UnitMarket} from "../../src/UnitMarket.sol";
import {IUnitMarket} from "../../src/interfaces/IUnitMarket.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";
import {UnitMarketHandler} from "../utils/UnitMarketHandler.sol";

contract UnitMarketInvariantsTest is LoanFixture {
    uint256 internal constant TOKEN_B = 8;

    UnitMarket internal um;
    UnitMarketHandler internal handler;
    address[3] internal actors;

    /// @dev Two loans give the lender real units at m1 and m2, which it splits with two other holders, so every
    ///      holder can list, buy and relist at both maturities.
    function setUp() public override {
        super.setUp();
        um = new UnitMarket(address(cm), owner, guardian, treasury, 25);

        _openLoan();
        ve.mint(bob, TOKEN_B, LOCK_BTC, m3, false);
        _deposit(bob, TOKEN_B);
        _borrow(bob, TOKEN_B, m2, offerM2, 20_000e18);
        vm.startPrank(lender);
        uint256 unitsM1 = cm.claimUnits(m1);
        uint256 unitsM2 = cm.claimUnits(m2);
        vm.stopPrank();

        actors = [lender, makeAddr("holder1"), makeAddr("holder2")];
        for (uint256 i; i < 3; ++i) {
            if (i != 0) {
                vm.startPrank(lender);
                cm.safeTransferFrom(lender, actors[i], m1, unitsM1 / 3, "");
                cm.safeTransferFrom(lender, actors[i], m2, unitsM2 / 3, "");
                vm.stopPrank();
                musd.mint(actors[i], 1_000_000e18);
            }
            vm.prank(actors[i]);
            musd.approve(address(um), type(uint256).max);
        }

        handler = new UnitMarketHandler(
            UnitMarketHandler.Wiring({
                um: um, cm: cm, musd: musd, owner: owner, guardian: guardian, treasury: treasury
            }),
            actors,
            [m1, m2]
        );

        // Duplicates weight listing and buying, so a 64-call run builds a book and trades against it.
        bytes4[12] memory actions = [
            UnitMarketHandler.list.selector,
            UnitMarketHandler.list.selector,
            UnitMarketHandler.list.selector,
            UnitMarketHandler.buy.selector,
            UnitMarketHandler.buy.selector,
            UnitMarketHandler.buy.selector,
            UnitMarketHandler.cancel.selector,
            UnitMarketHandler.returnExpired.selector,
            UnitMarketHandler.warp.selector,
            UnitMarketHandler.setFeeBps.selector,
            UnitMarketHandler.setPaused.selector,
            UnitMarketHandler.claimFees.selector
        ];
        bytes4[] memory selectors = new bytes4[](actions.length);
        for (uint256 i; i < actions.length; ++i) {
            selectors[i] = actions[i];
        }
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_C43_UnitsHeldEqualOpenListings() public view {
        for (uint256 m; m < 2; ++m) {
            uint64 maturity = handler.maturities(m);
            uint256 open;
            for (uint256 i; i < handler.listingCount(); ++i) {
                IUnitMarket.Listing memory l = um.listingOf(handler.listingIds(i));
                if (l.maturity == maturity) open += l.unitsLeft;
            }
            assertEq(cm.balanceOf(address(um), maturity), open, "C43: units held differ from open listings");
        }
    }

    function invariant_C46_MusdHeldEqualsFeesOwed() public view {
        assertEq(musd.balanceOf(address(um)), um.treasuryOwed(), "C46: MUSD held differs from fees owed");
        assertEq(
            um.treasuryOwed() + handler.feesClaimed(), handler.feesDue(), "C45: fees differ from the cost rounding"
        );
    }

    function invariant_C44_OnlyUnitsLeftEverChanges() public view {
        uint256 count = handler.listingCount();
        assertEq(um.nextListingId(), count + 1, "C44: listing ids skipped or reused");
        for (uint256 i; i < count; ++i) {
            uint256 id = handler.listingIds(i);
            assertEq(id, i + 1, "C44: listing ids skipped or reused");
            IUnitMarket.Listing memory l = um.listingOf(id);
            UnitMarketHandler.Terms memory t = handler.termsOf(id);
            assertEq(l.seller, t.seller, "C44: seller changed");
            assertEq(l.maturity, t.maturity, "C44: maturity changed");
            assertEq(l.expiry, t.expiry, "C44: expiry changed");
            assertEq(l.feeBps, t.feeBps, "C44: fee rate changed");
            assertEq(l.pricePerUnit, t.pricePerUnit, "C44: price changed");
            assertEq(l.unitsLeft, handler.unitsLeftGhost(id), "C45: units left differ from fills");
        }
    }

    function invariant_C45_BuysExactAndC46_ExitsNeverBlocked() public view {
        assertFalse(handler.badBuy(), "C45: a buy moved the wrong cost, fee or units");
        assertFalse(handler.exitBlocked(), "C46: a cancel or an after-expiry return reverted");
    }

    /// @dev Prints how often each action succeeded across every run so far, so a green result can be checked for
    ///      real coverage (run with -vv; the last run's print holds the campaign's totals). Every run starts again
    ///      from setUp's state, so the running totals are carried between runs in the process environment.
    function afterInvariant() external {
        string[8] memory names =
            ["list", "buy", "cancel", "returnExpired", "warp", "setFeeBps", "setPaused", "claimFees"];
        for (uint256 i; i < names.length; ++i) {
            console.log(names[i], _carry(names[i], handler.successes(bytes32(bytes(names[i])))));
        }
    }

    function _carry(string memory name, uint256 thisRun) internal returns (uint256 total) {
        string memory key = string.concat("DOJI_UNITMARKET_TOTAL_", name);
        total = vm.envOr(key, uint256(0)) + thisRun;
        vm.setEnv(key, vm.toString(total));
    }
}
