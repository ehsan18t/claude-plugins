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

Opus then reviews the diff and merges it. Anything a worker or the reviewer found but was not allowed to do (out-of-scope work, bugs outside the brief, gaps in the plan) goes to a follow-ups file that Opus works through before finishing.

### Staying inside the brief

Each brief lists the files its worker may change (`allowed_files`). Sometimes the work hits a bug in code outside those files. The worker may fix it as an **extra edit** when it is the smallest change that fixes a proven defect blocking the brief. There is no limit on the number of files; what counts is what the change is:

- It must come with proof (a failing command, a test, or a file and line) and be declared in the worker's report.
- It may not add behaviour, refactor, rename or tidy up, or change an interface other code uses.
- It may not touch a file another brief owns, or an off-limits file (dependencies, CI, build config, migrations; see `EXTRA_EDIT_PROTECTED`) unless the brief lists it.

The script fails the gates for an undeclared edit, another brief's file, or an off-limits file. The reviewer judges every other extra edit against the rule above. A rejected one goes back to the worker for one fix round. If it is still there afterwards (or the fix round stops, errors or is discarded), the run is not failed for it, but the summary carries a `FLAG for Opus` note so Opus decides on it before merging. Extra edits that first appear in the fix round get the same flag, because no reviewer has seen them.

Anything beyond the brief that the worker noticed but must not do (a refactor, a new feature, an interface change, a cleanup, a bug that does not block it, a gap in the plan) is **flagged in its report as a follow-up**, with its kind, proof and a suggested fix. Follow-ups collect in `.shikigami/<feature>/followups.md`, and Opus works through them before finishing.

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

### Where everything lives

| What | Where | Edit it? |
|---|---|---|
| Your settings | `~/.config/shikigami/shikigami.conf` (Windows: `C:\Users\<you>\.config\shikigami\shikigami.conf`) | Yes |
| Your agent files | `~/.config/shikigami/agents/shikigami-<worker\|reviewer\|tester>.md` | Yes |
| Defaults | `skills/run/shikigami.conf` inside the plugin | No, plugin updates replace it |
| Agents OpenCode loads | `~/.config/opencode/agents/shikigami-*.md` | No, rewritten before every run |
| OpenCode config for runs | `.shikigami/opencode.jsonc` in your repo | No, rewritten before every run |

If `XDG_CONFIG_HOME` is set, it replaces `~/.config` in these paths.

### Change a setting

1. Create your settings file. In Claude Code, run `/shikigami:run config`. It writes `~/.config/shikigami/shikigami.conf` with every setting commented out, and prints the path. If the file already exists, it only prints the path.
2. Open the file, remove the `#` in front of each setting you want to change, and edit its value. For example, to switch to OpenCode Go after subscribing, run `opencode models`, find the Go IDs for DeepSeek V4.1 Flash and GLM-5.3 Flash, and set:

   ```bash
   WORKER_MODEL="<Go ID for DeepSeek V4.1 Flash>"
   REVIEWER_MODEL="<Go ID for GLM-5.3 Flash>"
   ```

   Leave out the `#effort` part of the ID; the effort settings add it.
3. That's it. Every `worker.sh` call reads the file, so the next run uses the new value without a restart. Run `/shikigami:run doctor` to confirm: it prints the models, efforts and limits it will use.

Settings are read in this order, and the last one wins: the plugin's defaults, then your settings file, then an environment variable of the same name. An environment variable is handy for a one-off change, but it must be set in the shell you start Claude Code from.

| Setting | Default | Meaning |
|---|---|---|
| `WORKER_MODEL` | `opencode/deepseek-v4.1-flash-free` | Worker model, without the `#effort` part |
| `WORKER_EFFORT` | `high` | Worker effort. Retries use `max`. |
| `REVIEWER_MODEL` | `opencode/glm-5.3-flash-free` | Second-pass reviewer |
| `REVIEWER_EFFORT` | `max` | Reviewer effort |
| `REVIEWER_FALLBACK_MODEL` | the worker model | Used when the reviewer fails or hits its limit; empty for none |
| `TEST_WRITER` | `off` | `on` adds the black-box tester (more quota, more independent tests) |
| `TESTER_MODEL` | the reviewer model | Black-box tester model |
| `TESTER_EFFORT` | `high` | Black-box tester effort |
| `MAX_PARALLEL` | `8` | Workers running at once; extra runs wait for a free slot |
| `EXTRA_EDIT_PROTECTED` | dependency manifests and lockfiles, CI and build config, migrations, and configs that run code (git hooks, `.npmrc`, editor and dev-container settings) | Files a worker may never change as an extra edit, unless the brief lists them in `allowed_files` (space-separated globs, matched ignoring case; `""` turns the check off) |
| `WORKER_TIMEOUT` | `7200` | Seconds before a hung OpenCode run is stopped |
| `ACCEPT_TIMEOUT` | `900` | Seconds for each acceptance command and the black-box test run |
| `FAIL_TAIL_LINES` | `40` | Lines of failure output shown to Opus |
| `OPENCODE_BIN` | `opencode` | OpenCode command, if it is not on your `PATH` |
| `OPENCODE_RUN_FLAGS` | `--standalone` | Extra flags for every `opencode` call |

## What the OpenCode agents can use

Shikigami installs three OpenCode agents. Each one's permissions are the rules at the top of its file in `skills/run/opencode-agents/`.

| | Worker | Reviewer | Black-box tester |
|---|---|---|---|
| Read files in its worktree | Yes, except `.env` files | Yes, except `.env` files | Yes, except `.env` files |
| Edit files | Yes, in its worktree | No | Only in `.shikigami-blackbox/` |
| Run shell commands | Yes, except git history commands (commit, reset, checkout, push, and so on), `curl`, `wget`, PowerShell web commands and package installs | No | Same as the worker |
| Web | Context7 only | Context7 and 32 documentation, issue-tracker and package-registry sites | Context7 only |
| Web search, Code Mode, subagents, skills, asking you questions | No | No | No |
| Files outside its worktree | No | No | No |

**Context7** ([context7.com](https://context7.com)) gives up-to-date library documentation. The agents reach it through web fetches to `https://context7.com/api/v2/`, not as an MCP server, because OpenCode 2.1 gives custom agents MCP tools only through Code Mode, and Code Mode is off (it can fetch any site). It works without an account, at a lower rate limit.

**Formatters:** the run config turns on OpenCode's formatters, which only run when your repo already has one set up (Prettier or Biome, for example).

**MCP servers and OpenCode plugins:** Shikigami adds none. OpenCode merges its config files, so your global OpenCode config (`~/.config/opencode/opencode.json`) and the repo's own `opencode.json` and `.opencode/` folder still load during runs. MCP servers from them stay out of reach, because Code Mode is off. OpenCode plugins and custom tools from them do load, and Shikigami's rules do not cover them, so check what you have installed before you run it on a repo that has its own `.opencode/` folder.

### Change what an agent can use

Do not edit the files in `~/.config/opencode/agents/`: they are rewritten before every run. Make your own copy instead:

1. In Claude Code, run `/shikigami:run config agent reviewer` (or `worker`, or `tester`). It copies the plugin's file to `~/.config/shikigami/agents/` and prints the path.
2. Edit the rules at the top of that copy. Each rule has an `action`, a `resource` pattern and an `effect` (`allow` or `deny`). When several rules match, the last one wins, so keep the `deny` for `"*"` first and put allow rules after it. For example, to let the reviewer read another documentation site:

   ```yaml
   - {action: webfetch, resource: "https://docs.example.com/*", effect: allow}
   ```

3. Run `/shikigami:run doctor`. It installs your copy and lists it under "your agent files".

Your copy wins over the plugin's file from then on, including after plugin updates, so you will not get later changes to that agent until you merge them in yourself. Delete your copy to go back to the plugin's version.

## Safety

- **Workers are offline**, except for [Context7](https://context7.com) library documentation. OpenCode's Code Mode is off, and the shell blocks `curl`, `wget`, PowerShell web commands and package installs. This is best effort: a script that makes its own web request can still get through, so the worker's instructions also forbid it.
- **The reviewer** may read Context7 and an allow list of documentation, issue-tracker and package-registry sites (in `opencode-agents/shikigami-reviewer.md`), with no shell and no web search. Every verdict that relies on a web page must cite it, and the summary lists every page the reviewer read or was refused.
- **Your repository's history is never touched by a worker.** Workers cannot commit, reset, switch branches or push; `worker.sh` commits on a separate branch, and Opus merges.
- **Black-box tests (`TEST_WRITER=on`)** run outside OpenCode's permissions, like the brief's acceptance commands. Their `RUN` line must be one plain command (no pipes, chaining, substitution or redirection) that starts with the same program as an acceptance command, and the test files are kept outside the worktree so the worker cannot change them. The tests themselves are still code a model wrote, so only turn the tester on for code you would run anyway.
- **Feature and brief names** may use letters, digits, `.`, `_` and `-` only, and `worker.sh` only ever deletes folders under `.shikigami/worktrees/`.
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
| `worker.sh config` | Creates your settings file and prints its path |
| `worker.sh config agent <name>` | Copies an agent file to your settings folder so you can change it |

## Known limits

- The free OpenCode tier runs out quickly with several workers. When a model hits its limit, Shikigami pauses runs for that model instead of letting each one fail.
- OpenCode 2.1 offers MCP tools to custom agents only through Code Mode, which Shikigami keeps off, so Context7 is used through its web API instead of as an MCP server.
- Quality depends on the plan. Workers trust the plan's facts, so the skill tells Opus to check runtime and platform claims with an experiment before writing them into a brief.

## License

MIT. See [LICENSE](LICENSE).
