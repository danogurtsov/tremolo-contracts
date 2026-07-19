# Threat model

What can go wrong, what stops it, and what does not. Every claim here points at a test or a
measurement; anything unsupported is marked as such rather than argued.

---

## Assets at risk

| Asset | Where it lives | Who can move it |
|---|---|---|
| Collateral | `VarianceMarket`, per series | Only the holders of that series' positions, and only through `net`, `redeem` or `unsubscribe` |
| Position tokens | ERC-6909 balances | The holder |
| The settled number | `Series.realizedVariance`, written once | Nobody — set by `settle` from the source, never editable |

There is no admin path to collateral. The guardian can pause creation of **new** series and
nothing else; `settle`, `redeem`, `net` and `unsubscribe` have no pausable code path at all
(`test_guardian_cannotBlockSettlementOfLiveSeries`).

---

## 1. Manipulating the settled number

**The attack.** Realized variance is a sum of squared log returns, so an attacker holding a long
position profits by moving the price back and forth. Direction does not matter, which makes this
cheaper than any directional attack.

**What stops the cheap version.** The series samples a TWAP. Measured on the real pool: $1 000 000
pushed the price 620 ticks and, reversed in the same block, moved the settled variance by
**0 bps**. Two seconds of excursion inside a fifteen-minute average is nothing.

**What does not stop the expensive version.** Holding that same dislocation for five minutes —
a third of one grid step — raised settled variance **15.7x** and pays for itself against a long
position above roughly **$1.5M** of variance notional.

**And the honest caveat.** That $1.5M figure is measured on a fork, where nobody arbitrages the
price back. On a live chain, holding a 6% dislocation on the deepest ETH pool on Base for five
minutes means absorbing every arbitrage trade aimed at it. The measured number is the entry fee;
the real cost is unmeasured and much larger.

**Defence, and its limit.** Notional per series is bounded relative to source depth: a series may
not write more notional than it costs to move its source's price by one percent
(`MAX_NOTIONAL_TO_DEPTH_BPS`, enforced on both `subscribe` and `openImmediate`). On the target
pool that is roughly **$254k per series**, leaving the cheapest profitable attack about an order
of magnitude out of the money before arbitrage is counted at all.

Two things make the bound hold rather than look like it holds. It binds on **aggregate** size,
not per call, so it cannot be walked past in pieces. And collateral must be the token the source
quotes in — otherwise a series could sidestep the cap entirely by denominating itself in an
unrelated token, since comparing pool depth in USDC against units of some other asset compares
nothing (`test_createSeries_rejectsCollateralThatIsNotTheQuoteToken`).

There is still no price at which manipulation becomes impossible, only one at which it stops
being worth it. The cap sets that price.

Details: [manipulation_cost.md](docs/measurements/manipulation_cost.md)

## 2. Starving or killing the source

**The attack.** Stop trading in the pool so the series is reconstructed mostly from
interpolation, or make the source revert at settlement.

**What stops it.** Settlement counts genuine recordings and voids the series below
`minCompletenessBps`, returning deposits rather than paying out on an artefact. A reverting
source voids as well, through `try/catch` — the series can never freeze.
(`test_sparseWindow_voidsAndRefunds`, `test_revertingSource_voids`.)

**Residual.** Voiding is a refund, so an attacker who is losing can force a draw by killing the
source. On the target pool this means stopping a venue trading every 23 seconds, which costs far
more than any series it would void; on a thin pool it is cheap, which is an argument against
writing series on thin pools rather than a defence.

## 3. Draining collateral through the market

**Covered by construction.** Payouts sum to deposits identically: long receives
`notional * min(RV, cap*K)`, short receives the remainder of a pot that is exactly
`notional * cap * K`. Proven for the deposit half symbolically (`check_depositsSumToPot`), fuzzed
at 50 000 runs for the payout half, and asserted after every step of every sequence in two
invariant suites.

**Cross-series leakage.** A singleton invites one series paying out another's collateral. Asserted
per series, over several series sharing a token and a pool
(`invariant_everySeriesCoversItsOwnClaims`) — a contract-wide balance check would net a leak to
zero and see nothing.

**Rounding.** Deposits round up; withdrawals, payouts and minting round down. A subscription
round trip costs at most one wei, and sliced withdrawals cannot exceed the deposit
(`testFuzz_partialWithdrawalsCannotExceedDeposit`).

## 4. Hostile collateral tokens

| Behaviour | Outcome | Test |
|---|---|---|
| No return value (USDT) | Works | `test_noReturnToken_worksEndToEnd` |
| Reverts on zero transfer | Works — zero payouts skip the transfer | `test_revertOnZeroToken_losingSideCanStillRedeem` |
| Fee on transfer | **Rejected** at subscription, at any fee | `testFuzz_feeOnTransferToken_isRejectedAtAnyFee` |
| Reentrant callback (ERC-777) | Contained, entry and exit | `test_reentrantToken_cannotReenter*` |
| Rebasing | **Unsupported and undetected** — do not create series with one | — |

Rebasing is the live gap: a balance that changes on its own breaks the ledger silently, and
nothing in the contract notices.

## 5. Malicious or broken observers

The observer is chosen at series creation and immutable. A hostile observer can return any series
it likes, so **an observer is as trusted as the series that names it**.

Mitigations are at creation: the address must have code (`test_createSeries_rejectsObserverWithoutCode`),
`validateSource` must pass, and the core enforces its own `MAX_SAMPLES` so a third-party adapter
cannot make settlement unaffordable and strand a fully collateralised series
(`test_createSeries_rejectsGridAboveCoreCeiling`).

**Not mitigated:** nothing whitelists observers. Anyone can create a series naming a contract
they wrote. Whoever funds it is trusting that contract, and the protocol offers no opinion.

## 6. Griefing the lifecycle

| Attempt | Result |
|---|---|
| Activate a series nobody filled | Cancels, full refunds |
| Activate long after the start | Cancels past a one-hour grace, rather than entering ACTIVE against a buffer that has been overwritten |
| Settle early, twice, or on a dead series | Reverts, or voids; never leaves a series unresolvable |
| Redeem twice | Impossible — positions are burned on the way out |
| Never claim | Funds stay the holder's forever; there is no deadline and no sweep |

## 7. RFQ execution

Signed quotes carry a deadline and a maker-scoped nonce, are cancellable by nonce, and are bound
to this contract by the EIP-712 domain separator — a signature is not portable to another
deployment (`test_fill_signatureIsNotPortableAcrossDeployments`). Tampering with strike or size
invalidates the signature.

**Residual.** Quote distribution is off chain and unprotected: a relay can withhold or reorder
quotes. Since a quote is an offer rather than an obligation, the worst outcome is a trade that
does not happen.

---

## Assumed, not verified

1. **Uniswap V3 reports its own history honestly.** The protocol reads a buffer it does not
   control. A pool with modified oracle behaviour would settle whatever it wants.
2. **Block timestamps are approximately true.** Windows are hours long, so a sequencer moving
   timestamps by seconds changes nothing. Moving them by hours would.
3. **The collateral token is not rebasing.** See §4.
4. **Arbitrage exists.** Section 1's defence rests on it, and section 1's *measurement* explicitly
   does not include it.

## Known gaps, in order

1. **No external audit.** See [SECURITY.md](SECURITY.md).
2. **Arbitrage cost unmeasured** (§1) — the largest unknown in the security argument. The
   notional cap is sized against a lower bound that excludes it, which is the conservative
   direction, but the true margin is unknown.
3. **Rebasing tokens undetected** (§4).
4. **Depth is measured at a moment.** `depthQuote` reads current in-range liquidity. Liquidity
   that leaves after a series is funded shrinks the margin the cap was sized for, and nothing
   revisits it. Re-checking at settlement would let a liquidity provider void a series at will,
   which is a worse trade.
