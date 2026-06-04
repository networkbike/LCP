# LCP — Issue Template

Thanks for using LCP. To help us reproduce, please include:

## Environment

- LCP version: (read `version` from `assets/lcp-thresholds.json`)
- Network: `atlantic-testnet` / `mainnet`
- Target: `<address or native:PHRS / native:PROS>`
- Block height at which you ran: `<number>`

## Command / prompt

Paste the exact prompt you sent to your Agent.

## Expected vs actual

- Expected band:
- Actual band:
- Reproducer: yes / no

## Safety check

- Did you ever pass a private key to LCP? **It should be a hard no.**
- Did LCP ever attempt `cast send` or `forge script`? **It should be a hard no.**

If either answer is "yes", please open a security issue instead of a regular
bug report.
