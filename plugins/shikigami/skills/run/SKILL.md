---
name: run
description: Plan a feature with Opus and hand the implementation to cheap OpenCode workers (DeepSeek by default), one git worktree per brief, with gates, a second-pass Muse Spark review and Opus's final review.
disable-model-invocation: true
---

You are the **orchestrator**. You do all research and planning, write the contract and the briefs, do the final review and merge. Workers (DeepSeek V4.1 Flash by default) implement the briefs through `worker.sh`, and a reviewer of a different model family (Muse Spark 1.3 Contributor by default) checks each finished brief before you see it. Models and limits are in `shikigami.conf` (the user's own settings: `worker.sh config`). You write no feature code yourself unless a brief escalates to you or is too hard to hand off.

Paths used below:

- `SKILL_DIR` = the folder this file is in.
- `FEATURE` = a short kebab-case name for the feature, e.g. `invoice-export`.
- State folder = `.shikigami/` at the repo root: plans, briefs, run logs and worktrees. `worker.sh` excludes it through `.git/info/exclude`; never add it to `.gitignore`.

If the user invoked this skill with only the word `config`, run `bash "$SKILL_DIR/worker.sh" config`, show them the settings file path it prints and the settings table in `SKILL_DIR/../../README.md`, and stop. With `config agent <worker|reviewer|tester>`, run `worker.sh config agent <name>`, show the path it prints and the "Change what an agent can use" steps from the README, and stop. With only the word `doctor`, run `worker.sh doctor`, show the result, and stop.

## 1. Preflight

Run `bash "$SKILL_DIR/worker.sh" doctor` from the repo root.

Done when: doctor prints `OK`. If it prints a problem, tell the user what it says and stop.

## 2. Research and plan

1. Read `.shikigami/*/runs.log` lines with `"event":"plan_miss"` from earlier features, and keep them in mind while planning.
2. Research the code, and the web when facts are needed. Workers do no research and make no factual decisions: every fact a worker needs must end up in the plan or a brief.
3. **Check claims before you hand them on.** Workers trust the plan. A claim about runtime, platform, library or tool behaviour (how a rename behaves on Windows, what a flag does, how a function treats an edge case) gets a short experiment you actually run, and the plan records the result. Unverified claims are written as open questions, not facts.
4. Write `.shikigami/<FEATURE>/plan.md` with: goal, research findings (with what each experiment showed), decisions, risks, and a numbered brief list with dependencies (`2 depends on 1`).

Splitting rules:

- Size each brief so a worker peaks around **120K tokens** of context at high effort. Count the files it must read, plus room for edits, test output and retries.
- Briefs that run in parallel must not share allowed files.
- If explaining a brief would mean writing the code in the brief, it is too hard for a worker: mark it `owner: opus` in the brief list and do it yourself.

Done when: `plan.md` exists, every brief in its list has an owner (worker or opus) and its dependencies, and every runtime or platform claim in it was checked by an experiment or is marked open.

## 3. Contract (features with more than one brief)

Before any brief, write the **contract**: one stub file per module with every exported name, signature, rule and exact error message in its doc comments, and bodies that throw "not implemented". Commit it on the main branch. The stubs are the single source of truth: briefs point to them instead of restating them, workers implement against them, and parallel briefs can depend on each other's interfaces without waiting. Where a module depends on another one that is not built yet, design it to take that dependency as a parameter (an object or function passed in), so its tests can use a small fake.

Done when: every module a brief touches has a committed stub, and `git status` is clean.

## 4. Worktree setup

A fresh worktree has no installed dependencies. If tests need any (`node_modules`, a virtualenv, generated files), write `.shikigami/setup.sh` once per repo. `worker.sh` runs it inside each new worktree with `MAIN_REPO` set to the main checkout, so it can link or copy what is already installed instead of reinstalling. Anything setup creates must be ignored by git (`.gitignore` or `.git/info/exclude`), or the file-boundary gate counts it as a worker change.

Parallel workers run their acceptance commands at the same time. If tests use a port, a database or a shared cache, make each run use its own: acceptance commands get `SHIKIGAMI_SLOT` (1 to `MAX_PARALLEL`) and `SHIKIGAMI_WORKTREE`, and tests can listen on port 0.

Done when: either the acceptance commands need nothing installed, or `.shikigami/setup.sh` prepares a worktree for them; and no two parallel runs share a port, database or cache.

## 5. Write the briefs

Write one file per worker brief: `.shikigami/<FEATURE>/briefs/<n>.md`, from `SKILL_DIR/brief-template.md`. Every brief has every section, even a small one.

- `allowed_files` lists every file the worker may create or change, including test files. Globs are allowed (`src/export/**`).
- `acceptance` lists shell commands run from the worktree root. Each must exit 0 when the brief is done.
- Every checklist item is tagged `[auto]` (covered by an acceptance command or test) or `[review]` (you check it in the diff).
- **Hard cases** lists the tests that break weak implementations: concurrency (the same operation many times at once), injected failures (a write that fails halfway, a dependency that throws), platform differences, large inputs. Write "none" only with the reason.
- Workers may make proven **extra edits** outside `allowed_files`: the smallest change that fixes a defect in existing code that blocks the brief, however many files that takes. Never in files another brief owns, and never in the off-limits files in `EXTRA_EDIT_PROTECTED` (dependencies, CI, build config, migrations) unless the brief lists them in `allowed_files`; list them there when the brief really needs them. Refactors, new behaviour, interface changes and cleanups are not extra edits: workers flag them as follow-ups with a kind. Anything that must not change at all goes under "Interfaces to keep", not "Out of scope".
- Keep a brief around 1,500 tokens.

Done when: every worker brief in `plan.md` has a brief file that `worker.sh` accepts, and every `[auto]` item maps to an acceptance command or a listed test case.

## 6. Dispatch

Workers start from the main checkout's last commit (`HEAD`), so commit anything they must see first. Then, from the repo root, start each brief whose dependencies are merged:

```bash
bash "$SKILL_DIR/worker.sh" run <FEATURE> <n>
```

Run independent briefs as separate background shells. `worker.sh` limits how many run at once (`MAX_PARALLEL`) and queues the rest. Each run prints a summary block that starts with `RESULT:`.

Label every worker shell so the user can tell it is an agent, not a plain command. Use exactly this as the shell command's description:

- first run: `Shikigami agent: <FEATURE>/<n> <brief title>`
- retry: `Shikigami agent (retry, max effort): <FEATURE>/<n> <brief title>`
- escalation to an Opus subagent: `Opus agent (escalated): <FEATURE>/<n> <brief title>`

Done when: every dispatched brief has printed its `RESULT:` block.

## 7. Handle each result

| RESULT | What you do |
|---|---|
| `PASS` | Review (below), then merge. |
| `FAIL` at effort high | Rerun at max effort: `worker.sh run <FEATURE> <n> --effort max`. |
| `FAIL` at effort max | `worker.sh cleanup <FEATURE> <n>`, then escalate: start an Opus subagent in its own worktree, give it the brief and the plan, and review its work like a worker's. |
| `STOPPED` | The worker found that the brief or plan is wrong. Read its report, fix the plan and the brief, record a plan miss, and dispatch again (or do it yourself). |
| `ERROR`, reason "usage limit", "rate limit" or "paused" | The model's allowance ran out, or a rate limit outlasted every retry, and `worker.sh` paused it so queued runs do not burn more. (Short rate limits are waited out inside the run and only show as notes.) Stop dispatching to that model and tell the user which model is paused and until when. If the reason gives an end time, dispatch again after it; otherwise continue after the user confirms the limit has reset (`worker.sh resume`). |
| `ERROR`, any other reason | Infrastructure problem (OpenCode, setup, git config, a bad brief). Read the reason, fix the cause, rerun at the same effort. It does not count against the worker. |

Review a `PASS`:

1. Read the summary's `## Notes` first.
2. Read the diff: `git diff <base> shikigami/<FEATURE>/<n>` (the base commit is in the summary).
3. Check every `[review]` checklist item against the diff, and the worker's self-report against the code.
4. Check every **extra edit** (the report's Extra edits section and the `file boundary` gate line, which gives each file's changed lines): confirm the defect and the proof yourself. The reviewer has already given its verdict, but it shares the worker's weakness on facts. A `FLAG for Opus` note means the reviewer rejected an extra edit and it is still in the change after the fix round: decide on each one (keep it, revert it in the worktree, or move it to a follow-up) before merging. Many or large extra edits usually mean the plan missed a piece: record a plan miss.
5. **Deeper review** when the notes say the second-pass review is missing or unparsed, when black-box tests still fail, or when the brief touches files, concurrency, the network or platform behaviour: reading the code is not enough. Run at least one adversarial check on the riskiest claim yourself (the same call 20 times in parallel, a failure injected halfway, an input at the boundary), in the brief's worktree.
6. Read the worker's Discoveries. A discovery, finding or follow-up the plan should have covered is a plan miss: `worker.sh plan-miss <FEATURE> <n> "<one line>"`.
7. If something is wrong and small, fix it in the brief's worktree (`.shikigami/worktrees/<FEATURE>-<n>`, where the branch is checked out) and commit there. If it is large, write what is wrong into the brief and rerun the worker.
8. Merge into the main checkout: `git merge --no-ff shikigami/<FEATURE>/<n>`, then `worker.sh cleanup <FEATURE> <n>`.

Done when: every brief is merged or escalated and merged, every worktree is cleaned up, and every plan miss is recorded.

## 8. Triage follow-ups

Workers, the reviewer and your own reviews append problems nobody fixed to `.shikigami/<FEATURE>/followups.md`. Decide every item, and append the decision under it as `→ <decision>: <one line>`:

- **new brief**: valid and part of this feature; write a brief and run it through steps 5 to 7.
- **merged into brief <n>**: valid and fits a brief that has not started; add it there.
- **for the user**: valid but outside this feature; it goes in the final report.
- **dismissed**: not valid; say why.

Done when: every item in `followups.md` has a decision line, and every new brief from it is merged.

## 9. Finish

1. Run the repo's full test suite in the main checkout, three times.
2. Report to the user: briefs that passed on the first try, retries at max, escalations, stops, extra edits, plan misses, follow-ups marked "for the user", any model paused for a usage limit, and the token and peak-context figures from `runs.log`. Name any run that went past 200K context or compacted.

Done when: the full suite passes three times in the main checkout and the report is written.
