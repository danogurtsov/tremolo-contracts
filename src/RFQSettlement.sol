// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "solady/utils/EIP712.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

import {IVarianceMarket} from "./interfaces/IVarianceMarket.sol";
import {Variance} from "./types/Variance.sol";

/// @title RFQSettlement
/// @notice Trades opened against a signed quote, at a strike the counterparty named.
///
/// @dev What this exists to fix. The subscription flow answers "who wants this instrument at
///      this strike"; nothing answered "what is the strike". A creator typed a number, and a
///      taker could only enter during a window somebody had opened in advance. Both halves of
///      a market were missing: no price discovery, and no way in or out on demand.
///
///      Here a maker signs the terms — source, window, strike, cap, size, expiry of the quote —
///      and anyone may take the other side while the quote is live. The trade opens immediately
///      with both legs funded in the same transaction. That makes the strike the number someone
///      was willing to stand behind, rather than a parameter.
///
///      It also unblocks the exit. `net` releases collateral to whoever holds both legs, but
///      only if someone will buy the leg being sold, and nobody quotes without a way to price
///      and hedge. A maker who can open new offsetting trades on demand can quote an exit.
///
///      Deliberately a separate contract. The market moves collateral and computes variance; it
///      should not also know about signatures, nonces or deadlines. Anyone may write a different
///      execution layer against `openImmediate` without touching the part that holds the money.
contract RFQSettlement is EIP712 {
    /// @param maker Who signed, and which side they take.
    /// @param makerIsLong True if the maker takes the long leg and the taker takes the short.
    /// @param observer Price source adapter for the series.
    /// @param source Address the adapter reads.
    /// @param collateral Token both legs post.
    /// @param windowSeconds Length of the measurement window, starting at fill time.
    /// @param samples Grid points.
    /// @param minCompletenessBps Completeness floor for settlement.
    /// @param capMultiple Payout cap as a multiple of the strike.
    /// @param strike The number being quoted.
    /// @param notionalPerUnit Collateral per 1.0 of variance, per unit.
    /// @param maxUnits Largest size the maker will fill; a taker may take less.
    /// @param deadline Quote expiry, in seconds.
    /// @param nonce Maker-scoped, single use.
    struct Quote {
        address maker;
        bool makerIsLong;
        address observer;
        address source;
        address collateral;
        uint32 windowSeconds;
        uint16 samples;
        uint16 minCompletenessBps;
        uint64 capMultiple;
        uint256 strike;
        uint256 notionalPerUnit;
        uint256 maxUnits;
        uint256 deadline;
        uint256 nonce;
    }

    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "Quote(address maker,bool makerIsLong,address observer,address source,address collateral,"
        "uint32 windowSeconds,uint16 samples,uint16 minCompletenessBps,uint64 capMultiple,"
        "uint256 strike,uint256 notionalPerUnit,uint256 maxUnits,uint256 deadline,uint256 nonce)"
    );

    IVarianceMarket public immutable market;

    /// @notice Units already filled against a quote, keyed by its hash.
    /// @dev Partial fills are the point: a maker quotes a size they are willing to take, and
    ///      takers arrive in whatever pieces they arrive in. Tracking filled units rather than a
    ///      used/unused flag is what allows that.
    mapping(bytes32 quoteHash => uint256 filled) public filledUnits;

    /// @notice Nonces the maker has cancelled.
    mapping(address maker => mapping(uint256 nonce => bool)) public cancelledNonce;

    event QuoteFilled(
        bytes32 indexed quoteHash,
        address indexed maker,
        address indexed taker,
        uint256 seriesId,
        uint256 units,
        uint256 strike
    );
    event QuoteCancelled(address indexed maker, uint256 indexed nonce);

    error QuoteExpired(uint256 deadline);
    error QuoteCancelledError();
    error BadSignature();
    error ZeroFill();
    error ExceedsRemaining(uint256 requested, uint256 remaining);

    constructor(IVarianceMarket market_) {
        market = market_;
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("TremoloRFQ", "1");
    }

    /// @notice Hash a quote for signing, or for checking how much of it is left.
    function hashQuote(Quote calldata q) public view returns (bytes32) {
        // Encoded in two halves and concatenated. Fourteen fields in one `abi.encode` puts more
        // values on the stack than the legacy pipeline can address, and the result is identical:
        // concatenation of two encodings is the encoding of the concatenation.
        bytes memory head = abi.encode(
            QUOTE_TYPEHASH, q.maker, q.makerIsLong, q.observer, q.source, q.collateral, q.windowSeconds
        );
        bytes memory tail = abi.encode(
            q.samples,
            q.minCompletenessBps,
            q.capMultiple,
            q.strike,
            q.notionalPerUnit,
            q.maxUnits,
            q.deadline,
            q.nonce
        );
        return _hashTypedData(keccak256(bytes.concat(head, tail)));
    }

    /// @notice Units of a quote still available.
    function remaining(Quote calldata q) external view returns (uint256) {
        if (cancelledNonce[q.maker][q.nonce] || block.timestamp > q.deadline) return 0;
        uint256 used = filledUnits[hashQuote(q)];
        return used >= q.maxUnits ? 0 : q.maxUnits - used;
    }

    /// @notice Take the other side of a signed quote.
    ///
    /// @dev The taker pays for their own leg; the maker's leg is pulled from the maker, who
    ///      granted the market an allowance when they decided to quote. Signature verification
    ///      goes through `SignatureCheckerLib`, so a contract maker signing per ERC-1271 works
    ///      exactly like an EOA — which matters, because market makers are contracts.
    ///
    /// @param q The quote.
    /// @param signature Maker's signature over `hashQuote(q)`.
    /// @param units Size to take, up to whatever the quote has left.
    function fill(Quote calldata q, bytes calldata signature, uint256 units)
        external
        returns (uint256 seriesId)
    {
        if (block.timestamp > q.deadline) revert QuoteExpired(q.deadline);
        if (cancelledNonce[q.maker][q.nonce]) revert QuoteCancelledError();
        if (units == 0) revert ZeroFill();

        bytes32 digest = hashQuote(q);
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(q.maker, digest, signature)) {
            revert BadSignature();
        }

        uint256 used = filledUnits[digest];
        uint256 left = used >= q.maxUnits ? 0 : q.maxUnits - used;
        if (units > left) revert ExceedsRemaining(units, left);

        // Written before the external call, so a maker whose token calls back cannot fill the
        // same quote twice.
        filledUnits[digest] = used + units;

        seriesId = market.openImmediate(
            IVarianceMarket.SeriesParams({
                observer: q.observer,
                source: q.source,
                collateral: q.collateral,
                startTime: 0, // ignored; openImmediate starts now
                expiry: uint64(block.timestamp + q.windowSeconds),
                samples: q.samples,
                minCompletenessBps: q.minCompletenessBps,
                capMultiple: q.capMultiple,
                strike: Variance.wrap(q.strike),
                notionalPerUnit: q.notionalPerUnit
            }),
            q.makerIsLong ? q.maker : msg.sender,
            q.makerIsLong ? msg.sender : q.maker,
            units
        );

        emit QuoteFilled(digest, q.maker, msg.sender, seriesId, units, q.strike);
    }

    /// @notice Withdraw every quote carrying this nonce.
    /// @dev Cancellation is by nonce rather than by quote hash on purpose: a maker who wants out
    ///      of a price should not have to reconstruct the exact bytes they signed, and may not
    ///      still have them.
    function cancel(uint256 nonce) external {
        cancelledNonce[msg.sender][nonce] = true;
        emit QuoteCancelled(msg.sender, nonce);
    }
}
