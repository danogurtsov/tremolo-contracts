.PHONY: help build test fuzz ci fmt lint snapshot reference clean coverage mutate bias backtest verify slither deploy-dry

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
	@echo "make deploy-dry - run the deploy script against a Base fork"
	@echo "make backtest   - replay the instrument over real history"

build:
	forge build

# Deployable bytecode is always via_ir - smaller and cheaper to run. See ADR-0010.
build-deploy:
	FOUNDRY_PROFILE=ci forge build --sizes

test:
	forge test

fuzz:
	FOUNDRY_PROFILE=pr forge test

ci:
	FOUNDRY_PROFILE=ci forge test

# The Solidity is checked against this, never the other way round.
reference:
	python3 reference/variance_reference.py

# Fork tests are excluded: their gas depends on live chain state and would churn the file.
snapshot:
	forge snapshot --no-match-path "test/fork/*"

snapshot-check:
	forge snapshot --check --no-match-path "test/fork/*"

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

# Buy a pool more observation history. The buffer paradox means the deepest pools forget
# fastest, so this is an operating cost, not a workaround. ~$0.33 per 1000 slots on Base.
#   make extend-history POOL=0x... OBSERVER=0x... TARGET=5000
extend-history:
	cast send $(OBSERVER) "extendHistory(address,uint16)" $(POOL) $(TARGET) \
		--rpc-url base --private-key $$PRIVATE_KEY

# A deploy script that has never executed is a file, not a script. This runs in CI.
deploy-dry:
	FOUNDRY_PROFILE=ci forge script script/Deploy.s.sol --fork-url base

# Does the suite actually catch anything? Line coverage cannot answer that.
mutate:
	python3 tools/mutate.py --report docs/measurements/mutation_report.md

# How much variance the TWAP grid destroys, against live pools.
bias:
	python3 reference/bias_measurement.py

# Would either side have made money? Replays settlement over real history.
backtest:
	python3 reference/backtest.py

clean:
	forge clean
