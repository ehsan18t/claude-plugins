# Shikigami

A Claude Code plugin for building features with less Opus usage. Opus plans the feature, writes a contract and one brief per piece, and does the final review. Cheap models in [OpenCode](https://opencode.ai) do the implementation and a second-pass review, each piece in its own git worktree, several at a time.

In onmyōdō folklore, a shikigami is a spirit a sorcerer summons to act on their behalf. Here, Opus is the sorcerer.

## How it works

| Role | Default model | Job |
|---|---|---|
| Orchestrator | Claude Opus (your Claude Code session) | Research, plan, contract stubs, briefs, final review, merge |
| Worker | DeepSeek V4.1 Flash | Implements one brief in its own worktree |
| Reviewer | GLM-5.3 Flash | Checks each finished brief for gaps and verifies every out-of-scope edit |
| Black-box tester (optional) | GLM-5.3 Flash | Writes tests from the brief and contract alone, without seeing the worker's code |

For each brief, `worker.sh`:

1. creates a worktree and branch from your last commit;
2. runs the worker, which follows a fixed protocol: pre-flight, implement, self-review, and a self-report;
3. runs the gates: the brief's acceptance commands, plus a file-boundary check (only the brief's files, or declared and proven extra edits);
4. runs the reviewer, sends any gaps back to the worker for one fix round, and commits;
5. prints a summary for Opus: the result, tokens, peak context, gates, the self-report and the review.

Opus then reviews the diff and merges it. Problems nobody could fix go to a follow-ups file that Opus works through before finishing.

## Requirements

- [Claude Code](https://code.claude.com)
- [OpenCode](https://opencode.ai) v2 or newer, signed in. The free tier works for trying it out, but its allowance is small and shared across models; [OpenCode Go](https://opencode.ai/docs/go/) is the realistic option for whole features.
- Node.js 18 or newer
- Git, and bash (on Windows, Git Bash)

Tested on Windows with Git Bash. It is written to run on macOS and Linux too (it falls back to `gtimeout` or `perl` where `timeout` is missing), but those have not been tested yet.

## Install

```bash
claude plugin marketplace add ehsan18t/claude-plugins
```

```bash
claude plugin install shikigami@ehsan18t
```

Then, in a repository, start Claude Code and run:

```
/shikigami:run
```

and describe the feature. The first step runs `worker.sh doctor`, which checks your tools, OpenCode version and models, and installs the three OpenCode agents into `~/.config/opencode/agents/`.

## Configuration

The defaults are in `skills/run/shikigami.conf`. Do not edit that file, because plugin updates replace it. Create your own settings file instead, from Claude Code:

```
/shikigami:run config
```

That writes `~/.config/shikigami/shikigami.conf` with every setting commented out. Uncomment what you change. An environment variable of the same name beats both files.

| Setting | Default | Meaning |
|---|---|---|
| `WORKER_MODEL` | `opencode/deepseek-v4.1-flash-free` | Worker model. On Go, run `opencode models` and use the Go ID. |
| `WORKER_EFFORT` | `high` | Worker effort. Retries use `max`. |
| `REVIEWER_MODEL` | `opencode/glm-5.3-flash-free` | Second-pass reviewer |
| `REVIEWER_EFFORT` | `max` | Reviewer effort |
| `REVIEWER_FALLBACK_MODEL` | the worker model | Used when the reviewer fails or hits its limit; empty for none |
| `TEST_WRITER` | `off` | `on` adds the black-box tester (more quota, more independent tests) |
| `MAX_PARALLEL` | `8` | Workers running at once |
| `EXTRA_EDIT_MAX_FILES` | `2` | Files a worker may change outside its brief, with proof |
| `WORKER_TIMEOUT` | `7200` | Seconds before a hung run is stopped |

## Safety

- **Workers are offline**, except for [Context7](https://context7.com) library documentation. OpenCode's Code Mode is off, and the shell blocks `curl`, `wget`, PowerShell web commands and package installs. This is best effort: a script that makes its own web request can still get through, so the worker's instructions also forbid it.
- **The reviewer** may read Context7 and an allow list of documentation, issue-tracker and package-registry sites (in `opencode-agents/shikigami-reviewer.md`), with no shell and no web search. Every verdict that relies on a web page must cite it, and the summary lists every page the reviewer read or was refused.
- **Your repository's history is never touched by a worker.** Workers cannot commit, reset, switch branches or push; `worker.sh` commits on a separate branch, and Opus merges.
- **Data:** the code in each brief is sent to the worker and reviewer models through OpenCode. Check the data terms of the plan and models you use before running it on code you are not allowed to share.

## Files it creates in your repository

Everything lives in `.shikigami/` and a few worktree-only names, all excluded through `.git/info/exclude` (your `.gitignore` is not changed):

- `.shikigami/<feature>/plan.md` and `briefs/`: the plan and briefs Opus writes
- `.shikigami/<feature>/runs.log`: one JSON line per run (result, tokens, peak context, time)
- `.shikigami/<feature>/followups.md`: problems found but not fixed
- `.shikigami/worktrees/`: one worktree per running brief

## worker.sh commands

| Command | What it does |
|---|---|
| `worker.sh doctor` | Checks tools, OpenCode, models and git; installs the agents |
| `worker.sh run <feature> <n> [--effort max]` | Runs one brief and prints its summary |
| `worker.sh cleanup <feature> <n>` | Removes a brief's worktree and branch |
| `worker.sh plan-miss <feature> <n> "<note>"` | Records something the plan should have covered |
| `worker.sh resume [model]` | Lifts the pause after a model's usage limit resets |
| `worker.sh config` | Creates your settings file |

## Known limits

- The free OpenCode tier runs out quickly with several workers. When a model hits its limit, Shikigami pauses runs for that model instead of letting each one fail.
- OpenCode 2.1 offers MCP tools to custom agents only through Code Mode, which Shikigami keeps off, so Context7 is used through its web API instead of as an MCP server.
- Quality depends on the plan. Workers trust the plan's facts, so the skill tells Opus to check runtime and platform claims with an experiment before writing them into a brief.

## License

MIT. See [LICENSE](LICENSE).
