// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC6909} from "solady/tokens/ERC6909.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IPriceObserver} from "./interfaces/IPriceObserver.sol";
import {IVarianceMarket} from "./interfaces/IVarianceMarket.sol";
import {VarianceMath} from "./libraries/VarianceMath.sol";
import {Variance} from "./types/Variance.sol";

/// @title VarianceMarket
/// @notice Fully collateralised variance swaps settling on realized variance computed on chain.
///
/// @dev One contract holds every series, following Morpho Blue and Uniswap V4: a singleton means one address
/// to audit, one place where collateral lives, cheap series creation, and positions that are natively
/// fungible per
///      series through ERC-6909 rather than a token contract per instrument.
///
///      The central design property, from which almost everything else follows:
///
///          long  deposits  notional * K                  (its maximum loss, at RV = 0)
///          short deposits  notional * (cap - 1) * K      (its maximum loss, at RV >= cap*K)
///          ----------------------------------------------------------------------------
///          pool          = notional * cap * K
///
///          long  receives notional * min(RV, cap*K)
///          short receives pool - long payout
///
///      Payouts sum to deposits by construction: nothing to liquidate, no margin to monitor,
///      and no requirement that the price source be fast, only readable once at settlement.
///      Capital efficiency is the cost; partial margin is v1.
///
///      Lifecycle:
///
///          SUBSCRIBING --activate()--> ACTIVE --settle()--> SETTLED
///                |                        |                    |
///                |                        +-- source failed -> VOIDED
///                +-- one side empty ----------------------> CANCELLED
///
///      SETTLED pays the formula. VOIDED and CANCELLED return deposits untouched. A series can
///      never pay out more than was put in, in any state.
contract VarianceMarket is IVarianceMarket, ERC6909, ReentrancyGuard {
    using SafeTransferLib for address;
    using VarianceMath for Variance;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @dev Guard rails on series parameters. Wide enough not to constrain normal use, narrow
    ///      enough that a mistyped series cannot be created; parameters are immutable, so a
    ///      broken series would live forever.
    uint64 internal constant MIN_CAP_MULTIPLE = 1.05e18;
    uint64 internal constant MAX_CAP_MULTIPLE = 10e18;
    uint32 internal constant MIN_GRID_STEP = 60;
    uint32 internal constant MIN_WINDOW = 1 hours;
    uint32 internal constant MAX_WINDOW = 365 days;
    uint256 internal constant MAX_STRIKE = 100e18; // sigma = 1000% annualised
    uint16 internal constant MIN_SAMPLES = 2;

    /// @dev The core keeps its own ceiling rather than trusting the adapter's. A third-party
    ///      observer with a laxer limit would otherwise turn settlement into a gas bomb that
    ///      nobody can afford to trigger — leaving a series permanently unsettleable.
    uint16 internal constant MAX_SAMPLES = 256;

    /// @dev Lower bound on a series' completeness floor. Below this the sparseness guard at
    ///      settlement effectively stops protecting anything; at zero it is disabled outright.
    ///      50% is conservative: a window that is more than half interpolated does not describe
    ///      a market. The default (one genuine recording per grid point = BPS) sits well above.
    uint16 internal constant MIN_COMPLETENESS_BPS = 5000;

    /// @dev How long after `startTime` a series may still be activated.
    ///
    ///      Without a deadline, a series nobody activated for a week would enter ACTIVE against
    ///      a buffer that had long since been overwritten, and go straight to VOIDED. Deposits
    ///      would come back either way, so nothing is lost — but the series would have spent
    ///      that week claiming to be a live instrument, and an indexer would have believed it.
    ///      Cancelling avoids that.
    uint32 internal constant ACTIVATION_GRACE = 1 hours;

    /// @dev Ceiling on a series' total variance notional, as a fraction of what it costs to move
    ///      its source's price by one percent.
    ///
    ///      This exists because a large enough series makes manipulating its source pay.
    ///      Measured on the live
    ///      WETH/USDC pool: holding the price 6% away for a third of one grid step multiplies
    ///      settled variance by 15.7x, and pays for itself against any long position above
    ///      roughly $1.5M — against a source where a 1% move costs about $161k. The break-even is
    ///      a *ratio* between notional and depth, so the defence has to be one too.
    ///
    ///      Set at 1x: a series may write notional up to the cost of a 1% move in its source.
    ///      With the measured figures that leaves the cheapest profitable attack roughly an order
    ///      of magnitude out of the money, before counting arbitrage, which the measurement
    ///      excluded and which dominates the real cost.
    ///
    ///      It is a constant rather than a parameter on purpose. A per-series limit would be set
    ///      by whoever creates the series, which is whoever would benefit from setting it wrong.
    uint256 internal constant MAX_NOTIONAL_TO_DEPTH_BPS = 10_000;

    /// @dev Gas that reading the source must be given, per grid point and fixed.
    ///
    ///      These exist because of how `eth_estimateGas` interacts with `try/catch`. The
    ///      estimator searches for the cheapest gas at which the
    ///      transaction *succeeds* — and falling into the catch and voiding the series is a
    ///      success by that definition, while costing roughly half of what reading the series
    ///      costs. Left alone, every wallet would hand `settle` exactly enough gas to guarantee
    ///      the void it was supposed to prevent, and the winning side would lose its payout to
    ///      a refund.
    ///
    ///      Found on a local fork before deployment. The Foundry fork tests never saw it: they
    ///      call `settle` with effectively unlimited gas, so the cheap path was never taken.
    ///
    ///      Checking `gasleft()` up front removes the cheap path entirely — with too little gas
    ///      the call reverts instead of voiding, so the estimator has to keep looking. The
    ///      per-read component is asked of the observer (`settleGasFloor`), since only the
    ///      adapter knows its own cost model; this market-side overhead floors it.
    uint256 internal constant GAS_SETTLE_OVERHEAD = 300_000;

    /// @dev Positions are denominated in WAD, so a "unit" is 1e18. Pro-rata matching cannot
    ///      be exact over indivisible units, and the gap comes out of solvency. See the note
    ///      on `mintPositions`.
    uint256 internal constant MIN_SUBSCRIPTION = 0.0001e18;

    /// @notice Series registry. Ids are sequential from 1; 0 is never a valid series.
    mapping(uint256 seriesId => Series) internal _series;

    /// @notice Units subscribed but not yet converted into position tokens.
    mapping(uint256 seriesId => mapping(uint8 side => mapping(address => uint256))) internal _subscribed;

    /// @notice Collateral currently held for a series. Tracked explicitly so invariants can be
    ///         stated against a stored number rather than a recomputed one.
    mapping(uint256 seriesId => uint256) internal _collateralHeld;

    /// @notice Outstanding position tokens per id.
    /// @dev ERC-6909 has no supply accounting of its own. It is added here because the
    ///      solvency invariant is stated over outstanding obligations, and obligations are
    ///      supply times payout; without a supply figure that property cannot be checked.
    mapping(uint256 id => uint256) internal _totalSupply;

    uint256 public seriesCount;

    /// @notice Guardian nominated but not yet in office.
    address public pendingGuardian;

    /// @notice May pause creation of NEW series. Cannot touch existing ones.
    /// @dev Anyone already holding a position must be able to reach settlement without
    ///      depending on anyone's goodwill, so `settle`, `redeem` and `net` have no pausable
    ///      code path.
    address public guardian;
    bool public creationPaused;

    /// @notice Contracts allowed to open a series on behalf of two named funded parties.
    /// @dev `openImmediate` pulls collateral from arbitrary `longSide`/`shortSide` addresses
    ///      using only their standing ERC-20 allowance to this market. That allowance is
    ///      spending permission, not consent to a specific trade — the consent check (an
    ///      EIP-712 signature) lives in the execution layer (`RFQSettlement`). So the raw
    ///      entry point must be gated to execution layers the guardian trusts; otherwise
    ///      anyone could force any approver into an attacker-parameterised, rigged series and
    ///      drain their approved balance. Pluggability is preserved: the guardian can bless a
    ///      new execution layer without touching the contract that holds the money.
    mapping(address opener => bool authorized) public authorizedOpener;

    constructor(address guardian_) {
        // A zero guardian would make `setCreationPaused` permanently unreachable. The two-step
        // transfer protects against a mistyped handover later, but nothing protects deployment.
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
    }

    // =====================================================================
    // Views
    // =====================================================================

    /// @inheritdoc IVarianceMarket
    function getSeries(uint256 seriesId) external view returns (Series memory) {
        return _series[seriesId];
    }

    /// @inheritdoc IVarianceMarket
    function subscribedUnits(uint256 seriesId, Side side, address account) external view returns (uint256) {
        return _subscribed[seriesId][uint8(side)][account];
    }

    /// @inheritdoc IVarianceMarket
    function collateralHeld(uint256 seriesId) external view returns (uint256) {
        return _collateralHeld[seriesId];
    }

    /// @inheritdoc IVarianceMarket
    function tokenId(uint256 seriesId, Side side) public pure returns (uint256) {
        return (seriesId << 1) | uint256(uint8(side));
    }

    /// @inheritdoc IVarianceMarket
    function collateralPerUnit(uint256 seriesId, Side side) public view returns (uint256) {
        Series storage s = _series[seriesId];
        return side == Side.LONG
            ? VarianceMath.longCollateral(s.strike, s.notionalPerUnit)
            : VarianceMath.shortCollateral(s.strike, s.capMultiple, s.notionalPerUnit);
    }

    /// @notice Total collateral backing one matched unit: `notional * cap * K`.
    function totalCollateralPerUnit(uint256 seriesId) public view returns (uint256) {
        Series storage s = _series[seriesId];
        return VarianceMath.totalCollateral(s.strike, s.capMultiple, s.notionalPerUnit);
    }

    /// @inheritdoc IVarianceMarket
    function payoutPerUnit(uint256 seriesId, Side side) public view returns (uint256) {
        Series storage s = _series[seriesId];

        // Before settlement the deposit is the only number available.
        if (s.state != State.SETTLED) return collateralPerUnit(seriesId, side);

        uint256 long = VarianceMath.longPayout(s.realizedVariance, s.strike, s.capMultiple, s.notionalPerUnit);
        if (side == Side.LONG) return long;
        return totalCollateralPerUnit(seriesId) - long;
    }

    /// @notice Variance realized so far, part-way through a live series.
    ///
    /// @dev Without this, a holder could not tell whether they were winning until the series
    ///      expired, which makes a portfolio view impossible and a margin module unbuildable.
    ///
    ///      It works because **variance is additive**: the sum of squared log returns over
    ///      [start, now] plus the sum over [now, expiry] is the sum over the whole window, with
    ///      no cross term. So the accrued part is simply the same calculation over a shorter
    ///      window, on the same grid — no state, no accumulator, no keeper.
    ///
    ///      Sampled on complete grid steps only. A partial step would annualise a fraction of
    ///      an interval and produce a number that jumps around as the step fills in.
    ///
    /// @return accrued Annualised variance over the elapsed part of the window.
    /// @return elapsedSeconds Seconds covered by that figure.
    /// @return stepsComplete Grid steps included.
    function accruedVariance(uint256 seriesId)
        public
        view
        returns (Variance accrued, uint32 elapsedSeconds, uint16 stepsComplete)
    {
        Series storage s = _series[seriesId];

        // Once settled, return the stored number: recomputing could disagree with what was
        // actually paid out.
        if (s.state == State.SETTLED) {
            return (s.realizedVariance, uint32(s.expiry - s.startTime), s.samples);
        }
        if (s.state == State.NONE || block.timestamp <= s.startTime) {
            return (Variance.wrap(0), 0, 0);
        }

        uint32 window = uint32(s.expiry - s.startTime);
        uint32 step = window / s.samples;
        uint32 endTime = block.timestamp < s.expiry ? uint32(block.timestamp) : uint32(s.expiry);

        stepsComplete = uint16((endTime - s.startTime) / step);
        if (stepsComplete < 2) return (Variance.wrap(0), endTime - uint32(s.startTime), stepsComplete);

        elapsedSeconds = uint32(stepsComplete) * step;

        try IPriceObserver(s.observer)
            .sampleSeries(
                s.source, uint32(s.startTime) + elapsedSeconds, elapsedSeconds, stepsComplete
            ) returns (
            int256[] memory series
        ) {
            accrued = IPriceObserver(s.observer).seriesKind() == IPriceObserver.SeriesKind.TICKS
                ? VarianceMath.fromTicks(series, elapsedSeconds)
                : VarianceMath.fromPrices(_toUnsigned(series), elapsedSeconds);
        } catch {
            // A source that cannot answer yet is not an error here — settlement decides that.
            return (Variance.wrap(0), elapsedSeconds, stepsComplete);
        }
    }

    /// @notice What one unit of a position is worth right now, given a view on the rest.
    ///
    /// @dev The other half of additivity. Expected variance at expiry is the time-weighted sum
    ///      of what has been realized and what is expected over the remainder:
    ///
    ///          E[RV] = (elapsed * accrued + remaining * implied) / window
    ///
    ///      and the position is worth what it would pay at that number.
    ///
    ///      `impliedRemaining` is supplied by the caller. The protocol has no view on future
    ///      volatility: pulling an implied-vol feed into the core would drag oracle risk into
    ///      a contract that currently has none. Two parties can mark the same position
    ///      differently.
    ///
    ///      Note the units trap this walks into: an implied volatility taken from an off-chain
    ///      venue is spot-based, while this instrument settles on a TWAP series that runs about
    ///      a third lower (docs/measurements/variance_bias.md). Feeding one in unadjusted
    ///      overvalues the long side.
    function markToMarket(uint256 seriesId, Variance impliedRemaining, Side side)
        external
        view
        returns (uint256 valuePerUnit)
    {
        Series storage s = _series[seriesId];
        if (s.state == State.SETTLED || s.state == State.VOIDED) {
            return payoutPerUnit(seriesId, side);
        }

        uint32 window = uint32(s.expiry - s.startTime);
        (Variance accrued, uint32 elapsed,) = accruedVariance(seriesId);

        uint256 expected =
            (Variance.unwrap(accrued) * elapsed + Variance.unwrap(impliedRemaining) * (window - elapsed))
                / window;

        uint256 long =
            VarianceMath.longPayout(Variance.wrap(expected), s.strike, s.capMultiple, s.notionalPerUnit);
        return side == Side.LONG ? long : totalCollateralPerUnit(seriesId) - long;
    }

    // =====================================================================
    // Creation
    // =====================================================================

    /// @inheritdoc IVarianceMarket
    function createSeries(SeriesParams calldata p) external returns (uint256 seriesId) {
        if (creationPaused) revert CreationPaused();
        if (p.startTime <= block.timestamp) revert StartInPast();
        _validateParams(p);

        seriesId = ++seriesCount;
        _series[seriesId] = Series({
            observer: p.observer,
            source: p.source,
            collateral: p.collateral,
            startTime: p.startTime,
            expiry: p.expiry,
            samples: p.samples,
            minCompletenessBps: p.minCompletenessBps,
            capMultiple: p.capMultiple,
            state: State.SUBSCRIBING,
            strike: p.strike,
            notionalPerUnit: p.notionalPerUnit,
            subscribedLong: 0,
            subscribedShort: 0,
            matchedUnits: 0,
            matchedAtActivation: 0,
            longAtActivation: 0,
            shortAtActivation: 0,
            realizedVariance: Variance.wrap(0)
        });

        emit SeriesCreated(seriesId, p.observer, p.source, p.collateral, p.strike, p.startTime, p.expiry);
    }

    /// @dev Split out of `createSeries` so that neither half is hard to read. Everything here
    ///      is a guard against a series that would be wrong forever: parameters are immutable
    ///      once written, so validation at creation is the only defence there is.
    function _validateParams(SeriesParams memory p) internal view {
        if (p.observer == address(0) || p.source == address(0) || p.collateral == address(0)) {
            revert ZeroAddress();
        }
        if (p.expiry <= p.startTime) revert ExpiryBeforeStart();

        // Bound the duration on the full uint64 subtraction, BEFORE narrowing to uint32.
        // Checking the truncated value would enforce the window bound on
        // `(expiry - startTime) mod 2^32`, letting an expiry ~2^32 seconds out pass as a
        // short window and lock collateral until a real expiry ~136 years away.
        uint256 fullWindow = uint256(p.expiry) - p.startTime;
        if (fullWindow < MIN_WINDOW || fullWindow > MAX_WINDOW) revert InvalidWindow(uint32(fullWindow));
        uint32 window = uint32(fullWindow); // provably lossless: fullWindow <= MAX_WINDOW < 2^32
        if (p.samples < MIN_SAMPLES || p.samples > MAX_SAMPLES) revert InvalidSamples(p.samples);
        if (window / p.samples < MIN_GRID_STEP) revert GridStepTooSmall(window / p.samples);

        if (Variance.unwrap(p.strike) == 0 || Variance.unwrap(p.strike) > MAX_STRIKE) {
            revert InvalidStrike(Variance.unwrap(p.strike));
        }
        if (p.capMultiple < MIN_CAP_MULTIPLE || p.capMultiple > MAX_CAP_MULTIPLE) {
            revert InvalidCap(p.capMultiple);
        }
        if (p.notionalPerUnit == 0) revert ZeroNotional();
        // A floor as well as a ceiling. Zero would make the settlement sparseness test
        // `real * BPS < samples * minCompletenessBps` unreachable, silently disabling the
        // guard that refuses to settle a mostly-interpolated window — a value the creator
        // (or an RFQ maker signing the quote) benefits from setting wrong.
        if (p.minCompletenessBps < MIN_COMPLETENESS_BPS || p.minCompletenessBps > BPS) {
            revert InvalidCompleteness(p.minCompletenessBps);
        }

        // Both legs must be economically meaningful. With a tiny notional and a cap close to
        // one, integer rounding can drive a deposit to zero, which would let a side hold
        // exposure it never paid for.
        uint256 longDeposit = VarianceMath.longCollateral(p.strike, p.notionalPerUnit);
        uint256 shortDeposit = VarianceMath.shortCollateral(p.strike, p.capMultiple, p.notionalPerUnit);
        if (longDeposit == 0 || shortDeposit == 0) revert DegenerateCollateral();

        // An address with no code answers every staticcall with empty returndata, which decodes
        // as zero and would sail through validation. The series would then be created, funded,
        // and only fail at settlement — where it voids and refunds, having wasted everyone's
        // time and capital for the length of the window.
        if (p.observer.code.length == 0) revert ObserverHasNoCode(p.observer);

        // Collateral must be the token the source quotes in, so that the notional cap compares
        // like with like. Without this, a series could dodge the cap entirely by denominating
        // itself in an unrelated token whose units happen to look small next to pool depth.
        address quote = IPriceObserver(p.observer).quoteToken(p.source);
        if (quote != address(0) && quote != p.collateral) {
            revert CollateralNotQuoteToken(p.collateral, quote);
        }

        // The source must be able to answer for this window, checked before anyone commits
        // money rather than discovered at settlement.
        IPriceObserver(p.observer).validateSource(p.source, window, p.samples);
    }

    /// @notice Creates a series that starts immediately, with both legs already filled.
    ///
    /// @dev The subscription flow answers "who wants this instrument at this strike"; it does
    ///      not answer "what is the strike". Nothing in v0 did. A strike was whatever the
    ///      creator typed, and a taker could only enter during a subscription window that had
    ///      to be opened in advance.
    ///
    ///      Here instead a counterparty who is willing to take a side names the strike, and
    ///      the trade opens against it on the spot. Both legs are funded in the same
    ///      transaction, so the series is fully collateralised from its first block and there is
    ///      no window in which one side is committed and the other is not.
    ///
    ///      It checks parameters and moves collateral, nothing else. Who agreed to what, and
    ///      on what terms, is settled one layer up in `RFQSettlement`, which is where
    ///      signatures, deadlines and replay protection belong.
    ///
    /// @param p Series parameters. `startTime` is ignored and set to now.
    /// @param longSide Account taking the long leg; must have approved this contract.
    /// @param shortSide Account taking the short leg; must have approved this contract.
    /// @param units Size of both legs, WAD-denominated.
    function openImmediate(SeriesParams calldata p, address longSide, address shortSide, uint256 units)
        external
        nonReentrant
        returns (uint256 seriesId)
    {
        // Only a blessed execution layer may pull a third party's approved collateral. The
        // sole exception is a caller opening entirely against itself (both legs its own funds),
        // which is market-neutral and spends nobody else's allowance.
        if (!authorizedOpener[msg.sender] && (longSide != msg.sender || shortSide != msg.sender)) {
            revert NotAuthorizedOpener(msg.sender);
        }
        if (creationPaused) revert CreationPaused();
        if (units < MIN_SUBSCRIPTION) revert ZeroUnits();
        if (longSide == address(0) || shortSide == address(0)) revert ZeroAddress();

        SeriesParams memory q = p;
        q.startTime = uint64(block.timestamp);
        if (q.expiry <= q.startTime) revert ExpiryBeforeStart();
        _validateParams(q);

        seriesId = ++seriesCount;
        _series[seriesId] = Series({
            observer: q.observer,
            source: q.source,
            collateral: q.collateral,
            startTime: q.startTime,
            expiry: q.expiry,
            samples: q.samples,
            minCompletenessBps: q.minCompletenessBps,
            capMultiple: q.capMultiple,
            state: State.ACTIVE,
            strike: q.strike,
            notionalPerUnit: q.notionalPerUnit,
            subscribedLong: 0,
            subscribedShort: 0,
            matchedUnits: units,
            matchedAtActivation: units,
            longAtActivation: units,
            shortAtActivation: units,
            realizedVariance: Variance.wrap(0)
        });

        emit SeriesCreated(seriesId, q.observer, q.source, q.collateral, q.strike, q.startTime, q.expiry);

        _checkDepthLimit(seriesId, units);

        _pullCollateral(seriesId, Side.LONG, longSide, units);
        _pullCollateral(seriesId, Side.SHORT, shortSide, units);

        _mint(longSide, tokenId(seriesId, Side.LONG), units);
        _mint(shortSide, tokenId(seriesId, Side.SHORT), units);

        emit SeriesActivated(seriesId, units, units, units);
        emit PositionsMinted(seriesId, Side.LONG, longSide, units, 0);
        emit PositionsMinted(seriesId, Side.SHORT, shortSide, units, 0);
    }

    /// @dev Rejects a series that has grown large enough for manipulating its source to pay.
    ///
    ///      An observer with no on-chain depth returns `type(uint256).max` and the check passes:
    ///      a push feed cannot be moved by trading against it, so sizing is not the defence
    ///      there. A source reporting zero depth is rejected outright — a pool with no liquidity
    ///      in range prices nothing.
    function _checkDepthLimit(uint256 seriesId, uint256 units) internal view {
        Series storage s = _series[seriesId];

        // Only comparable when depth and notional are the same asset; `createSeries` enforces
        // that, so reaching here with a mismatch is impossible.
        if (IPriceObserver(s.observer).quoteToken(s.source) != s.collateral) return;

        uint256 depth = IPriceObserver(s.observer).depthQuote(s.source);
        if (depth == type(uint256).max) return;

        uint256 limit = depth * MAX_NOTIONAL_TO_DEPTH_BPS / BPS;
        uint256 notional = FixedPointMathLib.fullMulDiv(units, s.notionalPerUnit, WAD);
        if (notional > limit) revert ExceedsDepthLimit(notional, limit);
    }

    /// @dev Shared with `subscribe`: takes collateral and refuses anything that arrives short.
    function _pullCollateral(uint256 seriesId, Side side, address from, uint256 units) internal {
        Series storage s = _series[seriesId];
        uint256 amount = _depositFor(units, collateralPerUnit(seriesId, side));

        uint256 balanceBefore = s.collateral.balanceOf(address(this));
        s.collateral.safeTransferFrom(from, address(this), amount);
        uint256 received = s.collateral.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert CollateralShortfall(amount, received);

        _collateralHeld[seriesId] += amount;
    }

    // =====================================================================
    // Subscription
    // =====================================================================

    /// @inheritdoc IVarianceMarket
    function subscribe(uint256 seriesId, Side side, uint256 units) external nonReentrant {
        Series storage s = _series[seriesId];
        if (s.state != State.SUBSCRIBING) revert WrongState(s.state);
        if (block.timestamp >= s.startTime) revert SubscriptionClosed();
        if (units < MIN_SUBSCRIPTION) revert ZeroUnits();

        uint256 amount = _depositFor(units, collateralPerUnit(seriesId, side));

        _subscribed[seriesId][uint8(side)][msg.sender] += units;
        if (side == Side.LONG) s.subscribedLong += units;
        else s.subscribedShort += units;

        // Checked against the side being added, so the cap binds on whichever side grows past
        // it. Matching takes the minimum of the two, so bounding each bounds the matched size.
        _checkDepthLimit(seriesId, side == Side.LONG ? s.subscribedLong : s.subscribedShort);
        _collateralHeld[seriesId] += amount;

        // Credit only what actually arrived. A fee-on-transfer token would otherwise let a
        // subscription be recorded in full while the market holds less collateral than the
        // position it just sold requires — an under-collateralised series. Rejecting rather
        // than crediting the smaller amount: the deposit is derived from `units`, so a
        // partial arrival breaks the series' arithmetic.
        uint256 balanceBefore = s.collateral.balanceOf(address(this));
        s.collateral.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = s.collateral.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert CollateralShortfall(amount, received);

        emit Subscribed(seriesId, side, msg.sender, units, amount);
    }

    /// @inheritdoc IVarianceMarket
    /// @dev Available while subscribing, and after a failed activation. Both are cases where
    ///      no exposure was ever taken on, so the refund is unconditional and complete.
    function unsubscribe(uint256 seriesId, Side side, uint256 units) external nonReentrant {
        Series storage s = _series[seriesId];
        if (s.state != State.SUBSCRIBING && s.state != State.CANCELLED) revert WrongState(s.state);
        if (s.state == State.SUBSCRIBING && block.timestamp >= s.startTime) {
            revert SubscriptionClosed();
        }
        if (units < MIN_SUBSCRIPTION) revert ZeroUnits();

        uint256 held = _subscribed[seriesId][uint8(side)][msg.sender];
        if (units > held) revert InsufficientSubscription(held, units);

        // Rounded DOWN, while `subscribe` rounds up. Symmetric rounding would let a
        // subscription be withdrawn in several parts for more than it cost: ceil(a+b) can be
        // one wei less than ceil(a) + ceil(b), and that wei comes out of somebody else's
        // collateral. A full-size round trip is still exactly neutral.
        uint256 amount = FixedPointMathLib.fullMulDiv(units, collateralPerUnit(seriesId, side), WAD);

        _subscribed[seriesId][uint8(side)][msg.sender] = held - units;
        if (side == Side.LONG) s.subscribedLong -= units;
        else s.subscribedShort -= units;
        _collateralHeld[seriesId] -= amount;

        s.collateral.safeTransfer(msg.sender, amount);
        emit Unsubscribed(seriesId, side, msg.sender, units, amount);
    }

    /// @inheritdoc IVarianceMarket
    /// @dev Permissionless. Matching is pro-rata rather than first-come: the short side
    ///      matches `min(long, short)` units in aggregate and every subscriber is filled by
    ///      the same ratio. A queue would need iteration over a user-supplied list of subscribers.
    function activate(uint256 seriesId) external {
        Series storage s = _series[seriesId];
        if (s.state != State.SUBSCRIBING) revert WrongState(s.state);
        if (block.timestamp < s.startTime) revert TooEarly();

        uint256 long = s.subscribedLong;
        uint256 short = s.subscribedShort;
        uint256 matched = long < short ? long : short;

        // Too late to start measuring: the window has already been running without anyone
        // committing to it, and the source's memory of the early part may be gone.
        if (block.timestamp > s.startTime + ACTIVATION_GRACE) {
            s.state = State.CANCELLED;
            emit SeriesCancelled(seriesId);
            return;
        }

        if (matched == 0) {
            // Nobody took the other side. Everything is refundable via `unsubscribe`.
            s.state = State.CANCELLED;
            emit SeriesCancelled(seriesId);
            return;
        }

        s.matchedUnits = matched;
        s.matchedAtActivation = matched;
        // Snapshots, not a pre-divided fill factor. A factor floored to WAD loses a whole
        // unit's worth of matching when it is applied to a large subscription, and the loss
        // shows up as a side that keeps its position while its counterparty is refunded in
        // full. Keeping numerator and denominator makes the split exact.
        s.longAtActivation = long;
        s.shortAtActivation = short;
        s.state = State.ACTIVE;

        emit SeriesActivated(seriesId, matched, long, short);
    }

    /// @inheritdoc IVarianceMarket
    /// @dev Converts a subscription into transferable position tokens and refunds whatever the
    ///      pro-rata fill left unmatched. Anyone may call it for anyone: it moves no value to
    ///      the caller, and letting third parties settle bookkeeping keeps positions from
    ///      being stranded by an inattentive owner.
    ///
    ///      Minting rounds down; the dust stays in the series backing nothing, which can only
    ///      make the pool safer.
    function mintPositions(uint256 seriesId, Side side, address account)
        external
        nonReentrant
        returns (uint256 minted, uint256 refunded)
    {
        Series storage s = _series[seriesId];
        if (s.state == State.SUBSCRIBING || s.state == State.NONE) revert WrongState(s.state);
        if (s.state == State.CANCELLED) revert WrongState(s.state); // refunds go through unsubscribe

        uint256 units = _subscribed[seriesId][uint8(side)][account];
        if (units == 0) revert NothingToMint();

        uint256 total = side == Side.LONG ? s.longAtActivation : s.shortAtActivation;

        // Minted rounds down; the refund is taken as a share of the DEPOSIT rather than
        // computed from the minted amount. That ordering matters: it keeps the matched share
        // of every deposit inside the pool even when the position it backs rounds down, so
        // the collateral behind matched units can never be refunded away.
        // Against the ACTIVATION snapshot, not the live counter. `matchedUnits` falls as
        // positions are netted, and reading it here would hand a later subscriber a larger
        // refund than their fill entitles them to — collateral that is still backing someone
        // else's position. Caught by invariant_collateralCoversClaims at 512 runs, depth 128,
        // in a sequence where a netting happened between two mints.
        uint256 matched = s.matchedAtActivation;
        minted = FixedPointMathLib.fullMulDiv(units, matched, total);

        uint256 paid = _depositFor(units, collateralPerUnit(seriesId, side));
        refunded = FixedPointMathLib.fullMulDiv(paid, total - matched, total);

        _subscribed[seriesId][uint8(side)][account] = 0;

        // The aggregate must fall too, otherwise `subscribedLong/Short` keep reporting the
        // pre-activation figure forever. After
        // activation these fields mean "subscriptions not yet converted", and an indexer
        // reading them gets an answer that matches the collateral actually still owed.
        // Caught by invariant_collateralCoversClaims, not by any unit test.
        if (side == Side.LONG) s.subscribedLong -= units;
        else s.subscribedShort -= units;

        if (minted != 0) _mint(account, tokenId(seriesId, side), minted);
        if (refunded != 0) {
            _collateralHeld[seriesId] -= refunded;
            s.collateral.safeTransfer(account, refunded);
        }

        emit PositionsMinted(seriesId, side, account, minted, refunded);
    }

    // =====================================================================
    // Netting — the exit
    // =====================================================================

    /// @inheritdoc IVarianceMarket
    /// @dev Holding both legs of the same series is holding nothing: the payouts sum to the
    ///      deposits regardless of what variance does. So both legs can be burned and the full
    ///      collateral released, at any point before settlement, with no price and no oracle.
    ///
    ///      This is what replaces a secondary market. Exiting a long means selling the long
    ///      token to someone who is short the same series; that buyer nets and frees capital
    ///      immediately, so they can quote a price to the seller. Liquidity concentrates in
    ///      the series instead of splitting across a primary and a secondary venue.
    function net(uint256 seriesId, uint256 units) external nonReentrant returns (uint256 released) {
        Series storage s = _series[seriesId];
        if (s.state != State.ACTIVE) revert WrongState(s.state);
        if (units == 0) revert ZeroUnits();

        uint256 longId = tokenId(seriesId, Side.LONG);
        uint256 shortId = tokenId(seriesId, Side.SHORT);
        if (balanceOf(msg.sender, longId) < units || balanceOf(msg.sender, shortId) < units) {
            revert InsufficientPosition();
        }

        released = FixedPointMathLib.fullMulDiv(units, totalCollateralPerUnit(seriesId), WAD);

        _burn(msg.sender, longId, units);
        _burn(msg.sender, shortId, units);
        s.matchedUnits -= units;
        _collateralHeld[seriesId] -= released;

        s.collateral.safeTransfer(msg.sender, released);
        emit Netted(seriesId, msg.sender, units, released);
    }

    // =====================================================================
    // Settlement
    // =====================================================================

    /// @inheritdoc IVarianceMarket
    /// @dev Permissionless and unpausable. Two things can happen:
    ///
    ///        - the source answers and the window is dense enough -> SETTLED with a number;
    ///        - the source reverts, or the window is too sparse   -> VOIDED, deposits returned.
    ///
    ///      Paying out on a series reconstructed from a pool that stopped
    ///      trading would mean settling on an artefact of linear interpolation. Returning
    ///      deposits is the only outcome that cannot be gamed by killing a source.
    function settle(uint256 seriesId) external nonReentrant returns (State) {
        Series storage s = _series[seriesId];
        if (s.state != State.ACTIVE) revert WrongState(s.state);
        if (block.timestamp < s.expiry) revert TooEarly();
        _requireGasToSettle(s);
        return _settle(seriesId, s);
    }

    /// @dev Refuses to start rather than void for lack of gas. The 64/63 factor is EIP-150: a
    ///      call receives 63/64 of what is available, so the caller needs proportionally more
    ///      than the callee will use.
    ///
    ///      The floor is asked of the observer, not assumed from one constant. A tick pool
    ///      answers a whole grid in a single `observe()`, while a round-indexed feed searches
    ///      per grid point — a UniV3-measured `GAS_PER_SAMPLE` would leave a Chainlink series
    ///      settling on the cheap void-through-catch path. `GAS_SETTLE_OVERHEAD * 64/63` is kept
    ///      as a market-side floor beneath any adapter estimate.
    function _requireGasToSettle(Series storage s) internal view {
        uint32 window = uint32(s.expiry - s.startTime);
        uint256 readCost = IPriceObserver(s.observer).settleGasFloor(s.source, s.samples, window);
        uint256 needed = (readCost + GAS_SETTLE_OVERHEAD) * 64 / 63;
        if (gasleft() < needed) revert InsufficientGasToSettle(needed, gasleft());
    }

    /// @dev The body, callable from `redeem` so that nobody has to be paid to run it.
    function _settle(uint256 seriesId, Series storage s) internal returns (State) {
        uint32 window = uint32(s.expiry - s.startTime);

        // Completeness: how much of the window is genuine recording rather than interpolation.
        // Wrapped in try/catch because a source that reverts must void the series, not freeze it.
        try IPriceObserver(s.observer).realObservations(s.source, uint32(s.expiry), window) returns (
            uint256 real
        ) {
            if (real * BPS < uint256(s.samples) * s.minCompletenessBps) {
                return _void(seriesId, s, VoidReason.SPARSE_SERIES);
            }
        } catch {
            return _void(seriesId, s, VoidReason.SOURCE_REVERTED);
        }

        // The whole reconstruction — the source read AND the variance computation — runs behind
        // one try/catch. Moving the compute out of the catch would let an arithmetic revert
        // (an out-of-range tick, a non-positive price into lnWad) bubble up and freeze the
        // series in ACTIVE forever, which is strictly worse than the void-and-refund the design
        // promises. `reconstruct` is external+view so any revert inside it is caught here.
        try this.reconstruct(s.observer, s.source, uint32(s.expiry), window, s.samples) returns (Variance v) {
            s.realizedVariance = v;
            s.state = State.SETTLED;
            emit SeriesSettled(seriesId, v, msg.sender);
            return State.SETTLED;
        } catch {
            return _void(seriesId, s, VoidReason.SOURCE_REVERTED);
        }
    }

    /// @notice Reads the source and computes realized variance in one external call.
    /// @dev External so `_settle` can wrap the source read and the arithmetic in a single
    ///      try/catch. View: it moves no state, so wrapping it cannot introduce reentrancy.
    function reconstruct(address observer, address source, uint32 endTime, uint32 window, uint16 samples)
        external
        view
        returns (Variance)
    {
        int256[] memory series = IPriceObserver(observer).sampleSeries(source, endTime, window, samples);
        return IPriceObserver(observer).seriesKind() == IPriceObserver.SeriesKind.TICKS
            ? VarianceMath.fromTicks(series, window)
            : VarianceMath.fromPrices(_toUnsigned(series), window);
    }

    /// @dev Price series are non-negative by construction; the shared `int256[]` return type is
    ///      what lets one interface carry both scales.
    function _toUnsigned(int256[] memory a) internal pure returns (uint256[] memory out) {
        out = new uint256[](a.length);
        for (uint256 i = 0; i < a.length; ++i) {
            if (a[i] < 0) revert NegativePrice(a[i]);
            out[i] = uint256(a[i]);
        }
    }

    function _void(uint256 seriesId, Series storage s, VoidReason reason) internal returns (State) {
        s.state = State.VOIDED;
        emit SeriesVoided(seriesId, reason);
        return State.VOIDED;
    }

    /// @inheritdoc IVarianceMarket
    /// @dev In SETTLED, pays the formula. In VOIDED, returns the original deposit for that
    ///      side. Both are the same code path because both are "burn units, pay per-unit
    ///      amount" — and `payoutPerUnit` already answers with the deposit when no number
    ///      exists. There is no claim deadline: unclaimed collateral stays the holder's forever.
    function redeem(uint256 seriesId, Side side, uint256 units, address to)
        external
        nonReentrant
        returns (uint256 amount)
    {
        Series storage s = _series[seriesId];

        // Settle on the way out if nobody has yet. Nothing pays a keeper to call `settle`, and
        // adding a reward would have to come from somewhere: out of the pot, which breaks the
        // identity the whole design rests on, or out of a fund that has to be filled and
        // governed. Neither is necessary: whoever is owed money already has a reason to spend the gas,
        // and `accruedVariance` lets them see they are owed it.
        //
        // Following Squeeth, which accrues its funding on any interaction rather than on a
        // schedule. The public `settle` stays: an indexer or a losing side may still want the
        // number fixed at a particular moment.
        if (s.state == State.ACTIVE && block.timestamp >= s.expiry) {
            _requireGasToSettle(s);
            _settle(seriesId, s);
        }

        if (s.state != State.SETTLED && s.state != State.VOIDED) revert WrongState(s.state);
        if (units == 0) revert ZeroUnits();

        uint256 id = tokenId(seriesId, side);
        if (balanceOf(msg.sender, id) < units) revert InsufficientPosition();

        amount = FixedPointMathLib.fullMulDiv(units, payoutPerUnit(seriesId, side), WAD);

        _burn(msg.sender, id, units);
        _collateralHeld[seriesId] -= amount;

        if (amount != 0) s.collateral.safeTransfer(to, amount);
        emit Redeemed(seriesId, side, msg.sender, to, units, amount);
    }

    // =====================================================================
    // Guardian
    // =====================================================================

    /// @notice Pauses creation of new series. Existing series are untouched.
    function setCreationPaused(bool paused) external {
        if (msg.sender != guardian) revert NotGuardian();
        creationPaused = paused;
        emit CreationPauseSet(paused);
    }

    /// @notice Grants or revokes an execution layer's right to call `openImmediate`.
    /// @dev The trusted layer (e.g. `RFQSettlement`) verifies each party consented to the
    ///      exact terms before opening; the market cannot, so it delegates that to blessed
    ///      openers only. Revocable, so a compromised layer can be cut off without a redeploy.
    function setAuthorizedOpener(address opener, bool authorized) external {
        if (msg.sender != guardian) revert NotGuardian();
        authorizedOpener[opener] = authorized;
        emit AuthorizedOpenerSet(opener, authorized);
    }

    /// @notice Nominates a new guardian. Takes effect only once the nominee accepts.
    /// @dev Two-step because a single-step transfer hands the pause switch to whatever
    ///      address was typed, and a typo is unrecoverable; there is no second guardian to
    ///      undo it. Requiring the nominee to act proves the address is controlled by someone.
    function transferGuardian(address newGuardian) external {
        if (msg.sender != guardian) revert NotGuardian();
        pendingGuardian = newGuardian;
        emit GuardianTransferStarted(guardian, newGuardian);
    }

    /// @notice Completes a guardian transfer.
    function acceptGuardian() external {
        if (msg.sender != pendingGuardian) revert NotPendingGuardian();
        guardian = pendingGuardian;
        pendingGuardian = address(0);
        emit GuardianSet(guardian);
    }

    // =====================================================================
    // ERC6909 metadata
    // =====================================================================

    function name(uint256 id) public pure override returns (string memory) {
        return (id & 1) == 0 ? "Tremolo Variance Long" : "Tremolo Variance Short";
    }

    function symbol(uint256 id) public pure override returns (string memory) {
        return (id & 1) == 0 ? "vLONG" : "vSHORT";
    }

    function decimals(uint256) public pure override returns (uint8) {
        return 18; // positions are WAD-denominated; see MIN_SUBSCRIPTION
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    /// @dev Collateral owed for `units` at `perUnit`, rounded UP. Every rounding direction in
    ///      this contract favours the pool; deposits are where that starts.
    function _depositFor(uint256 units, uint256 perUnit) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDivUp(units, perUnit, WAD);
    }

    /// @notice Outstanding units of a position token.
    function totalSupply(uint256 id) public view returns (uint256) {
        return _totalSupply[id];
    }

    /// @dev Supply accounting hooks into mint and burn only; ordinary transfers move balances
    ///      between holders and leave supply untouched.
    function _afterTokenTransfer(address from, address to, uint256 id, uint256 amount) internal override {
        if (from == address(0)) _totalSupply[id] += amount;
        if (to == address(0)) _totalSupply[id] -= amount;
    }
}
