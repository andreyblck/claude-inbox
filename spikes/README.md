# Spikes

Ground truth for the three mechanisms in PLAN.md S0. Hooks live in this repo's
`.claude/settings.json`, so they fire **only** for Claude Code sessions started in
this folder. Nothing here can affect a real work session.

## How to run

```bash
cd ~/Desktop/work/blckgh/raycast-app
claude          # then drive the session into each case below
```

Payloads land in `spikes/captured/` (git-ignored).

| # | Case | How to trigger | Verdict |
|---|------|----------------|---------|
| S0.1 | Payload shapes | any session in this folder | _pending_ |
| S0.2 | `AskUserQuestion` intercept | ask Claude something that makes it offer options | _pending_ |
| S0.3 | `ExitPlanMode` intercept | enter plan mode, let it propose a plan | _pending_ |
| S0.4 | `Stop` + `asyncRewake` late answer | finish a turn, answer 2 min later | _pending_ |

## Findings

(fill in per case: captured payload excerpt, what the model did, verdict)
