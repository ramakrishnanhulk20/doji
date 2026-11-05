// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Fuzz and invariant tests for Faucet on MockMUSD. The fuzz tests walk claim times across many days and every daily
// limit, and check the second each claim opens. The invariant run mixes claims, repeat claims, time moves, limit
// changes, pauses, funding and view reads. After every call: paid out equals kits claimed times the fixed kit, no
// address ever holds more than one kit, no claim landed above the release (C57), and both views match a formula
// written here, not read from the contract, and never reverted (C56).
// It does NOT cover: a kit changed mid-run (a fixed kit is what makes the money sum exact, and Faucet.t.sol covers
// setKit), withdraw and rescue (Faucet.t.sol), hostile recipients (Faucet.t.sol; every recipient here is a plain
// address), or real MUSD (test/fork/FaucetFork.t.sol).

import {Test, console} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Faucet} from "../../src/Faucet.sol";
import {IFaucet} from "../../src/interfaces/IFaucet.sol";
import {MockMUSD} from "../utils/MockMUSD.sol";

/// @notice The release rule as the work order states it, kept apart from the contract so a test never compares the
///         contract with itself.
library ReleaseRule {
    uint256 internal constant DAY = 86_400;

    function released(uint256 time, uint256 limit) internal pure returns (uint256) {
        if (limit == 0) return 0;
        uint256 share = limit * (time % DAY) / DAY + 1;
        return share < limit ? share : limit;
    }

    function dayStart(uint256 time) internal pure returns (uint256) {
        return time - time % DAY;
    }
}

/// @notice Drives Faucet for FaucetInvariantsTest. Every call is wrapped so a revert only skips the step, and the
///         handler keeps its own count of kits, BTC and MUSD put in, and of who was paid.
contract FaucetHandler is CommonBase, StdCheats, StdUtils {
    /// @dev Few enough that a 64-call run often picks an address twice.
    uint256 internal constant RECIPIENTS = 96;

    Faucet public immutable faucet;
    MockMUSD public immutable musd;
    address internal immutable owner;
    address internal immutable relayer;

    uint256 public kits;
    uint256 public btcIn;
    uint256 public musdIn;
    bool public releasePassed;
    bool public paidTwice;
    bool public viewReverted;
    address[] public paid;
    mapping(address account => bool) internal _wasPaid;
    mapping(bytes32 action => uint256) public successes;

    constructor(Faucet faucet_, MockMUSD musd_, address owner_, address relayer_, uint256 btcIn_, uint256 musdIn_) {
        faucet = faucet_;
        musd = musd_;
        owner = owner_;
        relayer = relayer_;
        btcIn = btcIn_;
        musdIn = musdIn_;
    }

    function paidCount() external view returns (uint256) {
        return paid.length;
    }

    function claim(uint256 seed) external {
        address to = _recipient(seed);
        vm.prank(relayer);
        try faucet.claim(to) {
            if (_wasPaid[to]) paidTwice = true;
            _wasPaid[to] = true;
            paid.push(to);
            ++kits;
            ++successes["claim"];
            uint256 time = vm.getBlockTimestamp();
            if (faucet.claimsToday() > ReleaseRule.released(time, faucet.dailyLimit())) releasePassed = true;
        } catch {
            ++successes["claimRefused"];
        }
    }

    function claimAgain(uint256 seed) external {
        if (paid.length == 0) return;
        address to = paid[seed % paid.length];
        vm.prank(relayer);
        try faucet.claim(to) {
            paidTwice = true;
        } catch {
            ++successes["claimAgainRefused"];
        }
    }

    function warp(uint256 seed) external {
        vm.warp(vm.getBlockTimestamp() + bound(seed, 1, 8 hours));
        ++successes["warp"];
    }

    function warpDays(uint256 seed) external {
        vm.warp(vm.getBlockTimestamp() + bound(seed, 1 days, 3 days));
        ++successes["warpDays"];
    }

    function setLimit(uint256 seed) external {
        vm.prank(owner);
        faucet.setDailyLimit(uint32(bound(seed, 0, 500)));
        ++successes["setLimit"];
    }

    function togglePause() external {
        bool wasPaused = faucet.paused();
        vm.prank(owner);
        if (wasPaused) {
            faucet.unpause();
        } else {
            faucet.pause();
        }
        ++successes["togglePause"];
    }

    function fund(uint256 btcSeed, uint256 musdSeed) external {
        uint256 btc = bound(btcSeed, 0, 5e15);
        uint256 musdAmount = bound(musdSeed, 0, 100e18);
        vm.deal(address(this), btc);
        (bool ok,) = address(faucet).call{value: btc}("");
        if (ok) btcIn += btc;
        musd.mint(address(faucet), musdAmount);
        musdIn += musdAmount;
        ++successes["fund"];
    }

    function readViews() external {
        try faucet.claimsOpen() returns (uint256) {
            ++successes["readViews"];
        } catch {
            viewReverted = true;
        }
        try faucet.nextOpenAt() returns (uint256) {} catch {
            viewReverted = true;
        }
        try faucet.claimsToday() returns (uint256) {} catch {
            viewReverted = true;
        }
    }

    function _recipient(uint256 seed) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("faucet recipient", seed % RECIPIENTS)))));
    }
}

contract FaucetInvariantsTest is Test {
    uint128 internal constant BTC_KIT = 0.001e18;
    uint128 internal constant MUSD_KIT = 25e18;
    uint32 internal constant LIMIT = 40;
    /// @dev Unequal and small against a 64-call run, so runs reach the faucet running short of each coin in turn.
    uint256 internal constant START_BTC = 12 * uint256(BTC_KIT);
    uint256 internal constant START_MUSD = 9 * uint256(MUSD_KIT);

    Faucet internal faucet;
    MockMUSD internal musd;
    FaucetHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");

    function setUp() public {
        vm.warp(20_000 days);
        musd = new MockMUSD();
        faucet = new Faucet(address(musd), owner, relayer, BTC_KIT, MUSD_KIT, LIMIT);
        vm.deal(address(faucet), START_BTC);
        musd.mint(address(faucet), START_MUSD);

        handler = new FaucetHandler(faucet, musd, owner, relayer, START_BTC, START_MUSD);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = FaucetHandler.claim.selector;
        selectors[1] = FaucetHandler.claimAgain.selector;
        selectors[2] = FaucetHandler.warp.selector;
        selectors[3] = FaucetHandler.warpDays.selector;
        selectors[4] = FaucetHandler.setLimit.selector;
        selectors[5] = FaucetHandler.togglePause.selector;
        selectors[6] = FaucetHandler.fund.selector;
        selectors[7] = FaucetHandler.readViews.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_C54_PaidOutEqualsKitsClaimedTimesTheKit() public view {
        assertEq(handler.btcIn() - address(faucet).balance, handler.kits() * BTC_KIT);
        assertEq(handler.musdIn() - musd.balanceOf(address(faucet)), handler.kits() * MUSD_KIT);
    }

    function invariant_C54_NoAddressClaimsTwice() public view {
        assertFalse(handler.paidTwice());
        uint256 count = handler.paidCount();
        assertEq(count, handler.kits());
        for (uint256 i; i < count; ++i) {
            address to = handler.paid(i);
            assertTrue(faucet.claimed(to));
            assertEq(to.balance, BTC_KIT);
            assertEq(musd.balanceOf(to), MUSD_KIT);
        }
    }

    function invariant_C57_NoClaimLandedAboveTheRelease() public view {
        assertFalse(handler.releasePassed());
    }

    function invariant_C56_ViewsNeverRevertedAndMatchTheRule() public view {
        assertFalse(handler.viewReverted());

        uint256 time = vm.getBlockTimestamp();
        uint256 limit = faucet.dailyLimit();
        uint256 released = ReleaseRule.released(time, limit);
        uint256 count = faucet.claimsToday();
        uint256 btcKits = address(faucet).balance / BTC_KIT;
        uint256 musdKits = musd.balanceOf(address(faucet)) / MUSD_KIT;
        uint256 kitsHeld = btcKits < musdKits ? btcKits : musdKits;

        uint256 open;
        if (!faucet.paused() && count < released) {
            open = released - count < kitsHeld ? released - count : kitsHeld;
        }
        assertEq(faucet.claimsOpen(), open);

        uint256 next = faucet.nextOpenAt();
        if (faucet.paused() || limit == 0 || kitsHeld == 0) {
            assertEq(next, 0);
        } else if (open != 0) {
            assertEq(next, time);
        } else {
            assertGt(next, time);
        }
    }

    function afterInvariant() external view {
        console.log("kits paid", handler.successes("claim"));
        console.log("claims refused", handler.successes("claimRefused"));
        console.log("repeat claims refused", handler.successes("claimAgainRefused"));
        console.log("limit changes", handler.successes("setLimit"));
        console.log("pauses and resumes", handler.successes("togglePause"));
    }
}

contract FaucetReleaseFuzzTest is Test {
    uint128 internal constant BTC_KIT = 0.001e18;
    uint128 internal constant MUSD_KIT = 25e18;
    /// @dev Past every limit, so in these tests only the release decides whether a claim lands.
    uint256 internal constant FUNDED_KITS = 2_000;
    uint256 internal constant MAX_LIMIT = 500;
    uint256 internal constant WALK_STEPS = 64;
    uint256 internal constant MAX_STEP = 9 hours;
    uint256 internal constant MAX_DAY_NUMBER = 400_000;

    MockMUSD internal musd;
    Faucet internal faucet;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    uint256 internal nextRecipient;

    mapping(uint256 day => uint256) internal countOnDay;

    function setUp() public {
        musd = new MockMUSD();
        faucet = new Faucet(address(musd), owner, relayer, BTC_KIT, MUSD_KIT, 1);
        vm.deal(address(faucet), FUNDED_KITS * BTC_KIT);
        musd.mint(address(faucet), FUNDED_KITS * MUSD_KIT);
    }

    function _setLimit(uint256 limit) internal {
        vm.prank(owner);
        faucet.setDailyLimit(uint32(limit));
    }

    function _claimFresh() internal returns (bool landed) {
        address to = address(uint160(0x1000000 + ++nextRecipient));
        vm.prank(relayer);
        try faucet.claim(to) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Spends `count` claims in the day's last second, when the whole limit is out, then moves to `time`.
    function _fillDay(uint256 dayStart, uint256 count, uint256 time) internal {
        vm.warp(dayStart + 1 days - 1);
        for (uint256 i; i < count; ++i) {
            assertTrue(_claimFresh());
        }
        vm.warp(time);
    }

    function testFuzz_C57_ClaimTimesAcrossManyDaysNeverPassTheRelease(uint256 limitSeed, uint256 dayNumber, uint256 walk)
        public
    {
        uint256 limit = bound(limitSeed, 1, MAX_LIMIT);
        _setLimit(limit);
        uint256 time = bound(dayNumber, 1, MAX_DAY_NUMBER) * 1 days;
        uint256 landed;

        for (uint256 i; i < WALK_STEPS; ++i) {
            time += uint256(keccak256(abi.encode(walk, i))) % MAX_STEP;
            vm.warp(time);
            uint256 day = time / 1 days;
            uint256 attempts = uint256(keccak256(abi.encode(walk, i, "attempts"))) % 4;
            for (uint256 j; j < attempts; ++j) {
                if (_claimFresh()) {
                    ++countOnDay[day];
                    ++landed;
                }
                assertLe(countOnDay[day], ReleaseRule.released(time, limit), "count passed the release");
                assertEq(faucet.claimsOnDay(day), countOnDay[day], "contract and test counts agree");
            }
        }
        assertGt(landed, 0, "the walk must land claims to prove anything");
    }

    function testFuzz_C57_MidnightSweepTakesOnlyTheFirstShare(uint256 limitSeed, uint256 dayNumber) public {
        _setLimit(bound(limitSeed, 1, MAX_LIMIT));
        vm.warp(bound(dayNumber, 1, MAX_DAY_NUMBER) * 1 days);

        assertTrue(_claimFresh());
        for (uint256 i; i < 8; ++i) {
            assertFalse(_claimFresh());
        }
        assertEq(faucet.claimsToday(), 1);
    }

    function testFuzz_C56_NextOpenAtIsTheExactSecondAClaimOpens(
        uint256 limitSeed,
        uint256 countSeed,
        uint256 dayNumber,
        uint256 elapsedSeed
    ) public {
        uint256 limit = bound(limitSeed, 1, MAX_LIMIT);
        _setLimit(limit);
        uint256 dayStart = bound(dayNumber, 1, MAX_DAY_NUMBER) * 1 days;
        uint256 count = bound(countSeed, 0, limit);
        uint256 time = dayStart + bound(elapsedSeed, 0, 1 days - 1);
        _fillDay(dayStart, count, time);

        uint256 next = faucet.nextOpenAt();

        if (ReleaseRule.released(time, limit) > count) {
            assertEq(next, time, "open now reads as now");
            assertGt(faucet.claimsOpen(), 0);
            return;
        }
        assertEq(faucet.claimsOpen(), 0, "closed now");
        assertGt(next, time, "the next claim is in the future");
        vm.warp(next - 1);
        assertEq(faucet.claimsOpen(), 0, "still closed one second before");
        vm.warp(next);
        assertGt(faucet.claimsOpen(), 0, "open on that second");
        assertEq(ReleaseRule.dayStart(next), count == limit ? dayStart + 1 days : dayStart);
    }

    function testFuzz_C56_LimitLoweredMidDayReadsZeroNotARevert(
        uint256 limitSeed,
        uint256 countSeed,
        uint256 loweredSeed,
        uint256 elapsedSeed
    ) public {
        uint256 limit = bound(limitSeed, 2, MAX_LIMIT);
        _setLimit(limit);
        uint256 dayStart = 20_000 days;
        uint256 count = bound(countSeed, 1, limit);
        uint256 time = dayStart + bound(elapsedSeed, 0, 1 days - 1);
        _fillDay(dayStart, count, time);

        _setLimit(bound(loweredSeed, 0, count));

        assertEq(faucet.claimsToday(), count);
        assertEq(faucet.claimsOpen(), 0);
        assertFalse(_claimFresh());
        assertEq(faucet.claimsToday(), count);
    }
}
