# Contributing

## Running things

```bash
forge install          # submodules
forge test             # fast local suite, ~70s
make fuzz              # 5k fuzz runs + deeper invariants, before pushing
make ci                # what CI runs: 50k fuzz, via_ir, full depth
```

Fork tests need no configuration — they fall back to a public Base archive endpoint. Point
`BASE_RPC_URL` at a private node if you have one; see `.env.example`.

| Command | What it does |
|---|---|
| `make verify` | halmos symbolic proofs (three properties; see docs/measurements/formal_verification.md) |
| `make slither` | static analysis |
| `make mutate` | mutation testing — does the suite catch anything |
| `make bias` | re-measure TWAP bias against live pools |
| `make backtest` | replay the instrument over real history |
| `make snapshot` | refresh the gas snapshot |
| `make deploy-dry` | run the deploy script against a Base fork |

## What a change needs

**Anything touching `src/` needs a test** that fails if the behaviour is wrong, not just one
that exercises the code. Mutation testing exists in this repository because line coverage does
not answer that question.

**A number needs a measurement.** Parameters in this codebase come from
`docs/measurements/`, not from judgement. `MAX_SAMPLES` is 256 because 1024 costs 48.68M gas;
`minCompletenessBps` is 10000 because below that the estimate stops having a pattern; the
notional cap exists because manipulation was priced by carrying it out. New constants need a measurement behind them.

**Say what is not covered.** Every document here states its own limits — the backtest says 11.5
days is too short to price anything, the formal verification says which four properties do not
discharge and why, the manipulation measurement says its figure is a lower bound because forks
have no arbitrageurs.

## Before pushing

```bash
forge fmt && make fuzz && make snapshot
```

`make fuzz` compiles with `via_ir`, which is what deploys; differences that only appear under
the real pipeline should not reach main.

## Commit messages

Conventional prefixes, plus `measure:` for a measurement and `invariant:` for properties. The
body explains why, and a commit that changed behaviour because a test caught something says
what it caught.
