// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {CreditMarkets} from "../../src/CreditMarkets.sol";
import {UnitMarket} from "../../src/UnitMarket.sol";
import {IUnitMarket} from "../../src/interfaces/IUnitMarket.sol";
import {MockMUSD} from "./MockMUSD.sol";

/// @notice Drives random sequences against UnitMarket for UnitMarketInvariants.t.sol: listings by transfer at random
/// sizes, prices and expiries across two maturities, buys of random size (a seller may buy its own listing), cancels
/// by the seller, after-expiry returns by anyone, time moves, fee changes, pauses and resumes, and fee claims. Every
/// call is wrapped so a revert only skips the step. The handler keeps its own record of every listing's terms, of
/// the fees every buy should owe and of the MUSD claimed, so the invariants never compare the contract with itself.
/// An exit that should always work (a seller's cancel of an open listing, a return after expiry) and reverts, or a
/// buy whose money does not match the C45 rounding, raises a flag the invariants check.
contract UnitMarketHandler is CommonBase, StdCheats, StdUtils {
    struct Wiring {
        UnitMarket um;
        CreditMarkets cm;
        MockMUSD musd;
        address owner;
        address guardian;
        address treasury;
    }

    /// @dev Listing terms as the handler sent them, so a change made by the contract would show.
    struct Terms {
        address seller;
        uint64 maturity;
        uint64 expiry;
        uint16 feeBps;
        uint128 pricePerUnit;
    }

    uint256 internal constant PAR = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @dev Keeps the invariants' loops over listings small; a 64-call run rarely lists this often.
    uint256 internal constant MAX_LISTINGS = 48;

    UnitMarket public immutable um;
    CreditMarkets public immutable cm;
    MockMUSD public immutable musd;
    address internal immutable owner;
    address internal immutable guardian;
    address internal immutable treasury;

    address[3] public actors;
    uint64[2] public maturities;

    uint256[] public listingIds;
    mapping(uint256 listingId => Terms) internal _terms;
    mapping(uint256 listingId => uint128) public unitsLeftGhost;
    uint256 public feesDue;
    uint256 public feesClaimed;
    bool public exitBlocked;
    bool public badBuy;

    mapping(bytes32 action => uint256) public successes;

    constructor(Wiring memory w, address[3] memory actors_, uint64[2] memory maturities_) {
        um = w.um;
        cm = w.cm;
        musd = w.musd;
        owner = w.owner;
        guardian = w.guardian;
        treasury = w.treasury;
        actors = actors_;
        maturities = maturities_;
    }

    function listingCount() external view returns (uint256) {
        return listingIds.length;
    }

    function termsOf(uint256 listingId) external view returns (Terms memory) {
        return _terms[listingId];
    }

    function list(uint256 actorSeed, uint256 maturitySeed, uint256 unitsSeed, uint256 priceSeed, uint256 expirySeed)
        external
    {
        if (listingIds.length >= MAX_LISTINGS) return;
        address seller = actors[actorSeed % 3];
        uint64 maturity = maturities[maturitySeed % 2];
        uint256 held = cm.balanceOf(seller, maturity);
        if (held == 0) return;
        uint128 units = uint128(bound(unitsSeed, 1, held));
        uint128 price = uint128(bound(priceSeed, 1, PAR));
        uint64 expiry = uint64(vm.getBlockTimestamp() + bound(expirySeed, 1, 10 days));
        uint16 rate = um.feeBps();
        uint256 listingId = um.nextListingId();

        vm.prank(seller);
        try cm.safeTransferFrom(seller, address(um), maturity, units, abi.encode(price, expiry)) {
            listingIds.push(listingId);
            _terms[listingId] =
                Terms({seller: seller, maturity: maturity, expiry: expiry, feeBps: rate, pricePerUnit: price});
            unitsLeftGhost[listingId] = units;
            ++successes["list"];
        } catch {}
    }

    function buy(uint256 actorSeed, uint256 listingSeed, uint256 unitsSeed) external {
        if (listingIds.length == 0) return;
        uint256 listingId = listingIds[listingSeed % listingIds.length];
        uint128 left = unitsLeftGhost[listingId];
        if (left == 0) return;
        // A quarter of buys are dust, so the rounding up is exercised on every price.
        uint256 most = unitsSeed % 4 == 0 && left > 1e6 ? 1e6 : left;
        uint128 units = uint128(bound(unitsSeed, 1, most));
        address buyer = actors[actorSeed % 3];
        Terms memory t = _terms[listingId];
        uint256 expectedCost = (uint256(units) * t.pricePerUnit + PAR - 1) / PAR;
        uint256 expectedFee = expectedCost * t.feeBps / BPS;

        uint256 buyerMusd = musd.balanceOf(buyer);
        uint256 sellerMusd = musd.balanceOf(t.seller);
        uint256 buyerUnits = cm.balanceOf(buyer, t.maturity);
        vm.prank(buyer);
        try um.buy(listingId, units, uint128(PAR)) returns (uint256 cost) {
            unitsLeftGhost[listingId] = left - units;
            feesDue += expectedFee;
            if (cost != expectedCost || cost == 0) badBuy = true;
            if (cm.balanceOf(buyer, t.maturity) != buyerUnits + units) badBuy = true;
            if (buyer == t.seller) {
                if (buyerMusd - musd.balanceOf(buyer) != expectedFee) badBuy = true;
            } else {
                if (buyerMusd - musd.balanceOf(buyer) != expectedCost) badBuy = true;
                if (musd.balanceOf(t.seller) - sellerMusd != expectedCost - expectedFee) badBuy = true;
            }
            ++successes["buy"];
        } catch {}
    }

    function cancel(uint256 listingSeed) external {
        if (listingIds.length == 0) return;
        uint256 listingId = listingIds[listingSeed % listingIds.length];
        address seller = _terms[listingId].seller;
        bool open = unitsLeftGhost[listingId] != 0;
        vm.prank(seller);
        try um.cancel(listingId) {
            unitsLeftGhost[listingId] = 0;
            ++successes["cancel"];
        } catch {
            if (open) exitBlocked = true;
        }
    }

    function returnExpired(uint256 listingSeed, uint256 callerSeed) external {
        if (listingIds.length == 0) return;
        uint256 listingId = listingIds[listingSeed % listingIds.length];
        bool due = unitsLeftGhost[listingId] != 0 && vm.getBlockTimestamp() >= _terms[listingId].expiry;
        vm.prank(actors[callerSeed % 3]);
        try um.returnExpired(listingId) {
            unitsLeftGhost[listingId] = 0;
            ++successes["returnExpired"];
        } catch {
            if (due) exitBlocked = true;
        }
    }

    function warp(uint256 seed) external {
        vm.warp(vm.getBlockTimestamp() + bound(seed, 1 hours, 3 days));
        ++successes["warp"];
    }

    function setFeeBps(uint256 seed) external {
        vm.prank(owner);
        try um.setFeeBps(uint16(bound(seed, 0, 100))) {
            ++successes["setFeeBps"];
        } catch {}
    }

    function setPaused(uint256 seed) external {
        bool pause = seed % 2 == 0;
        vm.prank(pause ? guardian : owner);
        try um.setPaused(pause) {
            ++successes["setPaused"];
        } catch {}
    }

    function claimFees() external {
        vm.prank(treasury);
        try um.claimFees() returns (uint256 amount) {
            feesClaimed += amount;
            ++successes["claimFees"];
        } catch {}
    }
}
