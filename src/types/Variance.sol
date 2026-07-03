// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Annualised variance, WAD-scaled (1e18 = 1.0 = 100% vol squared).
/// @dev A user-defined value type on purpose. Variance and volatility differ by a square,
///      and mixing them is the single most likely arithmetic mistake in this codebase.
///      The type makes the two impossible to pass interchangeably at compile time.
///
///      Reference points, so the scale is never guessed:
///        20% annual vol -> sigma^2 = 0.04     -> Variance.wrap(0.04e18)
///        80% annual vol -> sigma^2 = 0.64     -> Variance.wrap(0.64e18)
///       150% annual vol -> sigma^2 = 2.25     -> Variance.wrap(2.25e18)
type Variance is uint256;

using {add as +, sub as -, lt as <, gt as >, lte as <=, gte as >=, eq as ==, neq as !=} for Variance global;

using VarianceLib for Variance global;

function add(Variance a, Variance b) pure returns (Variance) {
    return Variance.wrap(Variance.unwrap(a) + Variance.unwrap(b));
}

function sub(Variance a, Variance b) pure returns (Variance) {
    return Variance.wrap(Variance.unwrap(a) - Variance.unwrap(b));
}

function lt(Variance a, Variance b) pure returns (bool) {
    return Variance.unwrap(a) < Variance.unwrap(b);
}

function gt(Variance a, Variance b) pure returns (bool) {
    return Variance.unwrap(a) > Variance.unwrap(b);
}

function lte(Variance a, Variance b) pure returns (bool) {
    return Variance.unwrap(a) <= Variance.unwrap(b);
}

function gte(Variance a, Variance b) pure returns (bool) {
    return Variance.unwrap(a) >= Variance.unwrap(b);
}

function eq(Variance a, Variance b) pure returns (bool) {
    return Variance.unwrap(a) == Variance.unwrap(b);
}

function neq(Variance a, Variance b) pure returns (bool) {
    return Variance.unwrap(a) != Variance.unwrap(b);
}

library VarianceLib {
    uint256 internal constant WAD = 1e18;

    function raw(Variance a) internal pure returns (uint256) {
        return Variance.unwrap(a);
    }

    function isZero(Variance a) internal pure returns (bool) {
        return Variance.unwrap(a) == 0;
    }

    function min(Variance a, Variance b) internal pure returns (Variance) {
        return Variance.unwrap(a) < Variance.unwrap(b) ? a : b;
    }

    /// @notice Scales variance by a WAD-scaled multiplier, rounding down.
    /// @dev Used for the cap: `strike.mulWad(capMultiple)`.
    function mulWad(Variance a, uint256 multiplierWad) internal pure returns (Variance) {
        return Variance.wrap(Variance.unwrap(a) * multiplierWad / WAD);
    }

    /// @notice Notional value of this much variance, in token units.
    /// @param notionalPerUnit tokens paid per 1.0 (1e18) of variance
    /// @dev Rounds down. Callers that must not under-collateralise use `notionalUp`.
    function notional(Variance a, uint256 notionalPerUnit) internal pure returns (uint256) {
        return Variance.unwrap(a) * notionalPerUnit / WAD;
    }

    /// @notice As `notional`, rounding up. Used wherever rounding must favour the protocol.
    function notionalUp(Variance a, uint256 notionalPerUnit) internal pure returns (uint256) {
        uint256 p = Variance.unwrap(a) * notionalPerUnit;
        return p == 0 ? 0 : (p - 1) / WAD + 1;
    }
}
