// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Faucet against real Mezo testnet state: the real MUSD token, moved by a real holder. It deploys a new Faucet on a
// fork, funds it, claims for an address with no history, and checks the native balance and the MUSD arrive. It also
// checks that a recipient the real MUSD refuses leaves the claim whole, and what the faucet's views read on the
// fork's own clock.
// It does NOT cover: the faucet deployed by DeployFaucet or a real signed claim (script/faucet-live.sh proves those
// on the live network), the BTC ERC-20 view (a precompile the local EVM cannot run; the faucet never reads it), real
// BTC moving through mezod's own ledger (vm.deal sets the fork's native balance), or hostile recipients
// (test/unit/Faucet.t.sol).

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Faucet} from "../../src/Faucet.sol";
import {IFaucet} from "../../src/interfaces/IFaucet.sol";
import {ForkNode} from "../utils/ForkNode.sol";

contract FaucetForkTest is Test {
    address internal constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    /// @dev Held about 38 million test MUSD on 2026-11-05, the largest holder that is a plain wallet.
    address internal constant MUSD_HOLDER = 0x401d68969c9afAdeEc0e9fE6B67221247CFa642F;
    uint128 internal constant BTC_KIT = 0.001e18;
    uint128 internal constant MUSD_KIT = 25e18;
    uint32 internal constant LIMIT = 40;
    uint256 internal constant FUNDED_KITS = 3;

    IERC20 internal musd = IERC20(MUSD);
    Faucet internal faucet;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address internal funder = makeAddr("funder");
    address internal fresh = makeAddr("a wallet with no history");

    function setUp() public {
        ForkNode.selectTestnet();
        faucet = new Faucet(MUSD, owner, relayer, BTC_KIT, MUSD_KIT, LIMIT);

        vm.prank(MUSD_HOLDER);
        assertTrue(musd.transfer(address(faucet), FUNDED_KITS * MUSD_KIT));
        vm.deal(funder, FUNDED_KITS * BTC_KIT);
        vm.prank(funder);
        (bool ok,) = address(faucet).call{value: FUNDED_KITS * BTC_KIT}("");
        assertTrue(ok);
    }

    function test_ClaimPaysAFreshAddressRealMusdAndNativeBtc() public {
        assertEq(fresh.code.length, 0, "no code at the fresh address");
        assertEq(fresh.balance, 0, "no BTC at the fresh address");
        assertEq(musd.balanceOf(fresh), 0, "no MUSD at the fresh address");
        assertGt(faucet.claimsOpen(), 0);

        vm.prank(relayer);
        uint256 before = gasleft();
        faucet.claim(fresh);
        console.log("claim for a fresh address on the fork, gas", before - gasleft());

        assertEq(fresh.balance, BTC_KIT);
        assertEq(musd.balanceOf(fresh), MUSD_KIT);
        assertEq(address(faucet).balance, (FUNDED_KITS - 1) * BTC_KIT);
        assertEq(musd.balanceOf(address(faucet)), (FUNDED_KITS - 1) * MUSD_KIT);
        assertTrue(faucet.claimed(fresh));
        assertEq(faucet.claimsToday(), 1);

        vm.expectRevert(abi.encodeWithSelector(IFaucet.AlreadyClaimed.selector, fresh));
        vm.prank(relayer);
        faucet.claim(fresh);
    }

    /// @dev Answers one of the threat model's open questions: real MUSD refuses its own address as a recipient, and
    ///      that refusal must leave the claim unspent. The direct transfer comes first because MUSD has no receive, so
    ///      the claim alone would also revert at the BTC payment if MUSD took the tokens.
    function test_C54_RecipientRealMusdRefusesLeavesTheClaimWhole() public {
        vm.prank(MUSD_HOLDER);
        vm.expectRevert();
        // The call is expected to revert, so there is no return value to check.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        musd.transfer(MUSD, 1);

        vm.expectRevert();
        vm.prank(relayer);
        faucet.claim(MUSD);

        assertFalse(faucet.claimed(MUSD));
        assertEq(faucet.claimsToday(), 0);
        assertEq(address(faucet).balance, FUNDED_KITS * BTC_KIT);
        assertEq(musd.balanceOf(address(faucet)), FUNDED_KITS * MUSD_KIT);
    }

    function test_C56_ViewsMatchTheReleaseRuleOnTheForksClock() public view {
        uint256 elapsed = vm.getBlockTimestamp() % 1 days;
        uint256 share = uint256(LIMIT) * elapsed / 1 days + 1;
        uint256 released = share < LIMIT ? share : LIMIT;

        assertEq(faucet.claimsOpen(), released < FUNDED_KITS ? released : FUNDED_KITS);
        assertEq(faucet.nextOpenAt(), vm.getBlockTimestamp());
        assertEq(faucet.claimsToday(), 0);
    }
}
