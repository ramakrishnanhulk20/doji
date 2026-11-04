// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit and fuzz tests for parked offers: a lender's waiting MUSD sits in the sMUSD vault, a fill or cancel takes
// exactly the principal back out, a vault that pays or mints short is refused, a broken vault stops only parked
// paths, and sMUSD can neither be rescued nor slipped in as principal (threat model C30, C34, C35, C33). Runs on
// the real CreditMarkets and LoanManager with MockSavingsVault standing in for Mezo's MUSDSavingsRate.
// It does NOT cover: booking or paying yield per offer, or the guardian's stop-parking and pull-out controls
// (both come with the next work order; until then any yield stays in CreditMarkets credited to nobody); the real
// vault or a real position (test/fork/SavingsFork.t.sol); a roll that takes a parked offer, which runs the same
// fill path but is not exercised here; or a vault whose yield index falls.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditMarkets} from "../../src/CreditMarkets.sol";
import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {IMUSDSavingsRate} from "../../src/interfaces/IMUSDSavingsRate.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";
import {MockMUSD} from "../utils/MockMUSD.sol";
import {MockSavingsVault} from "../utils/MockSavingsVault.sol";

contract ParkedOffersTest is LoanFixture {
    uint128 internal constant PARKED = 50_000e18;
    uint256 internal constant FUZZ_STEPS = 20;

    address internal donor = makeAddr("donor");
    address internal stranger = makeAddr("stranger");

    struct Balances {
        uint256 alice;
        uint256 lender;
        uint256 cmMusd;
        uint256 cmShares;
        uint256 vaultMusd;
        uint256 parked;
    }

    function setUp() public override {
        super.setUp();
        address[2] memory payers = [donor, stranger];
        for (uint256 i; i < payers.length; ++i) {
            musd.mint(payers[i], 1_000_000e18);
            vm.prank(payers[i]);
            musd.approve(address(vault), type(uint256).max);
        }
    }

    /// @dev External so a constructor revert under vm.expectRevert is caught from a real call.
    function newMarkets(address vault_) external returns (CreditMarkets) {
        return new CreditMarkets(
            address(musd),
            address(btc),
            makeAddr("someManager"),
            owner,
            guardian,
            treasury,
            FEE_SHARE,
            10e18,
            uint32(WEEK),
            "",
            vault_
        );
    }

    function _postParked(uint64 maturity, uint128 amount) internal returns (uint256 id) {
        vm.prank(lender);
        id = cm.postParkedOffer(maturity, APR, amount);
    }

    function _balances() internal view returns (Balances memory b) {
        b.alice = musd.balanceOf(alice);
        b.lender = musd.balanceOf(lender);
        b.cmMusd = musd.balanceOf(address(cm));
        b.cmShares = vault.balanceOf(address(cm));
        b.vaultMusd = musd.balanceOf(address(vault));
        b.parked = cm.parkedPrincipal();
    }

    function _two(uint256 idA, uint128 amountA, uint256 idB, uint128 amountB)
        internal
        pure
        returns (uint256[] memory ids, uint128[] memory amounts)
    {
        ids = new uint256[](2);
        amounts = new uint128[](2);
        (ids[0], ids[1]) = (idA, idB);
        (amounts[0], amounts[1]) = (amountA, amountB);
    }

    function test_RevertWhen_ConstructorVaultZeroOrWrongToken() public {
        assertEq(cm.savingsVault(), address(vault));
        assertEq(cm.parkedPrincipal(), 0);

        vm.expectRevert(ICreditMarkets.ZeroAddress.selector);
        this.newMarkets(address(0));

        MockMUSD otherMusd = new MockMUSD();
        MockSavingsVault otherVault = new MockSavingsVault(address(otherMusd));
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.VaultTokenMismatch.selector, address(otherMusd)));
        this.newMarkets(address(otherVault));

        vm.expectRevert();
        this.newMarkets(makeAddr("noCode"));
    }

    function test_C34_ParkedPostMovesExactlyTheAmountIntoTheVault() public {
        Balances memory before = _balances();
        uint256 id = cm.nextOfferId();

        vm.expectCall(address(musd), abi.encodeCall(IERC20.approve, (address(vault), uint256(PARKED))), 1);
        vm.expectCall(address(vault), abi.encodeCall(IMUSDSavingsRate.deposit, (uint256(PARKED))), 1);
        vm.expectCall(address(musd), abi.encodeCall(IERC20.approve, (address(vault), uint256(0))), 1);
        vm.expectEmit(true, true, true, true, address(cm));
        emit ICreditMarkets.OfferPosted(id, lender, m1, APR, PARKED);
        vm.expectEmit(true, false, false, true, address(cm));
        emit ICreditMarkets.OfferParked(id, PARKED);
        assertEq(_postParked(m1, PARKED), id);

        assertEq(vault.balanceOf(address(cm)) - before.cmShares, PARKED, "sMUSD rose by exactly the amount");
        assertEq(musd.balanceOf(address(vault)) - before.vaultMusd, PARKED);
        assertEq(musd.balanceOf(address(cm)), before.cmMusd, "the MUSD went straight on to the vault");
        assertEq(before.lender - musd.balanceOf(lender), PARKED);
        assertEq(musd.allowance(address(cm), address(vault)), 0, "no allowance outlives the call");
        assertEq(cm.parkedPrincipal(), PARKED);
        ICreditMarkets.Offer memory offer = cm.offerOf(id);
        assertTrue(offer.parked);
        assertEq(offer.maker, lender);
        assertEq(offer.maturity, m1);
        assertEq(offer.aprBps, APR);
        assertEq(offer.remaining, PARKED);
        assertFalse(cm.offerOf(offerM1).parked, "a plain offer is not parked");
    }

    function test_C30_FillFromAParkedOfferPaysExactlyThePrincipal() public {
        uint256 id = _postParked(m1, PARKED);
        _deposit(alice, TOKEN);
        Balances memory before = _balances();

        vm.expectCall(address(vault), abi.encodeCall(IMUSDSavingsRate.withdraw, (uint256(PRINCIPAL))), 1);
        (uint256 principal,) = _borrow(alice, TOKEN, m1, id, PRINCIPAL);

        assertEq(principal, PRINCIPAL);
        assertEq(musd.balanceOf(alice) - before.alice, PRINCIPAL, "the borrower got exactly the principal");
        assertEq(before.cmShares - vault.balanceOf(address(cm)), PRINCIPAL, "sMUSD fell by exactly the principal");
        assertEq(musd.balanceOf(address(cm)), before.cmMusd, "no plain escrow or collected MUSD was used");
        assertEq(cm.parkedPrincipal(), PARKED - PRINCIPAL);
        assertEq(cm.offerOf(id).remaining, PARKED - PRINCIPAL);
    }

    function test_C30_MixedFillWithdrawsOnlyTheParkedPart() public {
        uint256 id = _postParked(m1, PARKED);
        _deposit(alice, TOKEN);
        Balances memory before = _balances();
        (uint256[] memory ids, uint128[] memory amounts) = _two(id, 12_000e18, offerM1, 8_000e18);

        vm.expectCall(address(vault), abi.encodeCall(IMUSDSavingsRate.withdraw, (uint256(12_000e18))), 1);
        vm.prank(alice);
        (uint256 principal,) = lm.borrow(TOKEN, m1, ids, amounts, 5_000);

        assertEq(principal, 20_000e18);
        assertEq(musd.balanceOf(alice) - before.alice, 20_000e18);
        assertEq(before.cmShares - vault.balanceOf(address(cm)), 12_000e18, "only the parked part left the vault");
        assertEq(before.cmMusd - musd.balanceOf(address(cm)), 8_000e18, "the plain part came from plain escrow");
        assertEq(cm.parkedPrincipal(), PARKED - 12_000e18);
        assertEq(cm.offerOf(id).remaining, PARKED - 12_000e18);
        assertEq(cm.offerOf(offerM1).remaining, OFFER - 8_000e18);
    }

    function test_C30_CancelOfAParkedOfferReturnsExactlyTheRemaining() public {
        uint256 id = _postParked(m1, PARKED);
        _deposit(alice, TOKEN);
        _borrow(alice, TOKEN, m1, id, PRINCIPAL);
        Balances memory before = _balances();
        uint128 left = PARKED - PRINCIPAL;

        vm.expectEmit(true, true, false, true, address(cm));
        emit ICreditMarkets.OfferCancelled(id, lender, left);
        vm.prank(lender);
        cm.cancelOffer(id);

        assertEq(musd.balanceOf(lender) - before.lender, left, "the maker got exactly the remaining");
        assertEq(vault.balanceOf(address(cm)), 0);
        assertEq(cm.parkedPrincipal(), 0);
        assertEq(cm.offerOf(id).remaining, 0);
        assertEq(musd.balanceOf(address(cm)), before.cmMusd);
    }

    function test_C30_YieldDeliveredWithAWithdrawStaysInCreditMarkets() public {
        uint256 id = _postParked(m1, PARKED);
        _deposit(alice, TOKEN);
        vm.prank(donor);
        vault.receiveProtocolYield(1_000e18);
        assertEq(cm.parkedPrincipal(), PARKED, "a yield payment changes no principal");
        uint256 firstLump = vault.accruedYield(address(cm));
        assertGt(firstLump, 0);
        Balances memory before = _balances();

        _borrow(alice, TOKEN, m1, id, PRINCIPAL);
        assertEq(musd.balanceOf(alice) - before.alice, PRINCIPAL, "the borrower never gets the yield");
        assertEq(musd.balanceOf(address(cm)) - before.cmMusd, firstLump, "the yield stayed in CreditMarkets");
        assertEq(cm.parkedPrincipal(), PARKED - PRINCIPAL);

        vm.prank(donor);
        vault.receiveProtocolYield(500e18);
        uint256 secondLump = vault.accruedYield(address(cm));
        uint256 lenderBefore = musd.balanceOf(lender);
        vm.prank(lender);
        cm.cancelOffer(id);
        assertEq(musd.balanceOf(lender) - lenderBefore, PARKED - PRINCIPAL, "the maker never gets the yield yet");
        assertEq(musd.balanceOf(address(cm)) - before.cmMusd, firstLump + secondLump, "both lumps credited to nobody");
        assertEq(cm.parkedPrincipal(), 0);
        assertEq(cm.offerOf(offerM2).remaining, OFFER, "no plain offer gained anything");
        assertEq(cm.marketOf(m1).collectedMusd, 0, "no market gained anything");
    }

    function test_C30_ShortPayRevertsFillAndCancelAndMovesNothing() public {
        uint256 id = _postParked(m1, PARKED);
        _deposit(alice, TOKEN);
        vault.shortPayBy(1);
        Balances memory before = _balances();

        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.VaultShortfall.selector, PRINCIPAL, PRINCIPAL - 1));
        _borrow(alice, TOKEN, m1, id, PRINCIPAL);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.VaultShortfall.selector, PARKED, PARKED - 1));
        vm.prank(lender);
        cm.cancelOffer(id);

        Balances memory afterB = _balances();
        assertEq(abi.encode(afterB), abi.encode(before), "no balance moved");
        assertEq(cm.offerOf(id).remaining, PARKED);
        assertEq(cm.marketOf(m1).openLoans, 0);
        assertEq(cm.marketOf(m1).faceTotal, 0);
        assertEq(uint8(lm.loanOf(TOKEN).state), uint8(ILoanManager.LoanState.None));
    }

    function test_C30_MintShortMakesAParkedPostRevert() public {
        vault.mintLessBy(1);
        Balances memory before = _balances();
        uint256 nextId = cm.nextOfferId();

        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.VaultShortfall.selector, PARKED, PARKED - 1));
        _postParked(m1, PARKED);

        Balances memory afterB = _balances();
        assertEq(abi.encode(afterB), abi.encode(before), "no balance moved");
        assertEq(cm.nextOfferId(), nextId, "no offer was recorded");
    }

    function test_C35_BrokenVaultStopsOnlyParkedPaths() public {
        uint256 id = _postParked(m1, PARKED);
        _deposit(alice, TOKEN);
        vault.revertOnWithdraw(true);
        vault.revertOnDeposit(true);

        vm.expectRevert(MockSavingsVault.WithdrawRefused.selector);
        _borrow(alice, TOKEN, m1, id, PRINCIPAL);
        vm.expectRevert(MockSavingsVault.WithdrawRefused.selector);
        vm.prank(lender);
        cm.cancelOffer(id);
        vm.expectRevert(MockSavingsVault.DepositRefused.selector);
        _postParked(m1, PARKED);

        assertEq(vault.balanceOf(address(cm)), PARKED);
        // From here to the end of the test nothing may call the vault, this test included.
        vm.expectCall(address(vault), bytes(""), 0);
        vm.prank(lender);
        uint256 plainId = cm.postOffer(m1, APR, 1_000e18);
        uint256 lenderBefore = musd.balanceOf(lender);
        vm.prank(lender);
        cm.cancelOffer(plainId);
        assertEq(musd.balanceOf(lender) - lenderBefore, 1_000e18, "plain cancel");

        uint256 aliceBefore = musd.balanceOf(alice);
        (, uint256 face) = _borrow(alice, TOKEN, m1, offerM1, PRINCIPAL);
        assertEq(musd.balanceOf(alice) - aliceBefore, PRINCIPAL, "plain fill");
        vm.prank(alice);
        lm.repay(TOKEN, face);
        assertEq(cm.marketOf(m1).collectedMusd, face, "repay");

        vm.warp(m1 + 1);
        cm.finalize(m1);
        vm.prank(treasury);
        uint256 feeUnits = cm.claimUnits(m1);
        vm.prank(treasury);
        (uint256 early,) = cm.withdrawCollected(m1, feeUnits);
        assertEq(early, feeUnits, "withdrawCollected");
        vm.startPrank(lender);
        uint256 units = cm.claimUnits(m1);
        (uint256 redeemed,) = cm.redeem(m1, units);
        vm.stopPrank();
        assertEq(redeemed, units, "redeem");

        assertEq(cm.offerOf(id).remaining, PARKED, "the parked offer waits for the vault");
        assertEq(cm.parkedPrincipal(), PARKED);
    }

    function test_C34_RescueRefusesSMUSDAndStraySMUSDIsNotPrincipal() public {
        uint256 id = _postParked(m1, PARKED);
        vm.startPrank(stranger);
        vault.deposit(500e18);
        vault.transfer(address(cm), 500e18);
        vm.stopPrank();
        assertEq(vault.balanceOf(address(cm)), PARKED + 500e18);
        assertEq(cm.parkedPrincipal(), PARKED, "sMUSD sent unasked is not principal");

        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.TokenNotRescuable.selector, address(vault)));
        vm.prank(owner);
        cm.rescueToken(address(vault), owner, 1);

        uint256 lenderBefore = musd.balanceOf(lender);
        vm.prank(lender);
        cm.cancelOffer(id);
        assertEq(musd.balanceOf(lender) - lenderBefore, PARKED, "the maker gets its own principal, no more");
        assertEq(vault.balanceOf(address(cm)), 500e18, "the stray sMUSD stays, credited to nobody");
        assertEq(cm.parkedPrincipal(), 0);
    }

    /// @dev Random posts of both kinds, fills of one or two offers driven as LoanManager, cancels, yield lumps and
    ///      sMUSD sent unasked, with the parked books checked after every step.
    function testFuzz_C30_ParkedBooksHoldAfterEveryStep(uint256 seed) public {
        uint256 strayShares;
        uint64[3] memory dates = [m1, m2, m3];
        for (uint256 step; step < FUZZ_STEPS; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = r % 7;
            uint128 amount = uint128(bound(r >> 16, 10e18, 20_000e18));
            if (action == 0) {
                vm.prank(lender);
                cm.postOffer(dates[(r >> 8) % 3], APR, amount);
            } else if (action == 1) {
                _postParked(dates[(r >> 8) % 3], amount);
            } else if (action == 2 || action == 3) {
                _fuzzFill(r);
            } else if (action == 4) {
                uint256 id = 1 + (r >> 80) % (cm.nextOfferId() - 1);
                if (cm.offerOf(id).remaining != 0) {
                    vm.prank(lender);
                    cm.cancelOffer(id);
                }
            } else if (action == 5) {
                if (vault.totalSupply() != 0) {
                    vm.prank(donor);
                    vault.receiveProtocolYield(bound(r >> 200, 1e18, 5_000e18));
                }
            } else {
                vm.startPrank(stranger);
                vault.deposit(amount);
                vault.transfer(address(cm), amount);
                vm.stopPrank();
                strayShares += amount;
            }
            _assertParkedBooks(strayShares);
        }
    }

    function _fuzzFill(uint256 r) internal {
        uint256 last = cm.nextOfferId() - 1;
        uint256 idA = 1 + (r >> 80) % last;
        ICreditMarkets.Offer memory a = cm.offerOf(idA);
        if (a.remaining == 0) return;
        uint128 takeA = uint128(bound(r >> 120, 1, a.remaining));
        uint256 idB = 1 + (r >> 160) % last;
        ICreditMarkets.Offer memory b = cm.offerOf(idB);
        uint256[] memory ids;
        uint128[] memory amounts;
        if (idB != idA && b.maturity == a.maturity && b.remaining != 0) {
            (ids, amounts) = _two(idA, takeA, idB, uint128(bound(r >> 200, 1, b.remaining)));
        } else {
            (ids, amounts) = _one(idA, takeA);
        }
        vm.prank(address(lm));
        cm.fill(a.maturity, ids, amounts, 5_000, bob);
    }

    function _assertParkedBooks(uint256 strayShares) internal view {
        uint256 parkedSum;
        uint256 plainSum;
        uint256 next = cm.nextOfferId();
        for (uint256 id = 1; id < next; ++id) {
            ICreditMarkets.Offer memory offer = cm.offerOf(id);
            if (offer.parked) parkedSum += offer.remaining;
            else plainSum += offer.remaining;
        }
        uint256 shares = vault.balanceOf(address(cm));
        assertEq(cm.parkedPrincipal(), parkedSum, "C30: parked principal is the sum of parked remainders");
        assertGe(shares, cm.parkedPrincipal(), "C30: sMUSD held covers parked principal");
        assertEq(shares, parkedSum + strayShares, "C34: only stray sMUSD sits above parked principal");
        assertGe(musd.balanceOf(address(cm)), plainSum, "C14: MUSD held covers plain escrow");
        assertEq(musd.allowance(address(cm), address(vault)), 0, "C34: no standing allowance");
    }
}
