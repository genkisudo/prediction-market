// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {ReceiverTemplate} from "../src/interfaces/ReceiverTemplate.sol";

contract PredictionMarketTest is Test {
    PredictionMarket internal market;

    address internal forwarder = address(0xF0);
    address internal owner = address(0xA0A);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0);
    address internal carol = address(0xC0);

    uint16 internal constant FEE_BPS = 200; // 2%

    function setUp() public {
        vm.prank(owner);
        market = new PredictionMarket(forwarder, owner, FEE_BPS);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    // ----- helpers --------------------------------------------------------

    function _createMarket() internal returns (uint256 id) {
        vm.prank(owner);
        id = market.createMarket(
            "Will Ronaldo win his first World Cup?",
            "wc2026-ronaldo-champion",
            uint64(block.timestamp + 1 days),
            uint64(block.timestamp + 2 days)
        );
    }

    function _deliverReport(uint256 marketId, uint8 outcome) internal {
        PredictionMarket.Resolution[] memory r = new PredictionMarket.Resolution[](1);
        r[0] = PredictionMarket.Resolution({marketId: marketId, outcome: outcome});
        vm.prank(forwarder);
        market.onReport("", abi.encode(r));
    }

    // ----- creation -------------------------------------------------------

    function test_createMarket() public {
        uint256 id = _createMarket();
        assertEq(id, 1);
        assertEq(market.marketCount(), 1);
        (string memory q,, uint64 td, uint64 rt, PredictionMarket.Outcome o, bool resolved,,) = market.getMarket(id);
        assertEq(q, "Will Ronaldo win his first World Cup?");
        assertEq(td, uint64(block.timestamp + 1 days));
        assertEq(rt, uint64(block.timestamp + 2 days));
        assertEq(uint8(o), uint8(PredictionMarket.Outcome.Unresolved));
        assertFalse(resolved);
    }

    function test_createMarket_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        market.createMarket("q", "e", uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days));
    }

    function test_createMarket_badDeadlines() public {
        vm.startPrank(owner);
        // trading deadline in the past
        vm.expectRevert(PredictionMarket.BadDeadlines.selector);
        market.createMarket("q", "e", uint64(block.timestamp), uint64(block.timestamp + 1 days));
        // resolve before trading deadline
        vm.expectRevert(PredictionMarket.BadDeadlines.selector);
        market.createMarket("q", "e", uint64(block.timestamp + 2 days), uint64(block.timestamp + 1 days));
        vm.stopPrank();
    }

    // ----- betting --------------------------------------------------------

    function test_bet_escrowsAndTracks() public {
        uint256 id = _createMarket();

        vm.prank(alice);
        market.betYes{value: 1 ether}(id);
        vm.prank(bob);
        market.betNo{value: 2 ether}(id);

        assertEq(address(market).balance, 3 ether);
        (uint256 yes, uint256 no,) = market.getPosition(id, alice);
        assertEq(yes, 1 ether);
        assertEq(no, 0);
        (,, uint64 td, uint64 rt,,, uint256 totalYes, uint256 totalNo) = market.getMarket(id);
        td;
        rt;
        assertEq(totalYes, 1 ether);
        assertEq(totalNo, 2 ether);
    }

    function test_bet_zeroReverts() public {
        uint256 id = _createMarket();
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.ZeroStake.selector);
        market.betYes{value: 0}(id);
    }

    function test_bet_afterDeadlineReverts() public {
        uint256 id = _createMarket();
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.TradingClosed.selector, id));
        market.betYes{value: 1 ether}(id);
    }

    function test_bet_invalidMarketReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.InvalidMarket.selector, uint256(99)));
        market.betYes{value: 1 ether}(99);
    }

    // ----- resolution -----------------------------------------------------

    function test_onReport_onlyForwarder() public {
        uint256 id = _createMarket();
        PredictionMarket.Resolution[] memory r = new PredictionMarket.Resolution[](1);
        r[0] = PredictionMarket.Resolution({marketId: id, outcome: 1});
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.UnauthorizedForwarder.selector, alice, forwarder));
        market.onReport("", abi.encode(r));
    }

    function test_onReport_resolvesMarket() public {
        uint256 id = _createMarket();
        vm.prank(alice);
        market.betYes{value: 1 ether}(id);
        vm.warp(block.timestamp + 2 days);

        _deliverReport(id, uint8(PredictionMarket.Outcome.Yes));

        (,,,, PredictionMarket.Outcome o, bool resolved,,) = market.getMarket(id);
        assertTrue(resolved);
        assertEq(uint8(o), uint8(PredictionMarket.Outcome.Yes));
    }

    function test_onReport_batchResolves() public {
        uint256 id1 = _createMarket();
        uint256 id2 = _createMarket();
        vm.prank(alice);
        market.betYes{value: 1 ether}(id1);
        vm.prank(bob);
        market.betNo{value: 1 ether}(id2);
        vm.warp(block.timestamp + 2 days);

        PredictionMarket.Resolution[] memory r = new PredictionMarket.Resolution[](2);
        r[0] = PredictionMarket.Resolution({marketId: id1, outcome: 1});
        r[1] = PredictionMarket.Resolution({marketId: id2, outcome: 2});
        vm.prank(forwarder);
        market.onReport("", abi.encode(r));

        (,,,,, bool r1,,) = market.getMarket(id1);
        (,,,,, bool r2,,) = market.getMarket(id2);
        assertTrue(r1);
        assertTrue(r2);
    }

    function test_onReport_tooEarlyReverts() public {
        uint256 id = _createMarket();
        PredictionMarket.Resolution[] memory r = new PredictionMarket.Resolution[](1);
        r[0] = PredictionMarket.Resolution({marketId: id, outcome: 1});
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.TooEarly.selector, id));
        market.onReport("", abi.encode(r));
    }

    function test_onReport_alreadyResolvedReverts() public {
        uint256 id = _createMarket();
        vm.prank(alice);
        market.betYes{value: 1 ether}(id);
        vm.warp(block.timestamp + 2 days);
        _deliverReport(id, 1);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.AlreadyResolved.selector, id));
        _deliverReport(id, 1);
    }

    function test_onReport_badOutcomeReverts() public {
        uint256 id = _createMarket();
        vm.warp(block.timestamp + 2 days);
        PredictionMarket.Resolution[] memory r = new PredictionMarket.Resolution[](1);
        r[0] = PredictionMarket.Resolution({marketId: id, outcome: 4});
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.BadOutcome.selector, uint8(4)));
        market.onReport("", abi.encode(r));
    }

    // ----- payout ---------------------------------------------------------

    function test_claim_parimutuelYesWins() public {
        uint256 id = _createMarket();
        vm.prank(alice);
        market.betYes{value: 1 ether}(id);
        vm.prank(bob);
        market.betYes{value: 2 ether}(id);
        vm.prank(carol);
        market.betNo{value: 2 ether}(id);

        vm.warp(block.timestamp + 2 days);
        _deliverReport(id, uint8(PredictionMarket.Outcome.Yes));

        // losingPool = 2 ETH, fee = 2% = 0.04 ETH, distributable = 1.96 ETH.
        // Mirror the contract's integer (floor) arithmetic exactly.
        uint256 losingPool = 2 ether;
        uint256 winningPool = 3 ether;
        uint256 distributable = losingPool - (losingPool * FEE_BPS) / 10_000;
        uint256 expectedAlice = uint256(1 ether) + (distributable * uint256(1 ether)) / winningPool;
        uint256 expectedBob = uint256(2 ether) + (distributable * uint256(2 ether)) / winningPool;

        assertEq(market.previewPayout(id, alice), expectedAlice);
        assertEq(market.previewPayout(id, bob), expectedBob);
        assertEq(market.previewPayout(id, carol), 0);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        uint256 paid = market.claim(id);
        assertEq(paid, expectedAlice);
        assertEq(alice.balance, balBefore + expectedAlice);

        vm.prank(bob);
        market.claim(id);

        // carol (loser) cannot claim
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.NothingToClaim.selector, id, carol));
        market.claim(id);

        // fee accrued = 0.04 ETH
        assertEq(market.accruedFees(), 0.04 ether);
    }

    function test_claim_noWins() public {
        uint256 id = _createMarket();
        vm.prank(alice);
        market.betNo{value: 4 ether}(id);
        vm.prank(bob);
        market.betYes{value: 1 ether}(id);

        vm.warp(block.timestamp + 2 days);
        _deliverReport(id, uint8(PredictionMarket.Outcome.No));

        // losingPool = 1 ETH, fee = 0.02 ETH, distributable 0.98; alice owns all of NO pool
        uint256 distributable = uint256(1 ether) - (uint256(1 ether) * FEE_BPS) / 10_000;
        uint256 expectedAlice = uint256(4 ether) + (distributable * uint256(4 ether)) / uint256(4 ether);
        assertEq(market.previewPayout(id, alice), expectedAlice);
        vm.prank(alice);
        assertEq(market.claim(id), expectedAlice);
    }

    function test_claim_doubleClaimReverts() public {
        uint256 id = _createMarket();
        vm.prank(alice);
        market.betYes{value: 1 ether}(id);
        vm.prank(carol);
        market.betNo{value: 1 ether}(id);
        vm.warp(block.timestamp + 2 days);
        _deliverReport(id, 1);

        vm.prank(alice);
        market.claim(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.AlreadyClaimed.selector, id, alice));
        market.claim(id);
    }

    function test_claim_beforeResolveReverts() public {
        uint256 id = _createMarket();
        vm.prank(alice);
        market.betYes{value: 1 ether}(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.NotResolved.selector, id));
        market.claim(id);
    }

    // ----- invalid / void -------------------------------------------------

    function test_invalidOutcome_refundsBothSides() public {
        uint256 id = _createMarket();
        vm.prank(alice);
        market.betYes{value: 1 ether}(id);
        vm.prank(carol);
        market.betNo{value: 3 ether}(id);
        vm.warp(block.timestamp + 2 days);

        _deliverReport(id, uint8(PredictionMarket.Outcome.Invalid));

        assertEq(market.previewPayout(id, alice), 1 ether);
        assertEq(market.previewPayout(id, carol), 3 ether);
        assertEq(market.accruedFees(), 0);

        vm.prank(alice);
        market.claim(id);
        vm.prank(carol);
        market.claim(id);
    }

    function test_resolve_winningSideEmpty_becomesInvalid() public {
        uint256 id = _createMarket();
        // only NO has stake, but oracle says YES -> auto-void so NO is refundable
        vm.prank(carol);
        market.betNo{value: 2 ether}(id);
        vm.warp(block.timestamp + 2 days);

        _deliverReport(id, uint8(PredictionMarket.Outcome.Yes));

        (,,,, PredictionMarket.Outcome o,,,) = market.getMarket(id);
        assertEq(uint8(o), uint8(PredictionMarket.Outcome.Invalid));
        assertEq(market.previewPayout(id, carol), 2 ether);
    }

    function test_voidMarket_afterGracePeriod() public {
        uint256 id = _createMarket();
        vm.prank(alice);
        market.betYes{value: 1 ether}(id);

        // before grace period: reverts
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.TooEarly.selector, id));
        market.voidMarket(id);

        // after 7 days past resolveTime: ok
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        market.voidMarket(id);
        assertEq(market.previewPayout(id, alice), 1 ether);
    }

    // ----- fees -----------------------------------------------------------

    function test_withdrawFees() public {
        uint256 id = _createMarket();
        vm.prank(alice);
        market.betYes{value: 1 ether}(id);
        vm.prank(carol);
        market.betNo{value: 2 ether}(id);
        vm.warp(block.timestamp + 2 days);
        _deliverReport(id, 1);

        assertEq(market.accruedFees(), 0.04 ether);
        uint256 balBefore = owner.balance;
        vm.prank(owner);
        market.withdrawFees(owner);
        assertEq(owner.balance, balBefore + 0.04 ether);
        assertEq(market.accruedFees(), 0);
    }

    function test_setFee_capEnforced() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.FeeTooHigh.selector, uint16(1001)));
        market.setFeeBps(1001);
    }

    // ----- oracle read surface -------------------------------------------

    function test_getResolvableMarkets() public {
        uint256 id1 = _createMarket();
        uint256 id2 = _createMarket();

        // none resolvable yet
        (uint256[] memory ids,) = market.getResolvableMarkets();
        assertEq(ids.length, 0);

        vm.warp(block.timestamp + 2 days);
        (ids,) = market.getResolvableMarkets();
        assertEq(ids.length, 2);
        assertEq(ids[0], id1);
        assertEq(ids[1], id2);

        // resolve one, the other remains
        _deliverReport(id1, uint8(PredictionMarket.Outcome.Invalid));
        (ids,) = market.getResolvableMarkets();
        assertEq(ids.length, 1);
        assertEq(ids[0], id2);
    }

    function test_supportsInterface() public view {
        assertTrue(market.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(market.supportsInterface(type(IERC165).interfaceId));
        assertFalse(market.supportsInterface(0xffffffff));
    }
}
