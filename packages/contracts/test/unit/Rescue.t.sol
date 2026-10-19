// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit tests for the owner's rescue paths and the CreditMarkets metadata. LoanManager.rescueToken may only move
// MUSD and BTC above what claimable holders are owed and refuses veBTC; rescuePosition only moves a veBTC that
// never became a position (C28, C1, C18). CreditMarkets.rescueToken refuses MUSD and BTC outright; setURI and the
// constructor URI; MarketFinalized carries btcAtFinal. Runs on the real contracts with mocks for veBTC,
// PriceFeed, the fee distributor, MUSD and BTC.
// It does NOT cover: rescue of real Mezo tokens on a fork, or a compromised owner key beyond these bounds (a
// stated non-goal in the threat model).

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CreditMarkets} from "../../src/CreditMarkets.sol";
import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";
import {MockToken} from "../utils/MockToken.sol";

contract RescueTest is LoanFixture {
    uint256 internal constant TOKEN_C = 9;
    uint256 internal constant STRAY_ID = 99;

    address internal rescuer = makeAddr("rescuer");

    /// @dev Alice gets a MUSD claimable from an auction surplus and bob a BTC claimable from an expired-lock fee
    ///      claim, so LoanManager holds money that belongs to them.
    function _makeClaimables() internal returns (uint256 musdOwed, uint256 btcOwed) {
        _openLoan();
        _makeUnsafe(TOKEN);
        lm.startAuction(TOKEN);
        vm.warp(vm.getBlockTimestamp() + DURATION / 3);
        vm.prank(buyer);
        lm.purchase(TOKEN, type(uint256).max, vm.getBlockTimestamp());

        ve.mint(bob, TOKEN_C, LOCK_BTC, m1, false);
        _deposit(bob, TOKEN_C);
        vm.warp(m1 + 1);
        dist.setClaimable(TOKEN_C, 0.05e18);
        vm.prank(bob);
        lm.claimRebase(TOKEN_C);

        musdOwed = lm.claimableMusd(alice);
        btcOwed = lm.claimableBtc(bob);
        assertGt(musdOwed, 0);
        assertGt(btcOwed, 0);
        assertEq(musd.balanceOf(address(lm)), musdOwed);
        assertEq(btc.balanceOf(address(lm)), btcOwed);
    }

    function test_C28_RescueTokenTakesOnlyMusdAboveTheClaimables() public {
        (uint256 musdOwed,) = _makeClaimables();
        musd.mint(address(lm), 100e18);

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.Rescued(address(musd), rescuer, 100e18);
        vm.prank(owner);
        lm.rescueToken(address(musd), rescuer, 100e18);
        assertEq(musd.balanceOf(rescuer), 100e18);

        vm.expectRevert(abi.encodeWithSelector(ILoanManager.RescueExceedsSurplus.selector, address(musd), 1, 0));
        vm.prank(owner);
        lm.rescueToken(address(musd), rescuer, 1);

        vm.prank(alice);
        (uint256 musdOut,) = lm.claim();
        assertEq(musdOut, musdOwed, "the claimable is still whole");
    }

    function test_C28_RescueTokenTakesOnlyBtcAboveTheClaimables() public {
        (, uint256 btcOwed) = _makeClaimables();
        btc.mint(address(lm), 2e18);

        vm.expectRevert(
            abi.encodeWithSelector(ILoanManager.RescueExceedsSurplus.selector, address(btc), 2e18 + 1, 2e18)
        );
        vm.prank(owner);
        lm.rescueToken(address(btc), rescuer, 2e18 + 1);
        vm.prank(owner);
        lm.rescueToken(address(btc), rescuer, 2e18);
        assertEq(btc.balanceOf(rescuer), 2e18);
        assertEq(btc.balanceOf(address(lm)), btcOwed);

        vm.prank(bob);
        (, uint256 btcOut) = lm.claim();
        assertEq(btcOut, btcOwed, "the claimable is still whole");
    }

    function test_C28_NothingStrayMeansNothingToRescue() public {
        (uint256 musdOwed, uint256 btcOwed) = _makeClaimables();
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.RescueExceedsSurplus.selector, address(musd), 1, 0));
        lm.rescueToken(address(musd), rescuer, 1);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.RescueExceedsSurplus.selector, address(btc), 1, 0));
        lm.rescueToken(address(btc), rescuer, 1);
        vm.stopPrank();
        assertEq(lm.totalClaimableMusd(), musdOwed);
        assertEq(lm.totalClaimableBtc(), btcOwed);
    }

    function test_RescueToken_OtherTokensMoveFreely() public {
        MockToken stray = new MockToken("STRAY");
        stray.mint(address(lm), 5e18);
        vm.prank(owner);
        lm.rescueToken(address(stray), rescuer, 5e18);
        assertEq(stray.balanceOf(rescuer), 5e18);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.RescueExceedsSurplus.selector, address(stray), 1, 0));
        vm.prank(owner);
        lm.rescueToken(address(stray), rescuer, 1);
    }

    function test_RescueToken_RefusesVeBTC() public {
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.TokenNotRescuable.selector, address(ve)));
        vm.prank(owner);
        lm.rescueToken(address(ve), rescuer, 1);
    }

    function test_RevertWhen_RescueTokenNotOwnerOrBadInput() public {
        MockToken stray = new MockToken("STRAY");
        stray.mint(address(lm), 5e18);
        address[2] memory others = [guardian, bob];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, others[i]));
            vm.prank(others[i]);
            lm.rescueToken(address(stray), others[i], 1);
        }
        vm.startPrank(owner);
        vm.expectRevert(ILoanManager.ZeroAddress.selector);
        lm.rescueToken(address(stray), address(0), 1);
        vm.expectRevert(ILoanManager.ZeroAmount.selector);
        lm.rescueToken(address(stray), rescuer, 0);
        vm.stopPrank();
    }

    function test_C1_RescuePositionSendsAStrayNft() public {
        ve.mint(bob, STRAY_ID, LOCK_BTC, m2, false);
        vm.prank(bob);
        ve.transferFrom(bob, address(lm), STRAY_ID);

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.PositionRescued(STRAY_ID, bob);
        vm.prank(owner);
        lm.rescuePosition(STRAY_ID, bob);
        assertEq(ve.ownerOf(STRAY_ID), bob);
    }

    function test_C28_RescuePositionRefusesARecordedPosition() public {
        _deposit(alice, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.PositionExists.selector, TOKEN));
        vm.prank(owner);
        lm.rescuePosition(TOKEN, owner);

        (uint256[] memory ids, uint128[] memory amounts) = _one(offerM1, PRINCIPAL);
        vm.prank(alice);
        lm.borrow(TOKEN, m1, ids, amounts, 5_000);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.PositionExists.selector, TOKEN));
        vm.prank(owner);
        lm.rescuePosition(TOKEN, owner);

        _makeUnsafe(TOKEN);
        lm.startAuction(TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.PositionExists.selector, TOKEN));
        vm.prank(owner);
        lm.rescuePosition(TOKEN, owner);
        assertEq(ve.ownerOf(TOKEN), address(lm));
    }

    function test_RevertWhen_RescuePositionNotHeldOrNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotInCustody.selector, TOKEN));
        vm.prank(owner);
        lm.rescuePosition(TOKEN, owner);

        ve.mint(bob, STRAY_ID, LOCK_BTC, m2, false);
        vm.prank(bob);
        ve.transferFrom(bob, address(lm), STRAY_ID);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        lm.rescuePosition(STRAY_ID, bob);
        vm.expectRevert(ILoanManager.ZeroAddress.selector);
        vm.prank(owner);
        lm.rescuePosition(STRAY_ID, address(0));
    }

    function test_CreditMarketsRescueTokenRefusesMusdAndBtc() public {
        musd.mint(address(cm), 1e18);
        btc.mint(address(cm), 1e18);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.TokenNotRescuable.selector, address(musd)));
        cm.rescueToken(address(musd), rescuer, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.TokenNotRescuable.selector, address(btc)));
        cm.rescueToken(address(btc), rescuer, 1e18);

        MockToken stray = new MockToken("STRAY");
        stray.mint(address(cm), 3e18);
        vm.expectEmit(true, true, false, true, address(cm));
        emit ICreditMarkets.Rescued(address(stray), rescuer, 3e18);
        cm.rescueToken(address(stray), rescuer, 3e18);
        assertEq(stray.balanceOf(rescuer), 3e18);

        vm.expectRevert(ICreditMarkets.ZeroAddress.selector);
        cm.rescueToken(address(stray), address(0), 1);
        vm.expectRevert(ICreditMarkets.ZeroAmount.selector);
        cm.rescueToken(address(stray), rescuer, 0);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vm.prank(guardian);
        cm.rescueToken(address(stray), guardian, 1);
    }

    function test_SetURI_OwnerOnlyAndEmits() public {
        string memory newUri = "https://doji.example/units/{id}.json";
        vm.expectEmit(address(cm));
        emit ICreditMarkets.UriSet(newUri);
        vm.prank(owner);
        cm.setURI(newUri);
        assertEq(cm.uri(m1), newUri);
        assertEq(cm.uri(m2), newUri, "one template for every maturity");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vm.prank(guardian);
        cm.setURI("");
    }

    function test_Constructor_SetsTheUri() public {
        string memory initial = "ipfs://doji-units/{id}.json";
        vm.recordLogs();
        CreditMarkets markets = new CreditMarkets(
            address(musd), address(btc), makeAddr("someManager"), owner, guardian, treasury, FEE_SHARE, 10e18, uint32(WEEK), initial
        );
        assertEq(markets.uri(m1), initial);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(markets) && logs[i].topics[0] == ICreditMarkets.UriSet.selector) {
                assertEq(abi.decode(logs[i].data, (string)), initial);
                seen = true;
            }
        }
        assertTrue(seen, "UriSet emitted at construction");
        assertEq(cm.uri(m1), "", "the fixture's markets start with an empty URI");
    }

    function test_MarketFinalized_CarriesBtcAtFinal() public {
        _openLoan();
        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
        vm.warp(m3 + 1);
        lm.settle(TOKEN);
        ICreditMarkets.Market memory market = cm.marketOf(m1);
        assertGt(market.collectedBtc, 0);

        vm.expectEmit(true, false, false, true, address(cm));
        emit ICreditMarkets.MarketFinalized(m1, market.faceTotal, 0, market.collectedBtc);
        cm.finalize(m1);
    }
}
