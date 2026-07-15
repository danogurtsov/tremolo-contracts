.PHONY: help build test fuzz ci fmt lint snapshot reference clean coverage mutate bias verify slither

help:
	@echo "make build      - compile contracts"
	@echo "make test       - fast local suite"
	@echo "make fuzz       - longer fuzz + invariant run (pre-push)"
	@echo "make ci         - full run, as CI executes it"
	@echo "make reference  - regenerate differential fixtures from the Python reference"
	@echo "make snapshot   - write gas snapshot"
	@echo "make fmt        - format"
	@echo "make lint       - forge lint"
	@echo "make coverage   - line coverage report"
	@echo "make verify     - symbolic proofs (halmos)"
	@echo "make slither    - static analysis"
	@echo "make mutate     - mutation testing"
	@echo "make bias       - measure grid bias against live pools"

build:
	forge build

test:
	forge test

fuzz:
	FOUNDRY_PROFILE=pr forge test

ci:
	FOUNDRY_PROFILE=ci forge test

# The Solidity is checked against this, never the other way round.
reference:
	python3 reference/variance_reference.py

snapshot:
	forge snapshot --snap .gas-snapshot

fmt:
	forge fmt

lint:
	forge lint

coverage:
	forge coverage --report summary --no-match-path "test/fork/*"

# Symbolic proofs. Three properties discharge; the four that do not are documented in
# docs/measurements/formal_verification.md rather than reported as passing.
verify:
	halmos --match-contract VarianceMathSymbolicTest --solver-timeout-assertion 60000

slither:
	slither . --config-file slither.config.json

# Does the suite actually catch anything? Line coverage cannot answer that.
mutate:
	python3 tools/mutate.py --report docs/measurements/mutation_report.md

# How much variance the TWAP grid destroys, against live pools.
bias:
	python3 reference/bias_measurement.py

clean:
	forge clean
