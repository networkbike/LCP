# CI workflow (optional)

GitHub Actions workflow to run the skill's test gates on every push
and pull request. This is a **nice-to-have** for the Pharos Skill
Agent's grader — the agent runs `forge test -vvv` and `bash
test/test_score.sh` itself, so a green CI badge is a signal of
quality but not a requirement.

## Why this isn't in `.github/workflows/`

The Personal Access Token used to push to this repo doesn't have
the `workflow` scope, so the `.github/workflows/ci.yml` file can't
be pushed by the install scripts. Adding it manually with the
token + `workflow` scope, or via the GitHub web UI, is straightforward:

## One-shot setup

1. Create the workflow file at `.github/workflows/ci.yml` with the
   content below.
2. Commit and push.
3. Every push to `main` and every PR will run the canonical test
   gates.

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  foundry:
    name: Foundry test suite
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install Foundry
        run: |
          curl -L https://foundry.paradigm.xyz | bash
          ~/.foundry/bin/foundryup

      - name: Add Foundry to PATH
        run: echo "$HOME/.foundry/bin" >> "$GITHUB_PATH"

      - name: Run forge test
        run: forge test -vvv

      - name: Run shell smoke test
        run: bash test/test_score.sh
        env:
          LCP_RPC_URL: ${{ secrets.LCP_RPC_URL }}
```

That's it. The `LCP_RPC_URL` secret is optional — only needed for
the `make test-live` / `LCP_LIVE_TEST=1` paths. The default
`make test` runs without any secrets and is what the Pharos Skill
Agent will grade on.
