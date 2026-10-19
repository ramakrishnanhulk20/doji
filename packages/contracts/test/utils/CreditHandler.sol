// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CreditMarkets} from "../../src/CreditMarkets.sol";
import {LoanManager} from "../../src/LoanManager.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {MockMUSD} from "./MockMUSD.sol";
import {MockVeBTC} from "./MockVeBTC.sol";
import {MockPriceFeed} from "./MockPriceFeed.sol";
import {MockPoolsVoter} from "./MockPoolsVoter.sol";

/// @notice Drives random sequences against CreditMarkets and LoanManager for CreditInvariants.t.sol: posts,
/// cancels, borrows, repays, rolls, auction starts and cancels, purchases, settle and its preparation,
/// write-offs after a simulated custody loss, time and price moves, finalisation, redemption and claims,
/// across three maturities. Every protocol call is wrapped so a revert only skips the step, and the ghost
/// totals the invariants compare against move only on success.
contract CreditHandler is CommonBase, StdCheats, StdUtils {
    struct Wiring {
        CreditMarkets cm;
        LoanManager lm;
        MockMUSD musd;
        MockVeBTC ve;
        MockPriceFeed feed;
        MockPoolsVoter voter;
        address treasury;
    }

    uint256 internal constant WEEK = 604_800;
    uint256 internal constant MAX_OFFERS = 40;
    uint256 internal constant MAX_TOKENS = 24;
    uint256 internal constant MIN_LOAN = 10e18;

    CreditMarkets public immutable cm;
    LoanManager public immutable lm;
    MockMUSD public immutable musd;
    MockVeBTC public immutable ve;
    MockPriceFeed public immutable feed;
    MockPoolsVoter public immutable voter;
    address public immutable treasury;

    uint64[3] public maturities;
    address[3] public lenders;
    address[3] public borrowers;
    address public buyer = makeAddr("handlerBuyer");
    address public thief = makeAddr("handlerThief");

    uint256[] public offerIds;
    uint256[] public tokenIds;
    uint256 internal _nextTokenId = 1_000;

    mapping(uint64 maturity => uint256) public redeemedMusd;
    mapping(uint64 maturity => uint256) public redeemedBtc;
    mapping(uint64 maturity => uint256) public burnedUnits;
    bool public paidAboveParMusd;

    mapping(bytes32 action => uint256) public successes;

    constructor(Wiring memory w, uint64[3] memory maturities_, uint256[] memory existingOffers, address existingLender) {
        cm = w.cm;
        lm = w.lm;
        musd = w.musd;
        ve = w.ve;
        feed = w.feed;
        voter = w.voter;
        treasury = w.treasury;
        maturities = maturities_;
        lenders = [existingLender, makeAddr("handlerLender1"), makeAddr("handlerLender2")];
        borrowers = [makeAddr("handlerBorrower0"), makeAddr("handlerBorrower1"), makeAddr("handlerBorrower2")];
        for (uint256 i; i < existingOffers.length; ++i) {
            offerIds.push(existingOffers[i]);
        }
        for (uint256 i; i < 3; ++i) {
            vm.prank(lenders[i]);
            musd.approve(address(cm), type(uint256).max);
            vm.prank(borrowers[i]);
            musd.approve(address(lm), type(uint256).max);
        }
        vm.prank(buyer);
        musd.approve(address(lm), type(uint256).max);
    }

    function offerCount() external view returns (uint256) {
        return offerIds.length;
    }

    function tokenCount() external view returns (uint256) {
        return tokenIds.length;
    }

    function postOffer(uint256 lenderSeed, uint256 maturitySeed, uint256 aprSeed, uint256 amountSeed) external {
        if (offerIds.length >= MAX_OFFERS) return;
        uint64 maturity = maturities[maturitySeed % 3];
        if (!cm.isValidMaturity(maturity)) return;
        address maker = lenders[lenderSeed % 3];
        uint128 amount = uint128(bound(amountSeed, 10e18, 60_000e18));
        uint16 aprBps = uint16(bound(aprSeed, 0, 2_000));
        musd.mint(maker, amount);
        vm.prank(maker);
        try cm.postOffer(maturity, aprBps, amount) returns (uint256 id) {
            offerIds.push(id);
            ++successes["postOffer"];
        } catch {}
    }

    function cancelOffer(uint256 offerSeed) external {
        if (offerIds.length == 0) return;
        uint256 id = offerIds[offerSeed % offerIds.length];
        address maker = cm.offerOf(id).maker;
        vm.prank(maker);
        try cm.cancelOffer(id) {
            ++successes["cancelOffer"];
        } catch {}
    }

    function borrow(uint256 tokenSeed, uint256 maturitySeed, uint256 offerSeed, uint256 amountSeed) external {
        uint256 tokenId = _pickToken(tokenSeed, ILoanManager.LoanState.None);
        if (tokenId == 0) tokenId = _newToken(tokenSeed);
        if (tokenId == 0) return;
        uint64 maturity = _pickMaturity(tokenId, maturitySeed, 0);
        if (maturity == 0) return;
        (uint256 offerId, uint128 amount) = _pickFill(tokenId, maturity, offerSeed, amountSeed);
        if (offerId == 0) return;

        (uint256[] memory ids, uint128[] memory amounts) = _one(offerId, amount);
        vm.prank(lm.positionOf(tokenId).borrower);
        try lm.borrow(tokenId, maturity, ids, amounts, 5_000) {
            ++successes["borrow"];
        } catch {}
    }

    function repay(uint256 tokenSeed, uint256 amountSeed) external {
        uint256 tokenId = _pickOpenLoan(tokenSeed);
        if (tokenId == 0) return;
        uint256 owed = lm.owedOf(tokenId);
        uint256 amount = amountSeed % 2 == 0 ? owed : bound(amountSeed, 1, owed);
        address payer = borrowers[amountSeed % 3];
        musd.mint(payer, amount);
        vm.prank(payer);
        try lm.repay(tokenId, amount) {
            ++successes["repay"];
        } catch {}
    }

    function roll(uint256 tokenSeed, uint256 maturitySeed, uint256 offerSeed, uint256 amountSeed) external {
        uint256 tokenId = _pickToken(tokenSeed, ILoanManager.LoanState.Active);
        if (tokenId == 0) return;
        ILoanManager.Loan memory loan = lm.loanOf(tokenId);
        if (block.timestamp > loan.maturity) return;
        uint64 maturity = _pickMaturity(tokenId, maturitySeed, loan.maturity);
        if (maturity == 0) return;
        (uint256 offerId, uint128 amount) = _pickFill(tokenId, maturity, offerSeed, amountSeed);
        if (offerId == 0) return;

        address borrower = lm.positionOf(tokenId).borrower;
        musd.mint(borrower, lm.owedOf(tokenId));
        (uint256[] memory ids, uint128[] memory amounts) = _one(offerId, amount);
        vm.prank(borrower);
        try lm.roll(tokenId, maturity, ids, amounts, 5_000, type(uint256).max) {
            ++successes["roll"];
        } catch {}
    }

    /// @dev Half the calls first crash the price so the chosen loan sits between 66% and 160% LTV, so auctions,
    ///      including underwater ones, happen often enough inside one run.
    function startAuction(uint256 tokenSeed, uint256 crashSeed) external {
        uint256 tokenId = _pickToken(tokenSeed, ILoanManager.LoanState.Active);
        if (tokenId == 0) return;
        if (crashSeed % 2 == 0) {
            (uint256 amount,,) = lm.lockOf(tokenId);
            uint256 ltvBps = bound(crashSeed >> 1, 6_600, 16_000);
            uint256 price = lm.owedOf(tokenId) * 10_000 * 1e18 / (ltvBps * amount);
            if (price != 0) feed.setPrice(price);
        }
        try lm.startAuction(tokenId) {
            ++successes["startAuction"];
        } catch {}
    }

    function cancelAuction(uint256 tokenSeed) external {
        uint256 tokenId = _pickToken(tokenSeed, ILoanManager.LoanState.Auction);
        if (tokenId == 0) return;
        try lm.cancelAuction(tokenId) {
            ++successes["cancelAuction"];
        } catch {}
    }

    /// @dev The buyer bids between half and one and a half times the current price, so some auctions go
    ///      unsold and reach settle.
    function purchase(uint256 tokenSeed, uint256 bidSeed) external {
        uint256 tokenId = _pickToken(tokenSeed, ILoanManager.LoanState.Auction);
        if (tokenId == 0) return;
        uint256 price = lm.auctionPrice(tokenId);
        uint256 maxPay = price * bound(bidSeed, 5_000, 15_000) / 10_000;
        musd.mint(buyer, price);
        vm.prank(buyer);
        try lm.purchase(tokenId, maxPay, block.timestamp) {
            ++successes["purchase"];
        } catch {}
    }

    /// @dev Half the calls first let time pass to the token's floor time, and out of the voter's blocked
    ///      first hour of an epoch, standing in for a keeper that waits.
    function prepareSettle(uint256 tokenSeed, uint256 waitSeed) external {
        uint256 tokenId = _pickUnsold(tokenSeed, true);
        if (tokenId == 0) return;
        if (waitSeed % 2 == 0) {
            ILoanManager.Auction memory a = lm.auctionOf(tokenId);
            uint256 at = Math.max(block.timestamp, uint256(a.startTime) + a.duration);
            if (at % WEEK <= 1 hours) at = at - (at % WEEK) + 1 hours + 1;
            if (voter.lastVoted(tokenId) >= at - (at % WEEK)) at = at - (at % WEEK) + WEEK + 1 hours + 1;
            vm.warp(at);
        }
        try lm.prepareSettle(tokenId) {
            ++successes["prepareSettle"];
        } catch {}
    }

    /// @dev Half the calls first let time pass to the token's floor time and lock end.
    function settle(uint256 tokenSeed, uint256 waitSeed) external {
        uint256 tokenId = _pickUnsold(tokenSeed, false);
        if (tokenId == 0) return;
        if (waitSeed % 2 == 0) {
            ILoanManager.Auction memory a = lm.auctionOf(tokenId);
            (, uint256 end,) = lm.lockOf(tokenId);
            vm.warp(Math.max(block.timestamp, Math.max(uint256(a.startTime) + a.duration, end)));
        }
        try lm.settle(tokenId) {
            ++successes["settle"];
        } catch {}
    }

    /// @dev Rare by design: a quarter of calls move a position out of custody, standing in for a veBTC flaw.
    function writeOff(uint256 tokenSeed) external {
        if (tokenSeed % 4 != 0) return;
        uint256 tokenId = _pickOpenLoan(tokenSeed >> 2);
        if (tokenId == 0) return;
        if (ve.ownerOf(tokenId) == address(lm)) ve.forceTransfer(address(lm), thief, tokenId);
        try lm.writeOff(tokenId) {
            ++successes["writeOff"];
        } catch {}
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1 hours, 5 days));
        ++successes["warp"];
    }

    function movePrice(uint256 priceSeed) external {
        feed.setPrice(bound(priceSeed, 15_000e18, 120_000e18));
        ++successes["movePrice"];
    }

    function finalize(uint256 maturitySeed) external {
        for (uint256 i; i < 3; ++i) {
            try cm.finalize(maturities[(maturitySeed % 3 + i) % 3]) {
                ++successes["finalize"];
            } catch {}
        }
    }

    /// @dev Looks across holders and maturities, from seeded starts, for units in a final market.
    function redeem(uint256 holderSeed, uint256 maturitySeed, uint256 unitsSeed) external {
        (address holder, uint64 maturity) = _pickRedeemable(holderSeed, maturitySeed);
        if (holder == address(0)) return;
        if (cm.pendingUnits(holder, maturity) != 0) {
            vm.prank(holder);
            cm.claimUnits(maturity);
        }
        uint256 held = cm.balanceOf(holder, maturity);
        if (held == 0) return;
        uint256 units = unitsSeed % 2 == 0 ? held : bound(unitsSeed, 1, held);
        vm.prank(holder);
        try cm.redeem(maturity, units) returns (uint256 musdOut, uint256 btcOut) {
            if (musdOut > units) paidAboveParMusd = true;
            redeemedMusd[maturity] += musdOut;
            redeemedBtc[maturity] += btcOut;
            burnedUnits[maturity] += units;
            ++successes["redeem"];
        } catch {}
    }

    function claim(uint256 accountSeed) external {
        address account = borrowers[accountSeed % 3];
        for (uint256 i; i < 3; ++i) {
            address candidate = borrowers[(accountSeed % 3 + i) % 3];
            if (lm.claimableMusd(candidate) != 0 || lm.claimableBtc(candidate) != 0) {
                account = candidate;
                break;
            }
        }
        vm.prank(account);
        try lm.claim() {
            ++successes["claim"];
        } catch {}
    }

    function _pickRedeemable(uint256 holderSeed, uint256 maturitySeed) internal view returns (address, uint64) {
        for (uint256 i; i < 3; ++i) {
            uint64 maturity = maturities[(maturitySeed % 3 + i) % 3];
            if (!cm.marketOf(maturity).isFinal) continue;
            for (uint256 j; j < 4; ++j) {
                uint256 k = (holderSeed % 4 + j) % 4;
                address holder = k == 3 ? treasury : lenders[k];
                if (cm.pendingUnits(holder, maturity) + cm.balanceOf(holder, maturity) != 0) return (holder, maturity);
            }
        }
        return (address(0), 0);
    }

    /// @dev Mints a fresh position to one of the borrowers and deposits it. Its lock ends on one of the three
    ///      maturities, a week after the last, or never (permanent), and a quarter arrive with a standing vote.
    function _newToken(uint256 seed) internal returns (uint256 tokenId) {
        if (tokenIds.length >= MAX_TOKENS) return 0;
        tokenId = _nextTokenId++;
        address borrower = borrowers[seed % 3];
        uint256 amount = bound(seed >> 8, 0.05e18, 3e18);
        uint256 kind = (seed >> 80) % 5;
        bool permanent = kind == 4;
        uint256 end = permanent ? 0 : (kind == 3 ? uint256(maturities[2]) + WEEK : maturities[kind]);
        if (!permanent && end <= block.timestamp) end = (block.timestamp / WEEK + 2) * WEEK;

        ve.mint(borrower, tokenId, int128(int256(amount)), end, permanent);
        if ((seed >> 120) % 4 == 0) voter.vote(tokenId);
        vm.startPrank(borrower);
        ve.approve(address(lm), tokenId);
        lm.deposit(tokenId);
        vm.stopPrank();
        tokenIds.push(tokenId);
    }

    /// @dev First tracked token from a seeded start whose loan is in `state` and whose NFT is still held.
    function _pickToken(uint256 seed, ILoanManager.LoanState state) internal view returns (uint256) {
        uint256 n = tokenIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = tokenIds[(seed % n + i) % n];
            if (lm.positionOf(tokenId).borrower == address(0)) continue;
            if (lm.loanOf(tokenId).state != state) continue;
            if (ve.ownerOf(tokenId) != address(lm)) continue;
            return tokenId;
        }
        return 0;
    }

    /// @dev An auctioned token still in custody that needs preparing (voted or permanent) when `needsPrep`,
    ///      or one with a normal, unvoted lock that settle can take once its time comes, when not.
    function _pickUnsold(uint256 seed, bool needsPrep) internal view returns (uint256) {
        uint256 n = tokenIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = tokenIds[(seed % n + i) % n];
            if (lm.loanOf(tokenId).state != ILoanManager.LoanState.Auction) continue;
            if (ve.ownerOf(tokenId) != address(lm)) continue;
            (,, bool permanent) = lm.lockOf(tokenId);
            bool voted = ve.voted(tokenId);
            if (needsPrep ? (voted || permanent) : (!voted && !permanent)) return tokenId;
        }
        return 0;
    }

    function _pickOpenLoan(uint256 seed) internal view returns (uint256) {
        uint256 n = tokenIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = tokenIds[(seed % n + i) % n];
            if (lm.loanOf(tokenId).state != ILoanManager.LoanState.None) return tokenId;
        }
        return 0;
    }

    /// @dev A valid maturity later than `after_` that the token's lock reaches, or zero.
    function _pickMaturity(uint256 tokenId, uint256 seed, uint64 after_) internal view returns (uint64) {
        (, uint256 end, bool permanent) = lm.lockOf(tokenId);
        for (uint256 i; i < 3; ++i) {
            uint64 maturity = maturities[(seed % 3 + i) % 3];
            if (maturity <= after_ || !cm.isValidMaturity(maturity)) continue;
            if (!permanent && maturity > end) continue;
            return maturity;
        }
        return 0;
    }

    /// @dev An offer at `maturity` with money left, and an amount inside it that keeps the loan under 40% LTV.
    function _pickFill(uint256 tokenId, uint64 maturity, uint256 offerSeed, uint256 amountSeed)
        internal
        view
        returns (uint256 offerId, uint128 amount)
    {
        (, uint256 value) = lm.collateralValue(tokenId);
        uint256 cap = value * 39 / 100;
        if (cap < MIN_LOAN) return (0, 0);
        uint256 n = offerIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = offerIds[(offerSeed % n + i) % n];
            if (cm.offerOf(id).maturity != maturity) continue;
            uint256 remaining = cm.offerOf(id).remaining;
            if (remaining < MIN_LOAN) continue;
            uint256 most = Math.min(remaining, cap);
            return (id, uint128(amountSeed % 2 == 0 ? most : bound(amountSeed, MIN_LOAN, most)));
        }
        return (0, 0);
    }

    function _one(uint256 offerId, uint128 amount) internal pure returns (uint256[] memory ids, uint128[] memory amounts) {
        ids = new uint256[](1);
        amounts = new uint128[](1);
        ids[0] = offerId;
        amounts[0] = amount;
    }
}
