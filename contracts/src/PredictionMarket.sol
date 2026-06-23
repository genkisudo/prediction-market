// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReceiverTemplate} from "./interfaces/ReceiverTemplate.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  PredictionMarket
/// @notice Parimutuel YES/NO prediction market for World Cup outcomes, resolved
///         automatically by a Chainlink CRE workflow acting as the oracle.
///
///         Lifecycle:
///           1. Owner creates a market with a question, an off-chain `eventId`
///              (the key the oracle resolves against), a trading deadline and an
///              earliest resolution time.
///           2. Anyone stakes ETH on YES or NO before the trading deadline.
///           3. After `resolveTime`, the CRE workflow reads the verifiable match
///              result and delivers a signed report through the KeystoneForwarder,
///              which calls `onReport` -> `_processReport` to settle the market.
///           4. Winners call `claim()` to withdraw their stake plus a pro-rata
///              share of the losing pool (net of protocol fee). No manual settlement.
///
/// @dev    Escrow, resolution and payout are fully on-chain. The only trusted
///         off-chain component is the CRE DON, gated by the immutable forwarder.
contract PredictionMarket is ReceiverTemplate, Ownable, ReentrancyGuard {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum Outcome {
        Unresolved, // 0 - not yet settled
        Yes, // 1 - YES side wins
        No, // 2 - NO side wins
        Invalid // 3 - cancelled / void -> full refunds
    }

    struct Market {
        string question; // human-readable question
        string eventId; // off-chain key the oracle resolves against
        uint64 tradingDeadline; // no bets accepted at/after this timestamp
        uint64 resolveTime; // earliest timestamp the oracle may settle
        Outcome outcome; // result once resolved
        bool resolved; // settlement flag
        uint128 totalYes; // total ETH staked on YES
        uint128 totalNo; // total ETH staked on NO
    }

    /// @notice One settlement instruction decoded from a CRE report.
    struct Resolution {
        uint256 marketId;
        uint8 outcome; // must map to Outcome.Yes / No / Invalid
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Protocol fee in basis points taken from the losing pool on payout.
    uint16 public feeBps;
    /// @notice Max fee (10%) — hard cap enforced in the setter.
    uint16 public constant MAX_FEE_BPS = 1000;
    /// @notice Accrued protocol fees withdrawable by the owner.
    uint256 public accruedFees;

    uint256 public marketCount;
    mapping(uint256 => Market) private _markets;

    // marketId => user => staked amount per side
    mapping(uint256 => mapping(address => uint256)) public yesStake;
    mapping(uint256 => mapping(address => uint256)) public noStake;
    // marketId => user => already claimed
    mapping(uint256 => mapping(address => bool)) public claimed;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event MarketCreated(
        uint256 indexed marketId,
        string question,
        string eventId,
        uint64 tradingDeadline,
        uint64 resolveTime
    );
    event BetPlaced(uint256 indexed marketId, address indexed account, bool isYes, uint256 amount);
    event MarketResolved(uint256 indexed marketId, Outcome outcome, uint256 totalYes, uint256 totalNo);
    event Claimed(uint256 indexed marketId, address indexed account, uint256 payout);
    event FeeUpdated(uint16 feeBps);
    event FeesWithdrawn(address indexed to, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error InvalidMarket(uint256 marketId);
    error TradingClosed(uint256 marketId);
    error ZeroStake();
    error AlreadyResolved(uint256 marketId);
    error NotResolved(uint256 marketId);
    error TooEarly(uint256 marketId);
    error BadOutcome(uint8 outcome);
    error NothingToClaim(uint256 marketId, address account);
    error AlreadyClaimed(uint256 marketId, address account);
    error BadDeadlines();
    error FeeTooHigh(uint16 feeBps);
    error TransferFailed();

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    /// @param forwarder The CRE KeystoneForwarder for the target chain.
    /// @param initialOwner The protocol owner (market creator / fee recipient).
    /// @param initialFeeBps Protocol fee in bps (<= MAX_FEE_BPS).
    constructor(address forwarder, address initialOwner, uint16 initialFeeBps)
        ReceiverTemplate(forwarder)
        Ownable(initialOwner)
    {
        if (initialFeeBps > MAX_FEE_BPS) revert FeeTooHigh(initialFeeBps);
        feeBps = initialFeeBps;
        emit FeeUpdated(initialFeeBps);
    }

    // ---------------------------------------------------------------------
    // Market creation
    // ---------------------------------------------------------------------

    /// @notice Create a new YES/NO market.
    /// @param question Human-readable question, e.g. "Will Ronaldo win his first World Cup?".
    /// @param eventId Off-chain identifier the oracle resolves against.
    /// @param tradingDeadline Timestamp after which no bets are accepted.
    /// @param resolveTime Earliest timestamp the oracle may settle (>= tradingDeadline).
    function createMarket(
        string calldata question,
        string calldata eventId,
        uint64 tradingDeadline,
        uint64 resolveTime
    ) external onlyOwner returns (uint256 marketId) {
        if (tradingDeadline <= block.timestamp || resolveTime < tradingDeadline) {
            revert BadDeadlines();
        }

        marketId = ++marketCount;
        Market storage m = _markets[marketId];
        m.question = question;
        m.eventId = eventId;
        m.tradingDeadline = tradingDeadline;
        m.resolveTime = resolveTime;

        emit MarketCreated(marketId, question, eventId, tradingDeadline, resolveTime);
    }

    // ---------------------------------------------------------------------
    // Betting (escrow)
    // ---------------------------------------------------------------------

    /// @notice Stake ETH on the YES outcome of a market.
    function betYes(uint256 marketId) external payable {
        _bet(marketId, true);
    }

    /// @notice Stake ETH on the NO outcome of a market.
    function betNo(uint256 marketId) external payable {
        _bet(marketId, false);
    }

    function _bet(uint256 marketId, bool isYes) internal {
        Market storage m = _markets[marketId];
        if (marketId == 0 || marketId > marketCount) revert InvalidMarket(marketId);
        if (msg.value == 0) revert ZeroStake();
        if (m.resolved || block.timestamp >= m.tradingDeadline) revert TradingClosed(marketId);

        if (isYes) {
            yesStake[marketId][msg.sender] += msg.value;
            m.totalYes += uint128(msg.value);
        } else {
            noStake[marketId][msg.sender] += msg.value;
            m.totalNo += uint128(msg.value);
        }

        emit BetPlaced(marketId, msg.sender, isYes, msg.value);
    }

    // ---------------------------------------------------------------------
    // Oracle resolution (CRE -> KeystoneForwarder -> onReport)
    // ---------------------------------------------------------------------

    /// @inheritdoc ReceiverTemplate
    /// @dev report is `Resolution[]` ABI-encoded by the CRE workflow.
    function _processReport(bytes calldata, bytes calldata report) internal override {
        Resolution[] memory resolutions = abi.decode(report, (Resolution[]));
        uint256 len = resolutions.length;
        for (uint256 i = 0; i < len; i++) {
            _resolve(resolutions[i].marketId, resolutions[i].outcome);
        }
    }

    function _resolve(uint256 marketId, uint8 rawOutcome) internal {
        Market storage m = _markets[marketId];
        if (marketId == 0 || marketId > marketCount) revert InvalidMarket(marketId);
        if (m.resolved) revert AlreadyResolved(marketId);
        if (block.timestamp < m.resolveTime) revert TooEarly(marketId);
        if (rawOutcome < uint8(Outcome.Yes) || rawOutcome > uint8(Outcome.Invalid)) {
            revert BadOutcome(rawOutcome);
        }

        Outcome outcome = Outcome(rawOutcome);

        // If the declared winning side has no stake, no one could ever claim the
        // pool. Void the market so both sides are refundable instead of stranding funds.
        if (outcome == Outcome.Yes && m.totalYes == 0) outcome = Outcome.Invalid;
        if (outcome == Outcome.No && m.totalNo == 0) outcome = Outcome.Invalid;

        m.outcome = outcome;
        m.resolved = true;
        _accrueFee(m);

        emit MarketResolved(marketId, outcome, m.totalYes, m.totalNo);
    }

    /// @notice Owner safety valve: void a market that the oracle never resolved,
    ///         enabling refunds. Only callable well after the resolve window opened.
    /// @dev Guards against permanently stuck escrow if the off-chain feed disappears.
    function voidMarket(uint256 marketId) external onlyOwner {
        Market storage m = _markets[marketId];
        if (marketId == 0 || marketId > marketCount) revert InvalidMarket(marketId);
        if (m.resolved) revert AlreadyResolved(marketId);
        // Allow voiding only once 7 days past the intended resolution time.
        if (block.timestamp < uint256(m.resolveTime) + 7 days) revert TooEarly(marketId);

        m.outcome = Outcome.Invalid;
        m.resolved = true;
        emit MarketResolved(marketId, Outcome.Invalid, m.totalYes, m.totalNo);
    }

    // ---------------------------------------------------------------------
    // Payout
    // ---------------------------------------------------------------------

    /// @notice Claim winnings (or refund for a voided market). Idempotent per user.
    function claim(uint256 marketId) external nonReentrant returns (uint256 payout) {
        Market storage m = _markets[marketId];
        if (marketId == 0 || marketId > marketCount) revert InvalidMarket(marketId);
        if (!m.resolved) revert NotResolved(marketId);
        if (claimed[marketId][msg.sender]) revert AlreadyClaimed(marketId, msg.sender);

        payout = _payoutOf(m, marketId, msg.sender);
        if (payout == 0) revert NothingToClaim(marketId, msg.sender);

        claimed[marketId][msg.sender] = true;

        (bool ok,) = msg.sender.call{value: payout}("");
        if (!ok) revert TransferFailed();

        emit Claimed(marketId, msg.sender, payout);
    }

    /// @notice View the amount `account` could claim from a resolved market.
    function previewPayout(uint256 marketId, address account) external view returns (uint256) {
        Market storage m = _markets[marketId];
        if (!m.resolved || claimed[marketId][account]) return 0;
        return _payoutOf(m, marketId, account);
    }

    function _payoutOf(Market storage m, uint256 marketId, address account) internal view returns (uint256) {
        uint256 staked;
        uint256 winningPool;
        uint256 losingPool;

        if (m.outcome == Outcome.Invalid) {
            // Refund both sides at face value, no fee.
            return yesStake[marketId][account] + noStake[marketId][account];
        } else if (m.outcome == Outcome.Yes) {
            staked = yesStake[marketId][account];
            winningPool = m.totalYes;
            losingPool = m.totalNo;
        } else if (m.outcome == Outcome.No) {
            staked = noStake[marketId][account];
            winningPool = m.totalNo;
            losingPool = m.totalYes;
        } else {
            return 0;
        }

        if (staked == 0 || winningPool == 0) return 0;

        // Fee is taken from the losing pool only; winners always recover their stake.
        uint256 fee = (losingPool * feeBps) / 10_000;
        uint256 distributable = losingPool - fee;
        uint256 profit = (distributable * staked) / winningPool;
        return staked + profit;
    }

    // ---------------------------------------------------------------------
    // Oracle read surface (consumed by the CRE workflow)
    // ---------------------------------------------------------------------

    /// @notice Markets that are eligible for resolution right now.
    /// @dev The CRE workflow reads this, fetches each `eventId` result off-chain,
    ///      and writes back a `Resolution[]` report. View call -> no gas in prod.
    function getResolvableMarkets() external view returns (uint256[] memory ids, string[] memory eventIds) {
        uint256 n;
        for (uint256 i = 1; i <= marketCount; i++) {
            Market storage m = _markets[i];
            if (!m.resolved && block.timestamp >= m.resolveTime) n++;
        }

        ids = new uint256[](n);
        eventIds = new string[](n);
        uint256 j;
        for (uint256 i = 1; i <= marketCount; i++) {
            Market storage m = _markets[i];
            if (!m.resolved && block.timestamp >= m.resolveTime) {
                ids[j] = i;
                eventIds[j] = m.eventId;
                j++;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getMarket(uint256 marketId)
        external
        view
        returns (
            string memory question,
            string memory eventId,
            uint64 tradingDeadline,
            uint64 resolveTime,
            Outcome outcome,
            bool resolved,
            uint256 totalYes,
            uint256 totalNo
        )
    {
        Market storage m = _markets[marketId];
        return (m.question, m.eventId, m.tradingDeadline, m.resolveTime, m.outcome, m.resolved, m.totalYes, m.totalNo);
    }

    function getPosition(uint256 marketId, address account)
        external
        view
        returns (uint256 yes, uint256 no, bool hasClaimed)
    {
        return (yesStake[marketId][account], noStake[marketId][account], claimed[marketId][account]);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps);
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    /// @notice Withdraw fees accrued from resolved markets. Lazily realizes the fee
    ///         from each resolved, non-void market the first time it is settled.
    /// @dev Fees are computed at resolution-independent payout time; to keep claim()
    ///      gas low we accrue on resolution via _accrueFee. Here we just sweep.
    function withdrawFees(address to) external onlyOwner nonReentrant {
        uint256 amount = accruedFees;
        accruedFees = 0;
        if (amount == 0) revert NothingToClaim(0, to);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit FeesWithdrawn(to, amount);
    }

    /// @dev Realize the protocol fee for a market into `accruedFees`. Called when a
    ///      market resolves to a winning side with a non-empty losing pool.
    function _accrueFee(Market storage m) internal {
        if (m.outcome == Outcome.Yes || m.outcome == Outcome.No) {
            uint256 losingPool = m.outcome == Outcome.Yes ? m.totalNo : m.totalYes;
            accruedFees += (losingPool * feeBps) / 10_000;
        }
    }
}
