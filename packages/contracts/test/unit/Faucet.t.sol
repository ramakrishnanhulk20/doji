// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit tests for Faucet: every public function's happy path, every revert and every event, the release rule at its
// edges, and hostile recipients (one that refuses, one that loops forever, one that returns 1 MB, two that call back
// in, and a Safe-style proxy wallet that must receive a full kit). Runs on the real contract with MockMUSD. Also
// DeployFaucet's C65 relayer check and C82 read-back, called directly.
// It does NOT cover: random sequences and fuzzed claim times (FaucetInvariants.t.sol), real MUSD and the real chain
// (test/fork/FaucetFork.t.sol, script/faucet-live.sh), the relayer's own gas and nonce rules or the website (the
// claim route's work), state that changes between a simulation and landing, the BTC ERC-20 view, which the faucet
// holds no address for, or DeployFaucet's run() from start to end (its broadcast is proven live). A stolen owner key
// is a stated non-goal in the threat model.

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DeployFaucet} from "../../script/DeployFaucet.s.sol";
import {Faucet} from "../../src/Faucet.sol";
import {IFaucet} from "../../src/interfaces/IFaucet.sol";
import {
    GasProbeRecipient,
    LoopingRecipient,
    ReenteringRecipient,
    ReenteringRelayer,
    RefusingRecipient,
    ReturnBombRecipient,
    SafeStyleProxy,
    SafeStyleSingleton
} from "../utils/FaucetRecipients.sol";
import {MockMUSD} from "../utils/MockMUSD.sol";
import {MockToken} from "../utils/MockToken.sol";

contract FaucetTest is Test {
    uint128 internal constant BTC_KIT = 0.001e18;
    uint128 internal constant MUSD_KIT = 25e18;
    uint32 internal constant LIMIT = 40;
    uint256 internal constant FUNDED_KITS = 100;
    /// @dev A UTC midnight, so offsets in these tests read as times of day.
    uint256 internal constant START = 20_000 days;
    uint256 internal constant STIPEND = 2_300;
    /// @dev The share of the day one claim takes at the daily limit of 40.
    uint256 internal constant STEP = 1 days / LIMIT;
    /// @dev The most any recipient may cost the relayer: the C59 ceiling must sit at or above this.
    uint256 internal constant WORST_CLAIM_GAS = 250_000;

    event Claimed(address indexed to, uint256 btc, uint256 musd, uint256 indexed day);
    event KitSet(uint128 btc, uint128 musd);
    event DailyLimitSet(uint32 dailyLimit);
    event RelayerSet(address indexed relayer);
    event Withdrawn(address indexed to, uint256 btc, uint256 musd);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event Paused(address account);
    event Unpaused(address account);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event SafeReceived(address indexed sender, uint256 value);

    MockMUSD internal musd;
    Faucet internal faucet;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(START);
        musd = new MockMUSD();
        faucet = new Faucet(address(musd), owner, relayer, BTC_KIT, MUSD_KIT, LIMIT);
        vm.deal(address(faucet), FUNDED_KITS * BTC_KIT);
        musd.mint(address(faucet), FUNDED_KITS * MUSD_KIT);
    }

    function _claim(address to) internal {
        vm.prank(relayer);
        faucet.claim(to);
    }

    /// @dev Spends the first `count` claims of the current day, each at the first second it is open.
    function _claimsAtRelease(uint256 count) internal {
        uint256 dayStart = vm.getBlockTimestamp() / 1 days * 1 days;
        for (uint256 i; i < count; ++i) {
            vm.warp(dayStart + i * STEP);
            _claim(makeAddr(string.concat("early", vm.toString(i))));
        }
    }

    function _assertNothingMoved(address to) internal view {
        assertFalse(faucet.claimed(to), "claimed stayed false");
        assertEq(faucet.claimsToday(), 0, "day's count stayed zero");
        assertEq(address(faucet).balance, FUNDED_KITS * BTC_KIT, "faucet BTC unchanged");
        assertEq(musd.balanceOf(address(faucet)), FUNDED_KITS * MUSD_KIT, "faucet MUSD unchanged");
        assertEq(to.balance, 0, "recipient got no BTC");
        assertEq(musd.balanceOf(to), 0, "recipient got no MUSD");
    }

    /// @dev Gas of one claim from the relayer's side, reverting or not.
    function _claimGas(address to) internal returns (uint256 used, bool landed) {
        vm.prank(relayer);
        uint256 before = gasleft();
        try faucet.claim(to) {
            landed = true;
        } catch {
            landed = false;
        }
        used = before - gasleft();
    }

    function test_constructor_SetsEverythingAndEmits() public {
        vm.expectEmit();
        emit RelayerSet(relayer);
        vm.expectEmit();
        emit KitSet(BTC_KIT, MUSD_KIT);
        vm.expectEmit();
        emit DailyLimitSet(LIMIT);
        Faucet fresh = new Faucet(address(musd), owner, relayer, BTC_KIT, MUSD_KIT, LIMIT);

        assertEq(address(fresh.musd()), address(musd));
        assertEq(fresh.owner(), owner);
        assertEq(fresh.relayer(), relayer);
        assertEq(fresh.btcPerClaim(), BTC_KIT);
        assertEq(fresh.musdPerClaim(), MUSD_KIT);
        assertEq(fresh.dailyLimit(), LIMIT);
        assertFalse(fresh.paused());
    }

    function test_constructor_CapsAreTheOrderedNumbers() public view {
        assertEq(faucet.MAX_BTC_PER_CLAIM(), 0.01e18);
        assertEq(faucet.MAX_MUSD_PER_CLAIM(), 100e18);
        assertEq(faucet.MAX_DAILY_LIMIT(), 500);
        assertEq(faucet.RECIPIENT_GAS(), 50_000);
    }

    function test_constructor_RefusesZeroAddresses() public {
        vm.expectRevert(IFaucet.ZeroAddress.selector);
        new Faucet(address(0), owner, relayer, BTC_KIT, MUSD_KIT, LIMIT);
        vm.expectRevert(IFaucet.ZeroAddress.selector);
        new Faucet(address(musd), address(0), relayer, BTC_KIT, MUSD_KIT, LIMIT);
        vm.expectRevert(IFaucet.ZeroAddress.selector);
        new Faucet(address(musd), owner, address(0), BTC_KIT, MUSD_KIT, LIMIT);
    }

    function test_C58_constructor_HoldsTheCaps() public {
        vm.expectRevert(IFaucet.KitEmpty.selector);
        new Faucet(address(musd), owner, relayer, 0, MUSD_KIT, LIMIT);
        vm.expectRevert(IFaucet.KitEmpty.selector);
        new Faucet(address(musd), owner, relayer, BTC_KIT, 0, LIMIT);
        vm.expectRevert(IFaucet.KitTooLarge.selector);
        new Faucet(address(musd), owner, relayer, 0.01e18 + 1, MUSD_KIT, LIMIT);
        vm.expectRevert(IFaucet.KitTooLarge.selector);
        new Faucet(address(musd), owner, relayer, BTC_KIT, 100e18 + 1, LIMIT);
        vm.expectRevert(IFaucet.LimitTooHigh.selector);
        new Faucet(address(musd), owner, relayer, BTC_KIT, MUSD_KIT, 501);
    }

    function test_C54_ClaimPaysOneWholeKitAndEmitsOnce() public {
        uint256 today = START / 1 days;
        vm.recordLogs();
        _claim(alice);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 faucetLogs;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(faucet)) ++faucetLogs;
        }
        assertEq(faucetLogs, 1, "one event from the faucet");
        assertEq(alice.balance, BTC_KIT);
        assertEq(musd.balanceOf(alice), MUSD_KIT);
        assertEq(address(faucet).balance, (FUNDED_KITS - 1) * BTC_KIT);
        assertEq(musd.balanceOf(address(faucet)), (FUNDED_KITS - 1) * MUSD_KIT);
        assertTrue(faucet.claimed(alice));
        assertEq(faucet.claimsOnDay(today), 1);
        assertEq(faucet.claimsToday(), 1);
    }

    function test_C54_ClaimEmitsClaimedNamingTheReceiver() public {
        vm.expectEmit(address(faucet));
        emit Claimed(alice, BTC_KIT, MUSD_KIT, START / 1 days);
        _claim(alice);
    }

    function test_C54_OnlyTheRelayerCanClaim() public {
        vm.expectRevert(IFaucet.NotRelayer.selector);
        vm.prank(stranger);
        faucet.claim(alice);

        vm.expectRevert(IFaucet.NotRelayer.selector);
        vm.prank(owner);
        faucet.claim(alice);
        _assertNothingMoved(alice);
    }

    function test_C54_ZeroAddressAndTheFaucetItselfAreRefused() public {
        vm.expectRevert(abi.encodeWithSelector(IFaucet.BadRecipient.selector, address(0)));
        _claim(address(0));
        vm.expectRevert(abi.encodeWithSelector(IFaucet.BadRecipient.selector, address(faucet)));
        _claim(address(faucet));
        assertEq(faucet.claimsToday(), 0);
    }

    function test_C54_SecondClaimForOneAddressIsRefusedOnAnyLaterDay() public {
        _claim(alice);
        vm.expectRevert(abi.encodeWithSelector(IFaucet.AlreadyClaimed.selector, alice));
        _claim(alice);

        vm.warp(START + 30 days);
        vm.expectRevert(abi.encodeWithSelector(IFaucet.AlreadyClaimed.selector, alice));
        _claim(alice);
        assertEq(alice.balance, BTC_KIT, "still one kit of BTC");
        assertEq(musd.balanceOf(alice), MUSD_KIT, "still one kit of MUSD");
    }

    function test_C54_RecipientThatRefusesBtcRevertsWhole() public {
        RefusingRecipient refuser = new RefusingRecipient();
        vm.expectRevert(abi.encodeWithSelector(IFaucet.BtcPaymentFailed.selector, address(refuser)));
        _claim(address(refuser));
        _assertNothingMoved(address(refuser));
    }

    function test_C54_RecipientMusdRefusesRevertsWhole() public {
        musd.setRefused(alice, true);
        vm.expectRevert(abi.encodeWithSelector(MockMUSD.RecipientRefused.selector, alice));
        _claim(alice);
        _assertNothingMoved(alice);
    }

    function test_C54_FaucetShortOfBtcRevertsWhole() public {
        vm.deal(address(faucet), BTC_KIT - 1);
        vm.expectRevert(abi.encodeWithSelector(IFaucet.NoClaimOpen.selector, 0));
        _claim(alice);
        assertFalse(faucet.claimed(alice));
        assertEq(faucet.claimsToday(), 0);
        assertEq(address(faucet).balance, BTC_KIT - 1);
        assertEq(musd.balanceOf(address(faucet)), FUNDED_KITS * MUSD_KIT);
    }

    function test_C54_FaucetShortOfMusdRevertsWhole() public {
        vm.prank(owner);
        faucet.withdraw(0, FUNDED_KITS * MUSD_KIT - (MUSD_KIT - 1));
        vm.expectRevert(abi.encodeWithSelector(IFaucet.NoClaimOpen.selector, 0));
        _claim(alice);
        assertFalse(faucet.claimed(alice));
        assertEq(faucet.claimsToday(), 0);
        assertEq(address(faucet).balance, FUNDED_KITS * BTC_KIT);
        assertEq(musd.balanceOf(address(faucet)), MUSD_KIT - 1);
    }

    function test_C54_ExactlyOneKitLeftStillPays() public {
        vm.startPrank(owner);
        faucet.withdraw((FUNDED_KITS - 1) * BTC_KIT, (FUNDED_KITS - 1) * MUSD_KIT);
        vm.stopPrank();
        assertEq(faucet.claimsOpen(), 1);

        _claim(alice);

        assertEq(address(faucet).balance, 0);
        assertEq(musd.balanceOf(address(faucet)), 0);
        assertEq(faucet.claimsOpen(), 0);
    }

    function test_C54_ClaimIsNotPayable() public {
        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        (bool ok,) = address(faucet).call{value: 1}(abi.encodeCall(IFaucet.claim, (alice)));
        assertFalse(ok);
        _assertNothingMoved(alice);
    }

    function test_C54_PausedClaimIsRefused() public {
        vm.prank(owner);
        faucet.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _claim(alice);
        assertFalse(faucet.claimed(alice));
    }

    function test_C54_AKitChangeAppliesToTheNextClaimOnly() public {
        _claim(alice);
        vm.prank(owner);
        faucet.setKit(0.002e18, 50e18);
        vm.warp(START + STEP);
        vm.expectEmit(address(faucet));
        emit Claimed(bob, 0.002e18, 50e18, START / 1 days);
        _claim(bob);
        assertEq(alice.balance, BTC_KIT);
        assertEq(bob.balance, 0.002e18);
        assertEq(musd.balanceOf(bob), 50e18);
    }

    function test_C57_OneClaimIsOpenAtMidnightAndNoMore() public {
        assertEq(faucet.claimsOpen(), 1);
        assertEq(faucet.nextOpenAt(), START);
        _claim(alice);
        assertEq(faucet.claimsOpen(), 0);
        assertEq(faucet.nextOpenAt(), START + STEP);

        vm.expectRevert(abi.encodeWithSelector(IFaucet.NoClaimOpen.selector, START + STEP));
        _claim(bob);
    }

    function test_C57_SecondClaimOpensOnTheSecondItIsReleased() public {
        _claim(alice);
        vm.warp(START + STEP - 1);
        assertEq(faucet.claimsOpen(), 0);
        vm.warp(START + STEP);
        assertEq(faucet.claimsOpen(), 1);
        _claim(bob);
        assertEq(faucet.claimsToday(), 2);
    }

    function test_C57_UnusedClaimsCarryOverWithinTheDay() public {
        vm.warp(START + 10 * STEP);
        assertEq(faucet.claimsOpen(), 11);
        _claim(alice);
        assertEq(faucet.claimsOpen(), 10);
        assertEq(faucet.nextOpenAt(), START + 10 * STEP);
    }

    function test_C57_WholeLimitIsOutByTheDaysLastSecond() public {
        vm.warp(START + 1 days - 1);
        assertEq(faucet.claimsOpen(), LIMIT);
    }

    function test_C57_EveryLimitReachesItselfInTheLastSecondAndNeverPassesIt() public {
        vm.warp(START + 1 days - 1);
        for (uint32 limit = 1; limit <= 500; ++limit) {
            vm.prank(owner);
            faucet.setDailyLimit(limit);
            assertEq(faucet.claimsOpen(), limit < FUNDED_KITS ? limit : FUNDED_KITS);
        }
    }

    function test_C57_ANewUtcDayStartsItsCountAtZero() public {
        _claim(alice);
        vm.warp(START + 1 days);
        assertEq(faucet.claimsToday(), 0);
        assertEq(faucet.claimsOpen(), 1);
        _claim(bob);
        assertEq(faucet.claimsOnDay(START / 1 days), 1);
        assertEq(faucet.claimsOnDay(START / 1 days + 1), 1);
    }

    function test_C57_UnusedClaimsDoNotCarryIntoTheNextDay() public {
        vm.warp(START + 1 days);
        assertEq(faucet.claimsOpen(), 1);
    }

    function test_C56_ClaimsOpenIsCappedByTheKitsTheFaucetCanPay() public {
        vm.warp(START + 1 days - 1);
        vm.deal(address(faucet), 3 * BTC_KIT);
        assertEq(faucet.claimsOpen(), 3);
        vm.prank(owner);
        faucet.withdraw(0, (FUNDED_KITS - 2) * MUSD_KIT);
        assertEq(faucet.claimsOpen(), 2);
    }

    function test_C56_ViewsReadZeroWhenPaused() public {
        vm.prank(owner);
        faucet.pause();
        assertEq(faucet.claimsOpen(), 0);
        assertEq(faucet.nextOpenAt(), 0);
    }

    function test_C56_ViewsReadZeroWhenShortOfBtc() public {
        vm.deal(address(faucet), BTC_KIT - 1);
        assertEq(faucet.claimsOpen(), 0);
        assertEq(faucet.nextOpenAt(), 0);
    }

    function test_C56_ViewsReadZeroWhenShortOfMusd() public {
        vm.prank(owner);
        faucet.withdraw(0, FUNDED_KITS * MUSD_KIT - (MUSD_KIT - 1));
        assertEq(faucet.claimsOpen(), 0);
        assertEq(faucet.nextOpenAt(), 0);
    }

    function test_C56_ViewsReadZeroWhenTheDailyLimitIsZero() public {
        vm.prank(owner);
        faucet.setDailyLimit(0);
        assertEq(faucet.claimsOpen(), 0);
        assertEq(faucet.nextOpenAt(), 0);
        vm.expectRevert(abi.encodeWithSelector(IFaucet.NoClaimOpen.selector, 0));
        _claim(alice);
    }

    function test_C56_LimitLoweredBelowTodaysCountReadsZeroNotARevert() public {
        vm.warp(START + 1 days - 1);
        _claim(alice);
        _claim(bob);
        _claim(stranger);
        vm.prank(owner);
        faucet.setDailyLimit(2);

        assertEq(faucet.claimsToday(), 3);
        assertEq(faucet.claimsOpen(), 0);
        assertEq(faucet.nextOpenAt(), START + 1 days);
        vm.expectRevert(abi.encodeWithSelector(IFaucet.NoClaimOpen.selector, START + 1 days));
        _claim(owner);
    }

    function test_C56_DayFullOpensAtTheNextMidnight() public {
        _claimsAtRelease(LIMIT);
        assertEq(faucet.claimsToday(), LIMIT);
        vm.warp(START + 1 days - 1);
        assertEq(faucet.claimsOpen(), 0);
        assertEq(faucet.nextOpenAt(), START + 1 days);
    }

    function test_C56_ViewsSurviveAMusdThatRevertsOrAnswersBadly() public {
        bytes memory balanceCall = abi.encodeCall(IERC20.balanceOf, (address(faucet)));

        vm.mockCallRevert(address(musd), balanceCall, "broken");
        assertEq(faucet.claimsOpen(), 0);
        assertEq(faucet.nextOpenAt(), 0);
        vm.expectRevert(abi.encodeWithSelector(IFaucet.NoClaimOpen.selector, 0));
        _claim(alice);
        vm.clearMockedCalls();

        vm.mockCall(address(musd), balanceCall, hex"01");
        assertEq(faucet.claimsOpen(), 0);
        assertEq(faucet.nextOpenAt(), 0);
        vm.clearMockedCalls();

        vm.etch(address(musd), "");
        assertEq(faucet.claimsOpen(), 0);
        assertEq(faucet.nextOpenAt(), 0);
    }

    function test_C55_ForwardsExactlyTheAllowanceToTheRecipient() public {
        GasProbeRecipient probe = new GasProbeRecipient();
        _claim(address(probe));
        assertGt(probe.gasAtEntry(), faucet.RECIPIENT_GAS() - 1);
        assertLe(probe.gasAtEntry(), faucet.RECIPIENT_GAS() + STIPEND);
    }

    function test_C55_LoopingRecipientCostsABoundedAmountAndChangesNothing() public {
        LoopingRecipient looper = new LoopingRecipient();
        (uint256 used, bool landed) = _claimGas(address(looper));

        assertFalse(landed);
        assertLt(used, WORST_CLAIM_GAS, "gas bounded");
        assertEq(looper.spins(), 0, "its work rolled back");
        _assertNothingMoved(address(looper));
    }

    function test_C55_OneMegabyteReturnCostsABoundedAmountAndChangesNothing() public {
        ReturnBombRecipient bomb = new ReturnBombRecipient(1_048_576);
        (uint256 used, bool landed) = _claimGas(address(bomb));

        assertFalse(landed, "1 MB of memory costs far more than the allowance");
        assertLt(used, WORST_CLAIM_GAS, "gas bounded");
        _assertNothingMoved(address(bomb));
    }

    function test_C55_ReturnDataThatFitsTheAllowanceIsNeverCopied() public {
        GasProbeRecipient plain = new GasProbeRecipient();
        (uint256 plainGas, bool plainLanded) = _claimGas(address(plain));
        vm.warp(START + STEP);
        ReturnBombRecipient bomb = new ReturnBombRecipient(100_000);
        (uint256 bombGas, bool bombLanded) = _claimGas(address(bomb));

        assertTrue(plainLanded);
        assertTrue(bombLanded, "100 KB fits the allowance, so the claim lands");
        // Copying 100 KB back into the faucet's frame would add about 28,000 gas on top of what the bomb itself spent.
        assertLt(bombGas, plainGas + 15_000, "the faucet paid nothing for the bytes");
        assertEq(address(bomb).balance, BTC_KIT);
        assertEq(musd.balanceOf(address(bomb)), MUSD_KIT);
    }

    function test_C55_CallbackThatFailsThePaymentRevertsWhole() public {
        ReenteringRecipient hostile = new ReenteringRecipient(faucet, alice, true);
        (uint256 used, bool landed) = _claimGas(address(hostile));

        assertFalse(landed);
        assertLt(used, WORST_CLAIM_GAS, "gas bounded");
        _assertNothingMoved(address(hostile));
        _assertNothingMoved(alice);
    }

    function test_C55_CallbackThatSwallowsTheRefusalGetsOneKitAndNoMore() public {
        ReenteringRecipient hostile = new ReenteringRecipient(faucet, alice, false);
        (uint256 used, bool landed) = _claimGas(address(hostile));

        assertTrue(landed);
        assertLt(used, WORST_CLAIM_GAS, "gas bounded");
        assertFalse(hostile.secondClaimLanded());
        assertEq(hostile.refusal(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(hostile).balance, BTC_KIT);
        assertEq(musd.balanceOf(address(hostile)), MUSD_KIT);
        assertFalse(faucet.claimed(alice));
        assertEq(faucet.claimsToday(), 1);
    }

    function test_C54_ReentrancyLockStopsARelayerThatCallsBackIn() public {
        ReenteringRelayer hostile = new ReenteringRelayer(faucet, alice);
        vm.prank(owner);
        faucet.setRelayer(address(hostile));

        hostile.claimForSelf();

        assertEq(hostile.refusal(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertFalse(faucet.claimed(alice));
        assertEq(address(hostile).balance, BTC_KIT);
        assertEq(faucet.claimsToday(), 1);
    }

    function test_C55_SafeStyleProxyWalletReceivesAFullKit() public {
        SafeStyleProxy wallet = new SafeStyleProxy(address(new SafeStyleSingleton()));

        vm.expectEmit(address(wallet));
        emit SafeReceived(address(faucet), BTC_KIT);
        (uint256 used, bool landed) = _claimGas(address(wallet));

        assertTrue(landed);
        assertEq(address(wallet).balance, BTC_KIT);
        assertEq(musd.balanceOf(address(wallet)), MUSD_KIT);
        assertTrue(faucet.claimed(address(wallet)));
        console.log("claim for a Safe-style proxy, gas", used);
    }

    function test_C55_SafeStyleReceiveFitsWellInsideTheAllowance() public {
        SafeStyleSingleton singleton = new SafeStyleSingleton();
        SafeStyleProxy wallet = new SafeStyleProxy(address(singleton));
        vm.deal(address(this), 1 ether);

        uint256 low;
        uint256 high = faucet.RECIPIENT_GAS();
        while (low < high) {
            uint256 mid = (low + high) / 2;
            // Each try starts cold, as a claim's one payment does.
            vm.cool(address(wallet));
            vm.cool(address(singleton));
            (bool ok,) = address(wallet).call{value: 1, gas: mid}("");
            if (ok) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        console.log("least allowance a Safe-style receive needs, on top of the stipend", low);
        assertLt(low, faucet.RECIPIENT_GAS() / 5);
    }

    function test_C58_SetKitAtTheCapsAndEmits() public {
        vm.expectEmit(address(faucet));
        emit KitSet(0.01e18, 100e18);
        vm.prank(owner);
        faucet.setKit(0.01e18, 100e18);
        assertEq(faucet.btcPerClaim(), 0.01e18);
        assertEq(faucet.musdPerClaim(), 100e18);
    }

    function test_C58_SetKitRefusesEmptyOverCapAndStrangers() public {
        vm.startPrank(owner);
        vm.expectRevert(IFaucet.KitEmpty.selector);
        faucet.setKit(0, MUSD_KIT);
        vm.expectRevert(IFaucet.KitEmpty.selector);
        faucet.setKit(BTC_KIT, 0);
        vm.expectRevert(IFaucet.KitTooLarge.selector);
        faucet.setKit(0.01e18 + 1, MUSD_KIT);
        vm.expectRevert(IFaucet.KitTooLarge.selector);
        faucet.setKit(BTC_KIT, 100e18 + 1);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relayer));
        vm.prank(relayer);
        faucet.setKit(BTC_KIT, MUSD_KIT);
    }

    function test_C58_SetDailyLimitAtTheCapAndZeroAndEmits() public {
        vm.expectEmit(address(faucet));
        emit DailyLimitSet(500);
        vm.prank(owner);
        faucet.setDailyLimit(500);
        assertEq(faucet.dailyLimit(), 500);

        vm.prank(owner);
        faucet.setDailyLimit(0);
        assertEq(faucet.dailyLimit(), 0);
    }

    function test_C58_SetDailyLimitRefusesOverCapAndStrangers() public {
        vm.expectRevert(IFaucet.LimitTooHigh.selector);
        vm.prank(owner);
        faucet.setDailyLimit(501);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relayer));
        vm.prank(relayer);
        faucet.setDailyLimit(1);
    }

    function test_SetRelayerMovesTheRightToClaimAndEmits() public {
        vm.expectEmit(address(faucet));
        emit RelayerSet(bob);
        vm.prank(owner);
        faucet.setRelayer(bob);
        assertEq(faucet.relayer(), bob);

        vm.expectRevert(IFaucet.NotRelayer.selector);
        vm.prank(relayer);
        faucet.claim(alice);
        vm.prank(bob);
        faucet.claim(alice);
        assertTrue(faucet.claimed(alice));
    }

    function test_SetRelayerRefusesZeroAndStrangers() public {
        vm.expectRevert(IFaucet.ZeroAddress.selector);
        vm.prank(owner);
        faucet.setRelayer(address(0));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relayer));
        vm.prank(relayer);
        faucet.setRelayer(relayer);
    }

    function test_C58_PauseAndUnpauseAreOwnerOnlyAndEmit() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relayer));
        vm.prank(relayer);
        faucet.pause();

        vm.expectEmit(address(faucet));
        emit Paused(owner);
        vm.prank(owner);
        faucet.pause();
        assertTrue(faucet.paused());

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(owner);
        faucet.pause();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relayer));
        vm.prank(relayer);
        faucet.unpause();

        vm.expectEmit(address(faucet));
        emit Unpaused(owner);
        vm.prank(owner);
        faucet.unpause();
        assertFalse(faucet.paused());

        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(owner);
        faucet.unpause();
    }

    function test_C58_PauseStopsClaimOnly() public {
        MockToken stray = new MockToken("STR");
        stray.mint(address(faucet), 5);
        vm.startPrank(owner);
        faucet.pause();
        faucet.setKit(0.002e18, 50e18);
        faucet.setDailyLimit(10);
        faucet.setRelayer(bob);
        faucet.withdraw(BTC_KIT, MUSD_KIT);
        faucet.rescueToken(address(stray), 5);
        vm.stopPrank();
        (bool ok,) = address(faucet).call{value: 0}("");
        assertTrue(ok, "funding still accepted");
        assertEq(owner.balance, BTC_KIT);
        assertEq(stray.balanceOf(owner), 5);
    }

    function test_C58_WithdrawPaysTheOwnerOnlyAndEmits() public {
        vm.expectEmit(address(faucet));
        emit Withdrawn(owner, 2 * BTC_KIT, 3 * MUSD_KIT);
        vm.prank(owner);
        faucet.withdraw(2 * BTC_KIT, 3 * MUSD_KIT);

        assertEq(owner.balance, 2 * BTC_KIT);
        assertEq(musd.balanceOf(owner), 3 * MUSD_KIT);
        assertEq(address(faucet).balance, (FUNDED_KITS - 2) * BTC_KIT);
        assertEq(musd.balanceOf(address(faucet)), FUNDED_KITS * MUSD_KIT - 3 * MUSD_KIT);
    }

    function test_C58_WithdrawOfZeroSkipsThatCoin() public {
        vm.prank(owner);
        faucet.withdraw(0, MUSD_KIT);
        assertEq(owner.balance, 0);
        vm.prank(owner);
        faucet.withdraw(BTC_KIT, 0);
        assertEq(owner.balance, BTC_KIT);
        assertEq(musd.balanceOf(owner), MUSD_KIT);
    }

    function test_C58_WithdrawRefusesStrangersAndTooMuch() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relayer));
        vm.prank(relayer);
        faucet.withdraw(1, 1);

        uint256 held = FUNDED_KITS * BTC_KIT;
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, held, held + 1));
        vm.prank(owner);
        faucet.withdraw(held + 1, 0);

        uint256 musdHeld = FUNDED_KITS * MUSD_KIT;
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(faucet), musdHeld, musdHeld + 1
            )
        );
        vm.prank(owner);
        faucet.withdraw(0, musdHeld + 1);
    }

    function test_C58_WithdrawBtcToAnOwnerThatRefusesReverts() public {
        RefusingRecipient refuser = new RefusingRecipient();
        vm.prank(owner);
        faucet.transferOwnership(address(refuser));
        vm.prank(address(refuser));
        faucet.acceptOwnership();

        vm.expectRevert(RefusingRecipient.Refused.selector);
        vm.prank(address(refuser));
        faucet.withdraw(1, 0);
    }

    function test_RescueSendsAStrayToTheOwnerAndEmits() public {
        MockToken stray = new MockToken("STR");
        stray.mint(address(faucet), 7);
        vm.expectEmit(address(faucet));
        emit Rescued(address(stray), owner, 7);
        vm.prank(owner);
        faucet.rescueToken(address(stray), 7);
        assertEq(stray.balanceOf(owner), 7);
    }

    function test_RescueRefusesMusdAndStrangers() public {
        vm.expectRevert(abi.encodeWithSelector(IFaucet.TokenNotRescuable.selector, address(musd)));
        vm.prank(owner);
        faucet.rescueToken(address(musd), 1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relayer));
        vm.prank(relayer);
        faucet.rescueToken(address(musd), 1);
    }

    function test_C58_PlainBtcAndMusdAreFundingCreditedToNobody() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(faucet).call{value: 3 * BTC_KIT}("");
        assertTrue(ok);
        musd.mint(alice, 3 * MUSD_KIT);
        vm.prank(alice);
        assertTrue(musd.transfer(address(faucet), 3 * MUSD_KIT));

        assertEq(address(faucet).balance, (FUNDED_KITS + 3) * BTC_KIT);
        assertEq(musd.balanceOf(address(faucet)), (FUNDED_KITS + 3) * MUSD_KIT);
        assertFalse(faucet.claimed(alice), "sending funds earns no claim state");
        assertEq(faucet.claimsToday(), 0);
    }

    function test_C58_OwnershipMovesInTwoSteps() public {
        vm.expectEmit(address(faucet));
        emit OwnershipTransferStarted(owner, bob);
        vm.prank(owner);
        faucet.transferOwnership(bob);
        assertEq(faucet.owner(), owner, "not moved until accepted");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        faucet.acceptOwnership();

        vm.prank(bob);
        faucet.acceptOwnership();
        assertEq(faucet.owner(), bob);
    }

    function test_C58_RenounceAlwaysReverts() public {
        vm.expectRevert(IFaucet.RenounceDisabled.selector);
        vm.prank(owner);
        faucet.renounceOwnership();
        vm.expectRevert(IFaucet.RenounceDisabled.selector);
        vm.prank(stranger);
        faucet.renounceOwnership();
        assertEq(faucet.owner(), owner);
    }
}

contract DeployFaucetChecksTest is Test {
    address internal constant TESTNET_MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    uint128 internal constant BTC_KIT = 0.001e18;
    uint128 internal constant MUSD_KIT = 25e18;
    uint32 internal constant LIMIT = 40;

    DeployFaucet internal script;
    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address internal keeper = makeAddr("keeper");
    address internal buyer = makeAddr("buyer");

    function setUp() public {
        script = new DeployFaucet();
        vm.etch(TESTNET_MUSD, address(new MockMUSD()).code);
    }

    function _deployed(address musd_, uint128 btc, uint128 musdAmount, uint32 limit) internal returns (Faucet) {
        return new Faucet(musd_, owner, relayer, btc, musdAmount, limit);
    }

    function _wallets(address first, address second) internal pure returns (address[] memory wallets) {
        wallets = new address[](3);
        wallets[0] = first;
        wallets[2] = second;
    }

    function test_C65_RelayerThatIsNoKnownWalletPasses() public view {
        script.checkRelayer(relayer, owner, _wallets(keeper, buyer));
    }

    function test_C65_RelayerMatchingTheOwnerIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(DeployFaucet.RelayerIsKnownWallet.selector, owner));
        script.checkRelayer(owner, owner, _wallets(keeper, buyer));
    }

    function test_C65_RelayerMatchingAnyListedWalletIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(DeployFaucet.RelayerIsKnownWallet.selector, keeper));
        script.checkRelayer(keeper, owner, _wallets(keeper, buyer));
        vm.expectRevert(abi.encodeWithSelector(DeployFaucet.RelayerIsKnownWallet.selector, buyer));
        script.checkRelayer(buyer, owner, _wallets(keeper, buyer));
    }

    function test_C82_ReadBackPassesForTheOrderedDeployment() public {
        script.checkDeployed(_deployed(TESTNET_MUSD, BTC_KIT, MUSD_KIT, LIMIT), owner, relayer);
    }

    function test_C82_ReadBackRefusesNoCode() public {
        Faucet nothing = Faucet(payable(makeAddr("no code here")));
        vm.expectRevert(abi.encodeWithSelector(DeployFaucet.MissingCode.selector, address(nothing)));
        script.checkDeployed(nothing, owner, relayer);
    }

    function test_C82_ReadBackRefusesAnotherMusd() public {
        address other = address(new MockMUSD());
        Faucet faucet = _deployed(other, BTC_KIT, MUSD_KIT, LIMIT);
        vm.expectRevert(abi.encodeWithSelector(DeployFaucet.WiringMismatch.selector, "Faucet.musd", TESTNET_MUSD, other));
        script.checkDeployed(faucet, owner, relayer);
    }

    function test_C82_ReadBackRefusesAKitOrLimitThatDiffers() public {
        Faucet wrongKit = _deployed(TESTNET_MUSD, BTC_KIT + 1, MUSD_KIT, LIMIT);
        vm.expectRevert(
            abi.encodeWithSelector(DeployFaucet.SettingMismatch.selector, "Faucet.btcPerClaim", BTC_KIT, BTC_KIT + 1)
        );
        script.checkDeployed(wrongKit, owner, relayer);

        Faucet wrongLimit = _deployed(TESTNET_MUSD, BTC_KIT, MUSD_KIT, LIMIT + 1);
        vm.expectRevert(
            abi.encodeWithSelector(DeployFaucet.SettingMismatch.selector, "Faucet.dailyLimit", LIMIT, LIMIT + 1)
        );
        script.checkDeployed(wrongLimit, owner, relayer);
    }

    function test_C82_ReadBackRefusesAStartedOwnershipTransfer() public {
        Faucet faucet = _deployed(TESTNET_MUSD, BTC_KIT, MUSD_KIT, LIMIT);
        vm.prank(owner);
        faucet.transferOwnership(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(DeployFaucet.WiringMismatch.selector, "Faucet.pendingOwner", address(0), relayer)
        );
        script.checkDeployed(faucet, owner, relayer);
    }

    function test_C82_ReadBackRefusesAPausedFaucet() public {
        Faucet faucet = _deployed(TESTNET_MUSD, BTC_KIT, MUSD_KIT, LIMIT);
        vm.prank(owner);
        faucet.pause();
        vm.expectRevert(abi.encodeWithSelector(DeployFaucet.SettingMismatch.selector, "Faucet.paused", 0, 1));
        script.checkDeployed(faucet, owner, relayer);
    }
}
