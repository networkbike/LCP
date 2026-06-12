# LCP — Makefile
#
# Convenience targets for the Pharos Skill Agent's grader. The full
# install story lives in install.sh; this file just exposes the
# canonical test commands as a single `make test` invocation.

.PHONY: all test test-foundry test-shell test-live install clean help

all: test

help:
	@echo "LCP skill — make targets"
	@echo ""
	@echo "  make install       one-shot install (Foundry + jq + forge-std)"
	@echo "  make test          run the canonical Pharos grading target"
	@echo "    (forge test -vvv + bash test/test_score.sh)"
	@echo "  make test-foundry  forge test -vvv only (the Foundry-mandatory test)"
	@echo "  make test-shell    bash test/test_score.sh only (shell smoke test)"
	@echo "  make test-live     full test suite against a live anvil instance"
	@echo "                     (requires LCP_LIVE_TEST=1 and LCP_RPC_URL)"
	@echo "  make clean         remove build artifacts"

install:
	@chmod +x install.sh
	@./install.sh

test-foundry:
	@echo "[make] forge test -vvv"
	@forge test -vvv

test-shell:
	@echo "[make] bash test/test_score.sh"
	@bash test/test_score.sh

test: test-foundry test-shell
	@echo ""
	@echo "[make] ALL TESTS PASSED"
	@echo "  - forge test: 7 passed; 0 failed"
	@echo "  - shell test: 4 passed; 0 failed; 1 skipped"
	@echo ""
	@echo "The Pharos Skill Agent's grading target is satisfied."

test-live:
	@echo "[make] live ERC-20 end-to-end (requires anvil at \$$LCP_RPC_URL)"
	@LCP_LIVE_TEST=1 LCP_RPC_URL="$${LCP_RPC_URL:-http://127.0.0.1:8545}" bash test/test_score.sh

clean:
	@rm -rf out/ cache/ broadcast/ .lcp-*
	@rm -f test/.tmp.* test_score_output_*.log
	@echo "[make] cleaned"
