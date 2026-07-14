# Security

## Status

This code is **unaudited** and deployed only to testnets. Do not put money at risk with it.

## Reporting a vulnerability

Email dan.ogurtsov@gmail.com. Please do not open a public issue for anything exploitable.
Expect an acknowledgement within 72 hours.

## Scope

In scope: everything under `src/`.

Out of scope: `src/mocks/` (test doubles, never deployed), `lib/` (upstream dependencies —
report those upstream).

## What the protocol assumes

Most of what could go wrong lives in these assumptions rather than in the code:

1. **The price source reports its own history correctly.** The protocol reads a Uniswap V3
   observation buffer and rebuilds a series from it. A source that can be made to report a
   different history can move settlement.
2. **A sparse window is detectable.** Completeness is measured by counting genuine recordings
   in the ring buffer. An adapter that cannot distinguish recorded values from interpolated
   ones degrades this check to a no-op.
3. **Collateral tokens behave like ERC-20** — with the deviations below handled explicitly
   rather than assumed away. Each row is backed by a test in `test/unit/HostileTokens.t.sol`.

   | Token behaviour | What happens | Test |
   |---|---|---|
   | No return value on `transfer` (USDT) | **Supported.** SafeTransferLib handles it | `test_noReturnToken_worksEndToEnd` |
   | Reverts on zero-value transfer | **Supported.** Zero payouts skip the transfer entirely | `test_revertOnZeroToken_losingSideCanStillRedeem` |
   | Fee on transfer | **Rejected at subscription.** The market credits only what arrived, and reverts if it is short | `testFuzz_feeOnTransferToken_isRejectedAtAnyFee` |
   | Callback to recipient (ERC-777) | **Contained.** Reentrancy guard holds on the way in and on the way out | `test_reentrantToken_cannotReenter*` |
   | Rebasing | **Unsupported and undetected.** A balance that changes on its own breaks the ledger silently; do not create series with one |

   Fee-on-transfer is rejected because crediting the smaller amount would leave the series
   holding less collateral than the position it just sold requires.
4. **Integer rounding always favours the pool.** Deposits round up, payouts round down. Dust
   accumulates in the series and can only make it more solvent, never less.

## What the protocol does not assume

- No liveness requirement on keepers: there are none.
- No latency requirement on the price source: it is read once, at settlement.
- No solvency monitoring: payouts sum to deposits by construction.
