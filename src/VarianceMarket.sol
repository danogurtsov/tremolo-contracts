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
/// @dev One contract holds every series. That is deliberate, and follows the same reasoning as
///      Morpho Blue and Uniswap V4: a singleton means one address to audit, one place where
///      collateral lives, cheap series creation, and positions that are natively fungible per
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
///      Payouts sum to deposits by construction. There is nothing to liquidate, no margin to
///      monitor, and no requirement that the price source be fast — only that it be readable
///      once, at settlement. Capital efficiency is traded away on purpose; it returns in v1
///      as partial margin, with liquidation and all the machinery that implies.
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

    /// @dev Guard rails on series parameters. Wide enough not to constrain honest use, narrow
    ///      enough that a mistyped series cannot be created — the cheapest possible answer to
    ///      "the parameters are immutable, so a broken series lives forever".
    uint64 internal constant MIN_CAP_MULTIPLE = 1.05e18;
    uint64 internal constant MAX_CAP_MULTIPLE = 10e18;
    uint32 internal constant MIN_GRID_STEP = 60;
    uint32 internal constant MIN_WINDOW = 1 hours;
    uint32 internal constant MAX_WINDOW = 365 days;
    uint256 internal constant MAX_STRIKE = 100e18; // sigma = 1000% annualised
    uint16 internal constant MIN_SAMPLES = 2;

    /// @dev Positions are denominated in WAD, so a "unit" is 1e18. Fractional units are not a
    ///      convenience: pro-rata matching cannot be exact over indivisible units, and the gap
    ///      lands on solvency rather than on rounding. See the note on `mintPositions`.
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
    ///      supply times payout — without a supply figure that property cannot be checked at
    ///      all, only asserted.
    mapping(uint256 id => uint256) internal _totalSupply;

    uint256 public seriesCount;

    /// @notice May pause creation of NEW series. Cannot touch existing ones.
    /// @dev The boundary is the point. Anyone already holding a position must be able to reach
    ///      settlement without depending on anyone's continued goodwill, so `settle`, `redeem`
    ///      and `net` are unpausable by construction — there is simply no code path.
    address public guardian;
    bool public creationPaused;

    constructor(address guardian_) {
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

        // Before a number exists, the only honest answer is the deposit itself.
        if (s.state != State.SETTLED) return collateralPerUnit(seriesId, side);

        uint256 long = VarianceMath.longPayout(s.realizedVariance, s.strike, s.capMultiple, s.notionalPerUnit);
        if (side == Side.LONG) return long;
        return totalCollateralPerUnit(seriesId) - long;
    }

    // =====================================================================
    // Creation
    // =====================================================================

    /// @inheritdoc IVarianceMarket
    function createSeries(SeriesParams calldata p) external returns (uint256 seriesId) {
        if (creationPaused) revert CreationPaused();
        if (p.observer == address(0) || p.source == address(0) || p.collateral == address(0)) {
            revert ZeroAddress();
        }
        if (p.startTime <= block.timestamp) revert StartInPast();
        if (p.expiry <= p.startTime) revert ExpiryBeforeStart();

        uint32 window = uint32(p.expiry - p.startTime);
        if (window < MIN_WINDOW || window > MAX_WINDOW) revert InvalidWindow(window);
        if (p.samples < MIN_SAMPLES) revert InvalidSamples(p.samples);
        if (window / p.samples < MIN_GRID_STEP) revert GridStepTooSmall(window / p.samples);

        if (Variance.unwrap(p.strike) == 0 || Variance.unwrap(p.strike) > MAX_STRIKE) {
            revert InvalidStrike(Variance.unwrap(p.strike));
        }
        if (p.capMultiple < MIN_CAP_MULTIPLE || p.capMultiple > MAX_CAP_MULTIPLE) {
            revert InvalidCap(p.capMultiple);
        }
        if (p.notionalPerUnit == 0) revert ZeroNotional();
        if (p.minCompletenessBps > BPS) revert InvalidCompleteness(p.minCompletenessBps);

        // Both legs must be economically meaningful. With a tiny notional and a cap close to
        // one, integer rounding can drive a deposit to zero, which would let a side hold
        // exposure it never paid for.
        uint256 longDeposit = VarianceMath.longCollateral(p.strike, p.notionalPerUnit);
        uint256 shortDeposit = VarianceMath.shortCollateral(p.strike, p.capMultiple, p.notionalPerUnit);
        if (longDeposit == 0 || shortDeposit == 0) revert DegenerateCollateral();

        // The source must be able to answer for this window, checked before anyone commits
        // money rather than discovered at settlement.
        IPriceObserver(p.observer).validateSource(p.source, window, p.samples);

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
        _collateralHeld[seriesId] += amount;

        s.collateral.safeTransferFrom(msg.sender, address(this), amount);
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
    ///      the same ratio. A queue would need iteration over subscribers, and iteration over
    ///      user-supplied lists is how protocols end up ungovernable at scale.
    function activate(uint256 seriesId) external {
        Series storage s = _series[seriesId];
        if (s.state != State.SUBSCRIBING) revert WrongState(s.state);
        if (block.timestamp < s.startTime) revert TooEarly();

        uint256 long = s.subscribedLong;
        uint256 short = s.subscribedShort;
        uint256 matched = long < short ? long : short;

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
    ///      Minting rounds down. The dust that leaves is collateral that stays in the series
    ///      backing nothing — it can only ever make the pool safer, never short.
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
        // pre-activation figure forever — a number that is no longer true of anything. After
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
    ///      VOIDED is not a failure mode bolted on afterwards, it is the honest answer to a
    ///      broken measurement. Paying out on a series reconstructed from a pool that stopped
    ///      trading would mean settling on an artefact of linear interpolation. Returning
    ///      deposits is the only outcome that cannot be gamed by killing a source.
    function settle(uint256 seriesId) external returns (State) {
        Series storage s = _series[seriesId];
        if (s.state != State.ACTIVE) revert WrongState(s.state);
        if (block.timestamp < s.expiry) revert TooEarly();

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

        try IPriceObserver(s.observer).sampleTicks(s.source, uint32(s.expiry), window, s.samples) returns (
            int256[] memory ticks
        ) {
            s.realizedVariance = VarianceMath.fromTicks(ticks, window);
            s.state = State.SETTLED;
            emit SeriesSettled(seriesId, s.realizedVariance, msg.sender);
            return State.SETTLED;
        } catch {
            return _void(seriesId, s, VoidReason.SOURCE_REVERTED);
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
    ///      exists. There is no claim deadline: unclaimed collateral stays the holder's
    ///      forever rather than becoming the protocol's after some interval.
    function redeem(uint256 seriesId, Side side, uint256 units, address to)
        external
        nonReentrant
        returns (uint256 amount)
    {
        Series storage s = _series[seriesId];
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

    function setGuardian(address newGuardian) external {
        if (msg.sender != guardian) revert NotGuardian();
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
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
