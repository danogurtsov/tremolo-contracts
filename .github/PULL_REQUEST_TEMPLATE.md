## What changed

<!-- One paragraph. If this fixes something a test caught, say what it caught. -->

## Why this way

<!-- What else was considered. -->

## Checks

- [ ] `forge fmt` clean
- [ ] `make fuzz` green (via_ir — the bytecode that deploys)
- [ ] Tests fail if the new behaviour is wrong, not merely exercise it
- [ ] New constants have a measurement behind them
- [ ] `make snapshot` refreshed if gas moved
