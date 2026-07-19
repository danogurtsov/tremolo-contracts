// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Variance} from "../types/Variance.sol";

/// @title IVarianceMarket
/// @notice External surface of the variance swap market: types, events and errors.
interface IVarianceMarket {
    // =====================================================================
    // Types
    // =====================================================================

    enum State {
        NONE,
        SUBSCRIBING,
        ACTIVE,
        SETTLED,
        VOIDED,
        CANCELLED
    }

    enum Side {
        LONG,
        SHORT
    }

    /// @notice Why a series returned deposits instead of paying a formula.
    enum VoidReason {
        SPARSE_SERIES,
        SOURCE_REVERTED
    }

    /// @param observer Price source adapter. Immutable for the life of the series.
    /// @param source Address the adapter reads, e.g. a Uniswap V3 pool. Immutable.
    /// @param collateral Token both sides deposit and are paid in.
    /// @param startTime When subscription closes and measurement begins.
    /// @param expiry When measurement ends and settlement becomes possible.
    /// @param samples Points on the observation grid.
    /// @param minCompletenessBps Minimum share of grid points that must correspond to genuine
    ///        recordings at the source. Below this, the series voids instead of settling on a
    ///        series that is mostly interpolation.
    /// @param capMultiple WAD-scaled cap on the payout, as a multiple of the strike.
    /// @param strike Strike variance, fixed at creation.
    /// @param notionalPerUnit Collateral tokens per 1.0 of variance, per whole unit (1e18).
    struct SeriesParams {
        address observer;
        address source;
        address collateral;
        uint64 startTime;
        uint64 expiry;
        uint16 samples;
        uint16 minCompletenessBps;
        uint64 capMultiple;
        Variance strike;
        uint256 notionalPerUnit;
    }

    /// @dev Storage form. Immutable parameters and mutable bookkeeping are kept in one struct
    ///      on purpose: everything about a series should be readable in a single call, which
    ///      is what an indexer and a UI both want.
    struct Series {
        address observer;
        address source;
        address collateral;
        uint64 startTime;
        uint64 expiry;
        uint16 samples;
        uint16 minCompletenessBps;
        uint64 capMultiple;
        State state;
        Variance strike;
        uint256 notionalPerUnit;
        uint256 subscribedLong;
        uint256 subscribedShort;
        uint256 matchedUnits;
        uint256 matchedAtActivation;
        uint256 longAtActivation;
        uint256 shortAtActivation;
        Variance realizedVariance;
    }

    // =====================================================================
    // Events
    // =====================================================================

    event SeriesCreated(
        uint256 indexed seriesId,
        address indexed observer,
        address indexed source,
        address collateral,
        Variance strike,
        uint64 startTime,
        uint64 expiry
    );
    event Subscribed(
        uint256 indexed seriesId, Side indexed side, address indexed account, uint256 units, uint256 amount
    );
    event Unsubscribed(
        uint256 indexed seriesId, Side indexed side, address indexed account, uint256 units, uint256 amount
    );
    event SeriesActivated(
        uint256 indexed seriesId, uint256 matchedUnits, uint256 longAtActivation, uint256 shortAtActivation
    );
    event SeriesCancelled(uint256 indexed seriesId);
    event PositionsMinted(
        uint256 indexed seriesId, Side indexed side, address indexed account, uint256 minted, uint256 refunded
    );
    event Netted(uint256 indexed seriesId, address indexed account, uint256 units, uint256 released);
    event SeriesSettled(uint256 indexed seriesId, Variance realizedVariance, address indexed caller);
    event SeriesVoided(uint256 indexed seriesId, VoidReason reason);
    event Redeemed(
        uint256 indexed seriesId,
        Side indexed side,
        address indexed account,
        address to,
        uint256 units,
        uint256 amount
    );
    event CreationPauseSet(bool paused);
    event GuardianTransferStarted(address indexed current, address indexed pending);
    event GuardianSet(address indexed guardian);

    // =====================================================================
    // Errors
    // =====================================================================

    error CreationPaused();
    error ZeroAddress();
    error StartInPast();
    error ExpiryBeforeStart();
    error InvalidWindow(uint32 window);
    error InvalidSamples(uint16 samples);
    error GridStepTooSmall(uint32 step);
    error InvalidStrike(uint256 strike);
    error InvalidCap(uint64 capMultiple);
    error ZeroNotional();
    error InvalidCompleteness(uint16 bps);
    error DegenerateCollateral();
    error WrongState(State state);
    error SubscriptionClosed();
    error ZeroUnits();
    error InsufficientSubscription(uint256 held, uint256 requested);
    error InsufficientPosition();
    error NothingToMint();
    error TooEarly();
    error NotGuardian();
    error NotPendingGuardian();
    error ObserverHasNoCode(address observer);
    error ActivationWindowClosed();
    error CollateralShortfall(uint256 expected, uint256 received);
    error NegativePrice(int256 value);
    error ExceedsDepthLimit(uint256 requested, uint256 limit);
    error CollateralNotQuoteToken(address collateral, address expected);

    // =====================================================================
    // Functions
    // =====================================================================

    function createSeries(SeriesParams calldata params) external returns (uint256 seriesId);
    function openImmediate(SeriesParams calldata params, address longSide, address shortSide, uint256 units)
        external
        returns (uint256 seriesId);
    function subscribe(uint256 seriesId, Side side, uint256 units) external;
    function unsubscribe(uint256 seriesId, Side side, uint256 units) external;
    function activate(uint256 seriesId) external;
    function mintPositions(uint256 seriesId, Side side, address account)
        external
        returns (uint256 minted, uint256 refunded);
    function net(uint256 seriesId, uint256 units) external returns (uint256 released);
    function settle(uint256 seriesId) external returns (State);
    function redeem(uint256 seriesId, Side side, uint256 units, address to) external returns (uint256 amount);

    function getSeries(uint256 seriesId) external view returns (Series memory);
    function subscribedUnits(uint256 seriesId, Side side, address account) external view returns (uint256);
    function collateralHeld(uint256 seriesId) external view returns (uint256);
    function tokenId(uint256 seriesId, Side side) external pure returns (uint256);
    function collateralPerUnit(uint256 seriesId, Side side) external view returns (uint256);
    function payoutPerUnit(uint256 seriesId, Side side) external view returns (uint256);
}
