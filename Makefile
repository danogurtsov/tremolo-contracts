.PHONY: help build test fuzz ci fmt lint snapshot reference clean coverage

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
	forge coverage --report summary

clean:
	forge clean
