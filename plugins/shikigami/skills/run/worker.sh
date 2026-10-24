#!/usr/bin/env bash
# worker.sh: run one worker on one brief in its own git worktree, gate it, review it, report.
#
#   worker.sh doctor                                 check tools, OpenCode, models and git setup
#   worker.sh run <feature> <brief> [--effort max]   implement one brief (prints a RESULT: block)
#   worker.sh cleanup <feature> <brief>              remove the brief's worktree and branch
#   worker.sh plan-miss <feature> <brief> "<note>"   record something the plan should have covered
#   worker.sh resume [model]                         lift a usage-limit pause (all models, or one)
#   worker.sh config                                 create your settings file and print its path
#
# Run from the main checkout of the repo. Exit codes for run: 0 PASS, 1 FAIL, 2 STOPPED, 3 ERROR.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/shikigami/shikigami.conf"
# Your settings first, then the defaults; both use ${NAME:-...}, so an environment variable beats both.
# shellcheck source=/dev/null
[ -f "$USER_CONF" ] && source "$USER_CONF"
# shellcheck source=shikigami.conf
source "$SKILL_DIR/shikigami.conf"

STATE=".shikigami"
REPORT_NAME=".shikigami-report.md"
INPUT_DIR=".shikigami-input"
BLACKBOX_DIR=".shikigami-blackbox"
MIN_OPENCODE="2.0.0"
EXCLUDES=("$STATE/" "$INPUT_DIR/" "$REPORT_NAME" "$BLACKBOX_DIR/")
LIMIT_PATTERN='usage limit|rate limit|quota|too many requests|insufficient (credit|balance)|\b429\b'

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi; }
unixpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "$1"; fi; }
lib() { node "$(native "$SKILL_DIR/lib.mjs")" "$@"; }
usage() { sed -n '3,10p' "$SKILL_DIR/worker.sh"; }
need() { [ -n "${1:-}" ] || { echo "RESULT: ERROR"; echo "reason: missing argument: $2"; usage; exit 3; }; }
# safe_name <value> <what>: feature and brief names become paths and branch names, so no slashes or "..".
safe_name() {
  need "${1:-}" "$2"
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$1" != *..* ]] \
    || { echo "RESULT: ERROR"; echo "reason: bad $2 name '$1': use letters, digits, '.', '_' and '-' only"; exit 3; }
}
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
model_label() { case "$1" in *glm*) echo GLM ;; *deepseek*) echo DeepSeek ;; *claude*|*anthropic*) echo Claude ;; *) echo "${1##*/}" ;; esac; }

# run_timeout <seconds> <command...>: GNU timeout, Homebrew gtimeout, or a perl fallback (macOS ships perl).
# A timed-out command returns 124 (timeout/gtimeout) or 142 (perl's SIGALRM).
run_timeout() {
  local s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
  else perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"; fi
}
timed_out() { [ "$1" -eq 124 ] || [ "$1" -eq 142 ]; }

find_opencode() {
  command -v "$OPENCODE_BIN" >/dev/null 2>&1 && return 0
  local c
  for c in "${APPDATA:-}/npm/opencode" "$HOME/AppData/Roaming/npm/opencode" "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode" "/opt/homebrew/bin/opencode" "/usr/local/bin/opencode"; do
    [ -x "$c" ] && { OPENCODE_BIN="$c"; return 0; }
  done
  return 1
}
oc_version() { "$OPENCODE_BIN" --version </dev/null 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }

repo_root() {
  local top common gitdir
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "worker.sh: not inside a git repository" >&2; return 1; }
  common="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
  gitdir="$(cd "$(git rev-parse --git-dir)" && pwd)"
  [ "$common" = "$gitdir" ] || { echo "worker.sh: run this from the main checkout, not from a worktree" >&2; return 1; }
  unixpath "$top"
}

ensure_excludes() {
  local exc="$ROOT/.git/info/exclude" p
  mkdir -p "$(dirname "$exc")"; touch "$exc"
  for p in "${EXCLUDES[@]}"; do grep -qxF "$p" "$exc" || printf '%s\n' "$p" >> "$exc"; done
}

sync_agents() {
  local dst="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/agents" f
  mkdir -p "$dst"
  for f in "$SKILL_DIR"/opencode-agents/*.md; do
    cmp -s "$f" "$dst/$(basename "$f")" || cp "$f" "$dst/"
  done
}

# OpenCode config used only by these runs (OPENCODE_CONFIG); the user's global config is untouched.
# Context7 is reached through webfetch to its HTTP API (allowed in the agent files), not as an MCP server:
# OpenCode 2.1 offers MCP tools to custom agents only through Code Mode, which the agents keep off.
write_oc_config() {
  local f="$ROOT/$STATE/opencode.jsonc"
  mkdir -p "$ROOT/$STATE"
  printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "formatter": true\n}\n' > "$f"
  export OPENCODE_CONFIG; OPENCODE_CONFIG="$(native "$f")"
}

# Serialise git operations on the shared repo (worktree add/remove, branch delete).
with_git_lock() {
  local lock="$ROOT/$STATE/.gitlock" waited=0 rc
  mkdir -p "$ROOT/$STATE"
  until mkdir "$lock" 2>/dev/null; do
    sleep 1; waited=$((waited + 1))
    if [ "$waited" -ge 120 ]; then rm -rf "$lock"; waited=0; fi   # holder died; break the lock once
  done
  "$@"; rc=$?
  rm -rf "$lock"
  return $rc
}

acquire_slot() {
  local dir="$ROOT/$STATE/.slots" i d p
  mkdir -p "$dir"
  while :; do
    for i in $(seq 1 "$MAX_PARALLEL"); do
      d="$dir/$i"
      if mkdir "$d" 2>/dev/null; then echo $$ > "$d/pid"; SLOT="$d"; SLOT_NO="$i"; return; fi
      p="$(cat "$d/pid" 2>/dev/null || true)"
      if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && [ "$(cat "$d/pid" 2>/dev/null)" = "$p" ]; then
        mv "$d" "$d.stale.$$" 2>/dev/null && rm -rf "$d.stale.$$"
      fi
    done
    sleep 5
  done
}

release_slot() { [ -n "${SLOT:-}" ] && rm -rf "$SLOT"; SLOT=""; }

remove_worktree() {
  local wt="$1" br="$2"
  case "$wt" in "$ROOT/$STATE/worktrees/"?*) ;; *) echo "refusing to remove $wt: not under $STATE/worktrees" >&2; return 1 ;; esac
  if [ -d "$wt" ]; then git -C "$ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"; fi
  git -C "$ROOT" worktree prune >/dev/null 2>&1
  [ -n "$br" ] && git -C "$ROOT" show-ref --verify --quiet "refs/heads/$br" && git -C "$ROOT" branch -D "$br" >/dev/null 2>&1
  return 0
}

add_worktree() { git -C "$ROOT" worktree add -q -b "$2" "$1" "$3"; }
add_detached_worktree() { git -C "$ROOT" worktree add -q --detach "$1" "$2"; }

# ---------- usage-limit pause ----------

PAUSE_FILE() { printf '%s\n' "$ROOT/$STATE/paused"; }

pause_model() {
  # pause_model <model> <message>: later runs for this model fail fast until `worker.sh resume`.
  mkdir -p "$ROOT/$STATE"
  printf '%s\t%s\t%s\n' "$1" "$(date '+%Y-%m-%d %H:%M')" "$(tr '\t\n' '  ' <<<"$2")" >> "$(PAUSE_FILE)"
}

paused_since() { [ -f "$(PAUSE_FILE)" ] && awk -F'\t' -v m="$1" '$1==m {print $2; exit}' "$(PAUSE_FILE)"; }

cmd_resume() {
  ROOT="$(repo_root)" || exit 3
  local f; f="$(PAUSE_FILE)"
  if [ ! -f "$f" ]; then echo "nothing is paused"; return 0; fi
  if [ -n "${1:-}" ]; then
    awk -F'\t' -v m="$1" '$1!=m' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    [ -s "$f" ] || rm -f "$f"
    echo "resumed $1"
  else
    rm -f "$f"; echo "resumed all models"
  fi
}

# ---------- doctor / config ----------

cmd_config() {
  if [ ! -f "$USER_CONF" ]; then
    mkdir -p "$(dirname "$USER_CONF")"
    sed 's/^\([A-Z_]*\)=/# \1=/' "$SKILL_DIR/shikigami.conf" > "$USER_CONF"
    echo "created $USER_CONF (every setting is commented out; uncomment the ones you change)"
  else
    echo "$USER_CONF"
  fi
}

cmd_doctor() {
  local problems=() v models m
  command -v git >/dev/null || problems+=("git not found")
  if command -v node >/dev/null; then
    v="$(node -p 'process.versions.node' 2>/dev/null)"
    version_ge "$v" "18.0.0" || problems+=("node $v is too old (18 or newer needed)")
  else
    problems+=("node not found (needed for lib.mjs)")
  fi
  if ! find_opencode; then
    problems+=("OpenCode CLI not found (install OpenCode v2, or set OPENCODE_BIN in $USER_CONF)")
  else
    v="$(oc_version)"
    version_ge "${v:-0.0.0}" "$MIN_OPENCODE" || problems+=("OpenCode ${v:-unknown} is too old: $MIN_OPENCODE or newer is needed")
    # shellcheck disable=SC2086
    models="$("$OPENCODE_BIN" models $OPENCODE_RUN_FLAGS </dev/null 2>&1)"
    for m in "$WORKER_MODEL" "$REVIEWER_MODEL" ${REVIEWER_FALLBACK_MODEL:+"$REVIEWER_FALLBACK_MODEL"} ${TESTER_MODEL:+"$TESTER_MODEL"}; do
      grep -qxF "$m" <<<"$models" || problems+=("model $m not listed by \`opencode models\`: $(head -3 <<<"$models" | tr '\n' ' ')")
    done
  fi
  if ROOT="$(repo_root 2>/dev/null)"; then
    git -C "$ROOT" config user.email >/dev/null || problems+=("git user.email is not set, so worker branches cannot be committed")
    ensure_excludes
    [ -f "$(PAUSE_FILE)" ] && problems+=("paused after a usage limit: $(cut -f1,2 "$(PAUSE_FILE)" | tr '\t\n' ' ;')run \`worker.sh resume\` once it resets")
  else
    problems+=("not in the main checkout of a git repository")
  fi
  [ -d "$SKILL_DIR/opencode-agents" ] || problems+=("missing $SKILL_DIR/opencode-agents")
  if [ ${#problems[@]} -eq 0 ]; then
    sync_agents
    echo "OK (OpenCode $(oc_version); worker $WORKER_MODEL at $WORKER_EFFORT; reviewer $REVIEWER_MODEL at $REVIEWER_EFFORT; black-box tester ${TEST_WRITER}; max $MAX_PARALLEL parallel)"
  else
    printf 'PROBLEM: %s\n' "${problems[@]}"
    return 1
  fi
}

# ---------- run ----------

finish() {
  # finish <RESULT> <reason>: log the run, print the summary block, exit with the RESULT code.
  local result="$1" reason="$2" code dur fu=""
  case "$result" in PASS) code=0 ;; FAIL) code=1 ;; STOPPED) code=2 ;; *) code=3 ;; esac
  dur=$(( $(date +%s) - START ))
  stop_tester
  if [ "$result" != ERROR ] && [ -s "${REPORT:-/nonexistent}" ]; then
    # The latest round's report is the worker's current view; earlier rounds may list items it has since fixed.
    fu="$(lib followups "$(native "${ROUND_REPORT:-$REPORT}")" "$(native "${REVIEW:-$REPORT.none}")")"
    if [ -n "$fu" ]; then
      FOLLOWUPS="$(grep -c '^- ' <<<"$fu")"
      printf '\n### brief %s, attempt %s (%s, %s)\n%s\n' "$ID" "$ATTEMPT" "$result" "$(date '+%Y-%m-%d %H:%M')" "$fu" >> "$PLAN_DIR/followups.md"
    fi
  fi
  if [ -n "${LOG:-}" ]; then
    lib log "$(native "$LOG")" event=run feature="$FEATURE" brief="$ID" attempt="${ATTEMPT:-0}" effort="$EFFORT" \
      result="$result" reason="$reason" variant="${VARIANT_SEEN:-}" worker_model="$WORKER_MODEL" reviewer="${REVIEWER_SEEN:-}" \
      tokens_input="${T_INPUT:-0}" tokens_output="${T_OUTPUT:-0}" tokens_reasoning="${T_REASONING:-0}" \
      cache_read="${T_CACHE_READ:-0}" cache_write="${T_CACHE_WRITE:-0}" cost="${T_COST:-0}" \
      peak_context="${PEAK:-0}" compacted="${COMPACTED:-0}" fix_round="${FIX_ROUND:-0}" \
      discoveries="${DISCOVERIES:-0}" findings_inside="${FD_INSIDE_TOTAL:-0}" findings_outside="${FD_OUTSIDE_TOTAL:-0}" \
      review="${REVIEW_STATUS:-none}" blackbox="${BB_STATUS:-off}" extra_edits="${SC_EXTRA:-0}" followups="${FOLLOWUPS:-0}" \
      duration_s="$dur" base="${BASE:-}" branch="${BR:-}"
  fi
  {
    echo "RESULT: $result"
    echo "reason: $reason"
    echo "brief: $FEATURE/$ID${TITLE:+ ($TITLE)}  attempt: ${ATTEMPT:-0}  worker: $WORKER_MODEL at $EFFORT${VARIANT_SEEN:+ (ran at: $VARIANT_SEEN)}${REVIEWER_SEEN:+  reviewer: $REVIEWER_SEEN}"
    [ -n "${BR:-}" ] && echo "branch: $BR  base: ${BASE:-}  worktree: ${WT:-}"
    echo "tokens: input ${T_INPUT:-0}, output ${T_OUTPUT:-0}, reasoning ${T_REASONING:-0}, cache read ${T_CACHE_READ:-0}, cache write ${T_CACHE_WRITE:-0}  cost: \$${T_COST:-0}"
    echo "peak context: ${PEAK:-0}  compacted: $([ "${COMPACTED:-0}" = 1 ] && echo yes || echo no)  fix round: $([ "${FIX_ROUND:-0}" = 1 ] && echo yes || echo no)  duration: ${dur}s"
    [ -n "${NOTES:-}" ] && { echo; echo "## Notes"; printf '%b' "$NOTES"; }
    [ -s "${GATES_FILE:-/nonexistent}" ] && { echo; echo "## Gates"; cat "$GATES_FILE"; }
    [ -n "${DIFFSTAT:-}" ] && { echo; echo "## Diffstat"; echo "$DIFFSTAT"; }
    [ -s "${FAIL_FILE:-/nonexistent}" ] && { echo; echo "## Failure output (last $FAIL_TAIL_LINES lines per command)"; cat "$FAIL_FILE"; }
    [ -n "$fu" ] && { echo; echo "## Follow-ups for Opus (added to $STATE/$FEATURE/followups.md)"; echo "$fu"; }
    [ -s "${REPORT:-/nonexistent}" ] && { echo; echo "## Worker self-report"; head -n 200 "$REPORT"; echo; }
    [ -s "${BB_OUT:-/nonexistent}" ] && { echo; echo "## Black-box tests ($BB_STATUS)"; tail -n "$FAIL_TAIL_LINES" "$BB_OUT"; echo; }
    if [ -s "${REVIEW:-/nonexistent}" ]; then
      echo; echo "## Second-pass review$([ "${FIX_ROUND:-0}" = 1 ] && echo " (gaps went back to the worker for one fix round)")"
      head -n 60 "$REVIEW"; echo
    fi
    echo; echo "logs: ${RUN_PREFIX:-}*"
  }
  release_slot
  exit "$code"
}

note() { NOTES="${NOTES:-}- $1\n"; }

add_usage() {
  T_INPUT=$(( ${T_INPUT:-0} + SS_INPUT )); T_OUTPUT=$(( ${T_OUTPUT:-0} + SS_OUTPUT ))
  T_REASONING=$(( ${T_REASONING:-0} + SS_REASONING ))
  T_CACHE_READ=$(( ${T_CACHE_READ:-0} + SS_CACHE_READ )); T_CACHE_WRITE=$(( ${T_CACHE_WRITE:-0} + SS_CACHE_WRITE ))
  T_COST="$(node -p "(${T_COST:-0}+$SS_COST).toFixed(6)")"
  [ "$SS_PEAK" -gt "${PEAK:-0}" ] && PEAK=$SS_PEAK
  [ "$SS_COMPACTED" = 1 ] && COMPACTED=1
  return 0
}

oc_start() {
  # oc_start <dir> <tag> <agent> <model> <effort> <message> <attachment>...: one OpenCode run in <dir>.
  # Writes $RUN_PREFIX-<tag>.jsonl; returns OpenCode's exit code.
  local dir="$1" tag="$2" agent="$3" model="$4" effort="$5" msg="$6" role=agent fargs=() f; shift 6
  case "$tag" in review*) role=reviewer ;; tests) role=tester ;; esac
  for f in "$@"; do fargs+=(-f "$f"); done
  # shellcheck disable=SC2086
  ( cd "$dir" && run_timeout "$WORKER_TIMEOUT" "$OPENCODE_BIN" run "$msg" $OPENCODE_RUN_FLAGS --agent "$agent" \
      --model "$model#$effort" --format json \
      --title "$(model_label "$model") $role: $FEATURE/$ID ${TITLE:-} ($tag, attempt $ATTEMPT, $effort)" "${fargs[@]}" </dev/null ) \
    > "$RUN_PREFIX-$tag.jsonl" 2> "$RUN_PREFIX-$tag.jsonl.stderr"
}

oc_collect() {
  # oc_collect <dir> <tag> <model> <effort> <rc>: read a finished run's events and token usage.
  # Sets OC_TEXT, OC_ERR and OC_LIMIT (1 when the error is a usage or rate limit); returns 0 on success.
  local dir="$1" tag="$2" model="$3" effort="$4" rc="$5" ev="$RUN_PREFIX-$2.jsonl" vars
  OC_TEXT="$ev.text"; OC_ERR=""; OC_LIMIT=0; EV_SESSION=""
  vars="$(lib events "$(native "$ev")" "$(native "$ev.text")" "$(native "$ev.err")")" || { OC_ERR="could not read OpenCode events ($ev)"; return 1; }
  eval "$vars"
  if [ -n "$EV_SESSION" ]; then
    # shellcheck disable=SC2086
    ( cd "$dir" && "$OPENCODE_BIN" session export "$EV_SESSION" $OPENCODE_RUN_FLAGS </dev/null ) > "$ev.session.json" 2> /dev/null
    vars="$(lib session "$(native "$ev.session.json")")" && eval "$vars"
    if [ "${SS_OK:-0}" = 1 ]; then
      add_usage
      [ "$tag" = worker ] && VARIANT_SEEN="$SS_VARIANT"
      case "$tag" in review*) REVIEWER_SEEN="$SS_MODEL#$SS_VARIANT" ;; esac
      [ -n "$SS_VARIANT" ] && [ "$SS_VARIANT" != "$effort" ] && note "$tag ran at variant '$SS_VARIANT', not '$effort'"
      [ -n "$SS_MODEL" ] && [ "$SS_MODEL" != "$model" ] && note "$tag ran on '$SS_MODEL', not '$model'"
      [ -n "$SS_OUTCOME" ] && [ "$SS_OUTCOME" != succeeded ] && OC_ERR="session outcome: $SS_OUTCOME"
    else
      note "$tag: could not read token usage from \`opencode session export\`"
    fi
  fi
  [ -s "$ev.err" ] && OC_ERR="$(cat "$ev.err")"
  timed_out "$rc" && OC_ERR="no result after ${WORKER_TIMEOUT}s (stopped)"
  [ "$rc" -ne 0 ] && [ -z "$OC_ERR" ] && OC_ERR="OpenCode exited $rc: $(tail -3 "$ev.stderr" 2>/dev/null | tr '\n' ' ')"
  [ -z "$EV_SESSION" ] && [ -z "$OC_ERR" ] && OC_ERR="OpenCode produced no session: $(tail -3 "$ev.stderr" 2>/dev/null | tr '\n' ' ')"
  grep -qiE "$LIMIT_PATTERN" <<<"$OC_ERR" && OC_LIMIT=1
  [ -z "$OC_ERR" ]
}

oc_session() {
  # oc_session <tag> <agent> <model> <effort> <message> <attachment>...: run in the brief's worktree and collect.
  local tag="$1" agent="$2" model="$3" effort="$4" rc
  oc_start "$WT" "$@"; rc=$?
  oc_collect "$WT" "$tag" "$model" "$effort" "$rc"
}

report_status() { grep -oiE 'STATUS[^A-Za-z]{0,6}(DONE|STOPPED)' "$1" 2>/dev/null | head -1 | grep -oiE 'DONE|STOPPED' | tr '[:lower:]' '[:upper:]'; }

run_worker() {
  # run_worker <tag> <message>: one implementer round. Sets ROUND_STATUS and ROUND_REPORT.
  local tag="$1" msg="$2" ok d
  rm -f "$WT/$REPORT_NAME"
  oc_session "$tag" shikigami-worker "$WORKER_MODEL" "$EFFORT" "$msg" "$INPUT_DIR/plan.md" "$INPUT_DIR/brief.md"; ok=$?
  ROUND_REPORT="$RUN_PREFIX-$tag-report.md"
  if [ -f "$WT/$REPORT_NAME" ]; then mv "$WT/$REPORT_NAME" "$ROUND_REPORT"
  elif [ -s "$OC_TEXT" ]; then cp "$OC_TEXT" "$ROUND_REPORT"
  else : > "$ROUND_REPORT"; fi
  { [ "$tag" != worker ] && printf '\n--- %s ---\n' "$tag"; cat "$ROUND_REPORT"; } >> "$REPORT"
  if [ $ok -ne 0 ]; then
    if [ "$OC_LIMIT" = 1 ]; then
      pause_model "$WORKER_MODEL" "$OC_ERR"
      finish ERROR "usage limit for $WORKER_MODEL: $OC_ERR. Runs for this model are paused; run \`worker.sh resume\` once the limit resets"
    fi
    finish ERROR "the $tag run did not complete: $OC_ERR"
  fi
  ROUND_STATUS="$(report_status "$ROUND_REPORT")"
  [ -n "$ROUND_STATUS" ] || note "$tag report has no STATUS line"
  d="$(lib discoveries "$(native "$ROUND_REPORT")")"
  [ "${d:-0}" -gt "${DISCOVERIES:-0}" ] && DISCOVERIES=$d
  return 0
}

run_gates() {
  # run_gates [boundary-only]: writes GATES_FILE and FAIL_FILE; returns 0 when every gate passes.
  local changed="$RUN_PREFIX-changed.txt" ok=0 n=0 cmd out rc vars why
  : > "$GATES_FILE"; : > "$FAIL_FILE"
  git -C "$WT" -c core.quotePath=false add -A >/dev/null 2>&1
  git -C "$WT" -c core.quotePath=false diff --cached --no-renames --name-only "$BASE" > "$changed"
  DIFFSTAT="$(git -C "$WT" diff --cached --stat "$BASE" | tail -n 25)"
  if [ ! -s "$changed" ]; then
    echo "changes: FAIL (no changes compared with the base commit)" >> "$GATES_FILE"
    return 1
  fi
  vars="$(lib scope "$(native "$BRIEF")" "$(native "$changed")" "$(native "$REPORT")" "$(native "$PLAN_DIR/briefs")" \
    "$EXTRA_EDIT_MAX_FILES" "$(native "$EXTRA_FILE")")"; rc=$?
  [ $rc -le 1 ] && [ -n "$vars" ] || finish ERROR "could not check the file boundary for $BRIEF"
  eval "$vars"
  if [ $rc -eq 0 ]; then
    echo "file boundary: PASS${SC_EXTRA:+ ($SC_EXTRA declared extra edits)}" | sed 's/ (0 declared extra edits)//' >> "$GATES_FILE"
  else
    why=""
    [ -n "$SC_UNDECLARED" ] && why="$why outside allowed_files and not declared under Extra edits: $SC_UNDECLARED;"
    [ -n "$SC_OWNED" ] && why="$why extra edits in another brief's files: $SC_OWNED;"
    [ "$SC_TOOMANY" = 1 ] && why="$why $SC_EXTRA extra-edit files, more than the limit of $EXTRA_EDIT_MAX_FILES;"
    why="${why# }"; echo "file boundary: FAIL (${why%;})" >> "$GATES_FILE"; ok=1
  fi
  [ "${1:-}" = boundary-only ] && return $ok
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    n=$((n + 1)); out="$RUN_PREFIX-gate$n.log"
    ( cd "$WT" && SHIKIGAMI_SLOT="$SLOT_NO" SHIKIGAMI_WORKTREE="$WT" run_timeout "$ACCEPT_TIMEOUT" bash -c "$cmd" </dev/null ) > "$out" 2>&1
    rc=$?
    if [ $rc -eq 0 ]; then
      echo "\`$cmd\`: PASS" >> "$GATES_FILE"
    else
      echo "\`$cmd\`: FAIL (exit $rc)" >> "$GATES_FILE"; ok=1
      { echo "### \`$cmd\` (exit $rc)"; tail -n "$FAIL_TAIL_LINES" "$out"; } >> "$FAIL_FILE"
    fi
  done < <(lib lines "$(native "$BRIEF")" acceptance)
  return $ok
}

commit_wt() {
  # commit_wt <message>: commit the staged worktree changes; a failure is an ERROR (git config or hook).
  git -C "$WT" commit -q -m "$1" > "$RUN_PREFIX-commit.log" 2>&1 \
    || { cp "$RUN_PREFIX-commit.log" "$FAIL_FILE"; finish ERROR "git commit failed in the worktree (hook or git config)"; }
}

# ---------- black-box tester (TEST_WRITER=on) ----------
# Writes tests from the brief and the contract alone, in a worktree at the base commit, so it never sees the
# worker's code. It runs alongside the worker; its tests then run against the worker's code.

start_tester() {
  BB_STATUS=off; TESTER_PID=""
  [ "$TEST_WRITER" = on ] || return 0
  if [ -n "$(paused_since "$TESTER_MODEL")" ]; then BB_STATUS="skipped (model paused)"; return 0; fi
  TWT="$ROOT/$STATE/worktrees/$FEATURE-$ID-tests"
  with_git_lock remove_worktree "$TWT" ""
  with_git_lock add_detached_worktree "$TWT" "$BASE" || { BB_STATUS="skipped (no worktree)"; return 0; }
  mkdir -p "$TWT/$INPUT_DIR"; cp "$PLAN" "$TWT/$INPUT_DIR/plan.md"; cp "$BRIEF" "$TWT/$INPUT_DIR/brief.md"
  oc_start "$TWT" tests shikigami-tester "$TESTER_MODEL" "$TESTER_EFFORT" \
    "Write black-box tests for brief $ID of feature $FEATURE from the attached brief and the contract in the code. Follow your instructions: tests go in $BLACKBOX_DIR/, with the command that runs them in $BLACKBOX_DIR/RUN." \
    "$INPUT_DIR/plan.md" "$INPUT_DIR/brief.md" &
  TESTER_PID=$!
  BB_STATUS=running
}

stop_tester() {
  [ -n "${TESTER_PID:-}" ] && kill "$TESTER_PID" 2>/dev/null
  [ -n "${TWT:-}" ] && [ -d "$TWT" ] && with_git_lock remove_worktree "$TWT" ""
  TESTER_PID=""; TWT=""
}

run_blackbox() {
  # run_blackbox: collect the tester's tests, run them against the worker's code. Returns 0 when they pass.
  local rc runcmd
  BB_OUT="$RUN_PREFIX-blackbox.log"
  case "$BB_STATUS" in off|skipped*|missing) return 0 ;; esac
  if [ "$BB_STATUS" = running ]; then
    wait "$TESTER_PID"; rc=$?; TESTER_PID=""
    if ! oc_collect "$TWT" tests "$TESTER_MODEL" "$TESTER_EFFORT" "$rc"; then
      [ "$OC_LIMIT" = 1 ] && pause_model "$TESTER_MODEL" "$OC_ERR"
      BB_STATUS="missing"; note "black-box tester did not finish: $OC_ERR"; return 0
    fi
    if [ ! -s "$TWT/$BLACKBOX_DIR/RUN" ]; then
      BB_STATUS="missing"; note "black-box tester wrote no $BLACKBOX_DIR/RUN file"; return 0
    fi
    # Keep the tester's files outside every worktree, so a worker in the fix round cannot change the tests or RUN.
    BB_SAVED="$RUN_PREFIX-blackbox"; rm -rf "$BB_SAVED"; cp -r "$TWT/$BLACKBOX_DIR" "$BB_SAVED"
    with_git_lock remove_worktree "$TWT" ""; TWT=""
    # RUN is model-written and runs outside OpenCode's permissions: allow one plain command line (no pipes,
    # chaining, substitution or redirection) that starts with the same program as one of the brief's acceptance commands.
    runcmd="$(head -1 "$BB_SAVED/RUN" | tr -d '\r')"
    if ! [[ "$runcmd" =~ ^[A-Za-z0-9\ ._/=:@+*-]+$ ]] \
      || ! lib lines "$(native "$BRIEF")" acceptance | awk '{print $1}' | grep -qxF -- "${runcmd%% *}"; then
      BB_STATUS="missing"; note "black-box RUN command rejected (plain command using an acceptance runner required): $runcmd"; return 0
    fi
    note "black-box tests run with: $runcmd"
  fi
  runcmd="$(head -1 "$BB_SAVED/RUN" | tr -d '\r')"
  rm -rf "$WT/$BLACKBOX_DIR"; cp -r "$BB_SAVED" "$WT/$BLACKBOX_DIR"
  ( cd "$WT" && run_timeout "$ACCEPT_TIMEOUT" bash -c "$runcmd" </dev/null ) > "$BB_OUT" 2>&1; rc=$?
  if [ $rc -eq 0 ]; then BB_STATUS=pass; return 0; fi
  BB_STATUS="fail (exit $rc)"; return 1
}

cmd_run() {
  START=$(date +%s); FEATURE="${1:-}"; ID="${2:-}"; EFFORT="$WORKER_EFFORT"
  safe_name "$FEATURE" feature; safe_name "$ID" brief; shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --effort) need "${2:-}" effort; EFFORT="$2"; shift 2 ;;
      *) echo "RESULT: ERROR"; echo "reason: unknown option $1"; exit 3 ;;
    esac
  done
  ROOT="$(repo_root)" || { echo "RESULT: ERROR"; echo "reason: run from the main checkout of a git repository"; exit 3; }
  find_opencode || { echo "RESULT: ERROR"; echo "reason: OpenCode CLI not found"; exit 3; }
  local since; since="$(paused_since "$WORKER_MODEL")"
  if [ -n "$since" ]; then
    echo "RESULT: ERROR"
    echo "reason: paused: $WORKER_MODEL hit its usage limit at $since. Run \`worker.sh resume\` once the limit resets, then dispatch again."
    exit 3
  fi
  PLAN_DIR="$ROOT/$STATE/$FEATURE"; PLAN="$PLAN_DIR/plan.md"; BRIEF="$PLAN_DIR/briefs/$ID.md"; LOG="$PLAN_DIR/runs.log"
  mkdir -p "$PLAN_DIR/runs"; touch "$LOG"
  ensure_excludes
  ATTEMPT=$(( $(lib attempts "$(native "$LOG")" "$FEATURE" "$ID") + 1 ))
  RUN_PREFIX="$PLAN_DIR/runs/$ID-a$ATTEMPT"
  REPORT="$RUN_PREFIX-report.md"; REVIEW="$RUN_PREFIX-review.md"
  GATES_FILE="$RUN_PREFIX-gates.txt"; FAIL_FILE="$RUN_PREFIX-failures.txt"; EXTRA_FILE="$RUN_PREFIX-extra.txt"
  : > "$REPORT"
  [ -f "$PLAN" ] || finish ERROR "missing $PLAN"
  [ -f "$BRIEF" ] || finish ERROR "missing $BRIEF"
  local vars
  vars="$(lib brief "$(native "$BRIEF")" 2>&1)" || finish ERROR "brief does not follow the brief format: ${vars#lib.mjs: }"
  eval "$vars"; TITLE="$BRIEF_TITLE"
  write_oc_config
  [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ] && note "the main checkout has uncommitted changes; workers start from the last commit and do not see them"
  sync_agents

  acquire_slot
  trap 'stop_tester; release_slot' EXIT
  WT="$ROOT/$STATE/worktrees/$FEATURE-$ID"; BR="shikigami/$FEATURE/$ID"
  BASE="$(git -C "$ROOT" rev-parse HEAD)"
  with_git_lock remove_worktree "$WT" "$BR"
  with_git_lock add_worktree "$WT" "$BR" "$BASE" || finish ERROR "could not create worktree $WT"
  mkdir -p "$WT/$INPUT_DIR"
  cp "$PLAN" "$WT/$INPUT_DIR/plan.md"; cp "$BRIEF" "$WT/$INPUT_DIR/brief.md"
  lib owned "$(native "$PLAN_DIR/briefs")" "$(native "$BRIEF")" > "$WT/$INPUT_DIR/owned-elsewhere.txt"
  if [ -f "$ROOT/$STATE/setup.sh" ]; then
    ( cd "$WT" && MAIN_REPO="$ROOT" bash "$ROOT/$STATE/setup.sh" </dev/null ) > "$RUN_PREFIX-setup.log" 2>&1 \
      || { tail -n "$FAIL_TAIL_LINES" "$RUN_PREFIX-setup.log" > "$FAIL_FILE"; finish ERROR "$STATE/setup.sh failed"; }
  fi
  start_tester

  run_worker worker "Implement brief $ID of feature $FEATURE. The plan and your brief are attached; copies are in $INPUT_DIR/. Your working directory is a git worktree of the repo. Extra-edit limit: $EXTRA_EDIT_MAX_FILES files outside allowed_files. Files owned by other briefs are listed in $INPUT_DIR/owned-elsewhere.txt. Follow your protocol, write your self-report to $REPORT_NAME at the worktree root, then end."
  if [ "$ROUND_STATUS" = STOPPED ]; then
    run_gates boundary-only || true
    finish STOPPED "the worker stopped: the brief or plan does not match the code"
  fi
  run_gates || finish FAIL "gates failed"
  commit_wt "$FEATURE/$ID: ${TITLE:-brief $ID}"

  local fixes="$RUN_PREFIX-fixes.md" bb_ok=0
  : > "$fixes"
  run_blackbox || bb_ok=1
  if [ $bb_ok -ne 0 ]; then
    { echo "- (black-box tests written from the contract alone fail; fix the code, or if a test contradicts the contract, say which and why under Discoveries)"; tail -n "$FAIL_TAIL_LINES" "$BB_OUT" | sed 's/^/    /'; } >> "$fixes"
  fi

  # Second pass: a fresh reviewer looks only for what the change misses, and checks every extra edit.
  git -C "$WT" diff "$BASE" HEAD > "$WT/$INPUT_DIR/change.diff"
  cp "$REPORT" "$WT/$INPUT_DIR/report.md"
  REVIEW_STATUS=ok; FD_INSIDE=0; FD_OUTSIDE=0; FD_SCOPE=0; FD_UNVERIFIED=""; FD_PARSED=0
  local rmodel="$REVIEWER_MODEL" rmsg="Review the attached diff for brief $ID. Answer one question: what does this change miss, given the goal? Also verify every entry under Extra edits in the attached worker report. Use the output format from your instructions."
  [ -n "$(paused_since "$rmodel")" ] && rmodel="${REVIEWER_FALLBACK_MODEL:-}"
  local reviewed=1
  if [ -n "$rmodel" ] && [ -z "$(paused_since "$rmodel")" ]; then
    oc_session review shikigami-reviewer "$rmodel" "$REVIEWER_EFFORT" "$rmsg" \
      "$INPUT_DIR/brief.md" "$INPUT_DIR/change.diff" "$INPUT_DIR/report.md" && reviewed=0
    if [ $reviewed -ne 0 ]; then
      [ "$OC_LIMIT" = 1 ] && pause_model "$rmodel" "$OC_ERR"
      local fb="${REVIEWER_FALLBACK_MODEL:-}"
      if [ -n "$fb" ] && [ "$fb" != "$rmodel" ] && [ -z "$(paused_since "$fb")" ]; then
        note "reviewer $rmodel failed ($OC_ERR); retried with $fb"
        oc_session review-fallback shikigami-reviewer "$fb" "$REVIEWER_EFFORT" "$rmsg" \
          "$INPUT_DIR/brief.md" "$INPUT_DIR/change.diff" "$INPUT_DIR/report.md" && reviewed=0
        [ $reviewed -ne 0 ] && [ "$OC_LIMIT" = 1 ] && pause_model "$fb" "$OC_ERR"
      fi
    fi
  else
    OC_ERR="every reviewer model is paused after a usage limit"
  fi
  if [ $reviewed -eq 0 ]; then
    cp "$OC_TEXT" "$REVIEW"
    vars="$(lib findings "$(native "$REVIEW")" "$(native "$RUN_PREFIX-review-fixes.md")" "$(native "$EXTRA_FILE")")" && eval "$vars"
    cat "$RUN_PREFIX-review-fixes.md" >> "$fixes" 2>/dev/null
    [ "$FD_PARSED" = 1 ] || { REVIEW_STATUS=unparsed; note "second-pass review output had no FINDING, SCOPE OK or NO FINDINGS lines; review the diff more closely"; }
    [ -n "$FD_UNVERIFIED" ] && note "the reviewer gave no verdict on these extra edits; check them yourself: $FD_UNVERIFIED"
    local review_export; review_export="$(ls -t "$RUN_PREFIX"-review*.jsonl.session.json 2>/dev/null | head -1)"
    RW_FETCHED=""; RW_BLOCKED=""; RW_DOCS=""; RW_CITED=""; RW_UNCITED=0
    [ -n "$review_export" ] && vars="$(lib reviewweb "$(native "$review_export")" "$(native "$REVIEW")")" && eval "$vars"
    [ -n "$RW_DOCS" ] && note "the reviewer read Context7 docs for: $RW_DOCS"
    [ -n "$RW_FETCHED" ] && note "the reviewer read these pages: $RW_FETCHED"
    [ -n "$RW_BLOCKED" ] && note "the reviewer tried these blocked pages: $RW_BLOCKED"
    [ "$RW_UNCITED" = 1 ] && note "the reviewer used outside sources but cited none; treat its source-based verdicts as unverified"
  else
    REVIEW_STATUS=missing; note "second-pass review did not run: $OC_ERR; do the deeper Opus review (read the code and run one adversarial check)"
  fi
  FD_INSIDE_TOTAL=$FD_INSIDE; FD_OUTSIDE_TOTAL=$FD_OUTSIDE
  [ "$FD_SCOPE" -gt 0 ] && note "the reviewer judged $FD_SCOPE extra edit(s) not justified; they went back to the worker"

  if [ -s "$fixes" ]; then
    FIX_ROUND=1
    run_worker fix "Checks after your first pass found these problems for brief $ID of feature $FEATURE:
$(cat "$fixes")
Fix gaps within the discovery rule. For an extra edit marked not justified, either revert it or keep it with better proof under Extra edits. Then write an updated self-report to $REPORT_NAME (STATUS line first, and say for each finding what you did), then end."
    if [ "$ROUND_STATUS" = STOPPED ]; then
      git -C "$WT" reset -q --hard HEAD; git -C "$WT" clean -qfd
      finish STOPPED "the worker stopped during the fix round; the first pass is committed on the branch"
    fi
    if run_gates; then
      [ $bb_ok -ne 0 ] && { run_blackbox || note "black-box tests still fail after the fix round; check whether the tests or the code are wrong"; }
      git -C "$WT" diff --cached --quiet || commit_wt "$FEATURE/$ID: review fixes"
      finish PASS "gates passed; fix round applied"
    fi
    git -C "$WT" reset -q --hard HEAD; git -C "$WT" clean -qfd
    note "the fix round broke the gates, so it was discarded; the first pass is kept and its findings are still open"
    finish PASS "first pass passed its gates; the fix round failed and was discarded"
  fi
  finish PASS "gates passed"
}

# ---------- cleanup / plan-miss ----------

cmd_cleanup() {
  local feature="${1:-}" id="${2:-}"
  safe_name "$feature" feature; safe_name "$id" brief
  ROOT="$(repo_root)" || exit 3
  with_git_lock remove_worktree "$ROOT/$STATE/worktrees/$feature-$id" "shikigami/$feature/$id"
  with_git_lock remove_worktree "$ROOT/$STATE/worktrees/$feature-$id-tests" ""
  echo "removed worktree $STATE/worktrees/$feature-$id and branch shikigami/$feature/$id"
}

cmd_plan_miss() {
  local feature="${1:-}" id="${2:-}" text="${3:-}"
  safe_name "$feature" feature; safe_name "$id" brief; need "$text" note
  ROOT="$(repo_root)" || exit 3
  mkdir -p "$ROOT/$STATE/$feature"
  lib log "$(native "$ROOT/$STATE/$feature/runs.log")" event=plan_miss feature="$feature" brief="$id" note="$text"
  echo "recorded plan miss for $feature/$id"
}

case "${1:-}" in
  doctor) shift; cmd_doctor "$@" ;;
  run) shift; cmd_run "$@" ;;
  cleanup) shift; cmd_cleanup "$@" ;;
  plan-miss) shift; cmd_plan_miss "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  config) shift; cmd_config "$@" ;;
  *) usage; exit 3 ;;
esac
