# ADR-0010 — via_ir for anything deployable

Date: 2026-07-28 · Status: accepted

## Context

`VarianceMarket` had grown to **20 436 bytes** against the 24 576 limit, leaving 4 140. The
protocol still needs accrued-variance reads, protocol fees, settlement checkpoints and a
settlement incentive — any two of which would not fit. The question was which structural change
to make, and it turned out the answer was to make none.

## What was tried

Measured, not assumed:

| Configuration | Size | Headroom | `settle` gas | Build |
|---|---|---|---|---|
| via_ir off, runs 10 000 *(before)* | 20 436 | 4 140 | 564 269 | 11s |
| via_ir off, runs 200 | 17 643 | 6 933 | — | 11s |
| **via_ir on, runs 10 000** | **16 608** | **7 968** | **443 536** | 58s |
| via_ir on, runs 200 | 14 410 | 10 166 | — | ~60s |

The structural options, from repositories with the same problem:

- **Uniswap V4** — `Extsload`/`Exttload` in the core returning raw storage, with `StateView`,
  `ReservesLens` and `V4Quoter` living in periphery.
- **Morpho Blue** — no view helpers in the core at all; callers read public mappings and compute
  off chain or in a library.
- **Euler EVK** — modules behind `delegatecall` dispatch, which buys unlimited room at the cost
  of an indirection on every call and a much larger trusted surface.

## Decision

**Turn on `via_ir` for every profile that produces deployable bytecode.** No architectural change.

This is unusual in that there is no trade-off on the axes that matter: the new pipeline is
**3 828 bytes smaller and 21% cheaper on `settle`**, the protocol's most expensive operation. It
optimises loops and memory better than the legacy pipeline, and this codebase is mostly loops
over arrays.

The cost is build time — 11s to 58s. That is paid only by the local edit-test loop, so:

- `default` keeps `via_ir = false` for iteration speed;
- **`pr` and `ci` turn it on**, so the bytecode that reaches main is always the bytecode that
  ships;
- `make deploy-dry` and `make build-deploy` force the `ci` profile. Before this, the deploy
  script ran under `default` and would have shipped the 20 436-byte build — the worst of both.

## Rejected, and why

**A lens contract (Uniswap's approach).** The right answer if the core were still too big after
via_ir. It is not, and splitting reads across two addresses complicates every integration for
headroom already available.

**Dropping `optimizer_runs` to 200.** Another 2 198 bytes, at the cost of runtime gas on a
contract whose functions are called constantly. Buying space with gas is the wrong direction
while space is not the binding constraint.

**Modules behind delegatecall (Euler's approach).** Unlimited room, and a far larger trusted
surface plus an indirection on every call. Warranted at Euler's scope; not at 16 KB.

## Consequences

- Headroom goes from 4 140 to **7 968 bytes**, enough for several planned additions before this
  question returns.
- The local suite runs against legacy-pipeline bytecode. Mitigated by `pr` and CI compiling the
  real thing, and it is the reason the pre-push profile exists at all.
- CI now asserts sizes explicitly. `forge build --sizes` only warns; a contract silently growing
  past the limit would otherwise surface at deployment.
- When headroom runs out again, the lens split is the next move, and this record says why it was
  not the first one.
