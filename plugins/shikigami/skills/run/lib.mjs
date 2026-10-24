// Helpers for worker.sh. Every path argument is a native path (worker.sh converts them).
//   node lib.mjs brief <brief.md>                          check the brief, print id and title as shell vars
//   node lib.mjs lines <brief.md> <allowed|acceptance>     print one header list item per line
//   node lib.mjs owned <briefs-dir> <brief.md>             globs owned by the other briefs, as "glob<TAB>brief id"
//   node lib.mjs scope <brief.md> <changed.txt> <report.md> <briefs-dir> <off-limits globs> <extra-out>
//                                                          file-boundary gate with declared extra edits; exit 1 if it fails
//   node lib.mjs events <events.jsonl> <text-out> <err-out>   session id, last text, error from `opencode run --format json`
//   node lib.mjs session <export.json>                     token, context and outcome figures from `opencode session export`
//   node lib.mjs findings <review.md> <fix-out> <extra.txt>   reviewer findings; inside and scope findings written to fix-out
//   node lib.mjs followups <report.md> <review.md>         follow-up bullets from the self-report and [outside] review findings
//   node lib.mjs reviewweb <export.json> <review.md>       pages the reviewer fetched or was refused, and the sources it cited
//   node lib.mjs discoveries <report.md>                   number of discoveries in a self-report
//   node lib.mjs attempts <runs.log> <feature> <brief>     how many runs this brief has had
//   node lib.mjs log <runs.log> key=value ...              append one JSON line to the run log
import fs from "node:fs";

const [, , cmd, ...args] = process.argv;
const read = (f) => (fs.existsSync(f) ? fs.readFileSync(f, "utf8").replace(/^﻿/, "").replace(/\r\n/g, "\n") : "");
const sh = (s) => "'" + String(s).replace(/'/g, "'\\''") + "'";

const REQUIRED_SECTIONS = [
  "Goal", "Context", "Steps", "Acceptance checklist", "Test cases", "Hard cases",
  "Interfaces to keep", "Out of scope", "Discovery rule",
];

function parseBrief(file) {
  const src = read(file);
  const m = src.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!m) throw new Error(`${file}: missing front-matter header`);
  const out = { id: "", title: "", allowed: [], acceptance: [], body: m[2] };
  let list = null;
  for (const raw of m[1].split("\n")) {
    if (!raw.trim() || raw.trim().startsWith("#")) continue;
    const item = raw.match(/^\s*-\s+(.*)$/);
    if (item && list) {
      out[list].push(unquote(item[1]));
      continue;
    }
    const kv = raw.match(/^([A-Za-z_]+):\s*(.*)$/);
    if (!kv) throw new Error(`${file}: cannot read header line: ${raw}`);
    const [, key, val] = kv;
    if (key === "allowed_files" || key === "acceptance") {
      list = key === "allowed_files" ? "allowed" : "acceptance";
      if (val.trim()) throw new Error(`${file}: ${key} must be a list of "- item" lines`);
    } else {
      list = null;
      out[key] = unquote(val);
    }
  }
  if (!out.allowed.length) throw new Error(`${file}: allowed_files is empty`);
  if (!out.acceptance.length) throw new Error(`${file}: acceptance is empty`);
  return out;
}

function checkBriefBody(file, body) {
  const headings = [...body.matchAll(/^#{1,6}\s+(.+?)\s*$/gm)].map((h) => h[1].toLowerCase());
  const missing = REQUIRED_SECTIONS.filter((s) => !headings.includes(s.toLowerCase()));
  if (missing.length) throw new Error(`${file}: missing sections: ${missing.join(", ")}`);
  const sec = section(body, "Acceptance checklist");
  const items = sec.split("\n").filter((l) => /^\s*[-*]\s+\S/.test(l));
  if (!items.length) throw new Error(`${file}: the acceptance checklist has no items`);
  const untagged = items.filter((l) => !/^\s*[-*]\s+\[(auto|review)\]/i.test(l));
  if (untagged.length) throw new Error(`${file}: checklist items without [auto] or [review]: ${untagged.map((l) => l.trim()).join(" | ")}`);
}

// Every section with this heading, joined (a report can hold one per round).
function section(md, name) {
  const head = new RegExp(`^#{1,6}\\s*\\**${name}\\**\\s*:?\\s*$`, "i");
  const out = [];
  let inside = false;
  for (const l of md.split("\n")) {
    if (/^#{1,6}\s/.test(l)) { inside = head.test(l); continue; }
    if (inside) out.push(l);
  }
  return out.join("\n");
}

function bullets(md, name) {
  return section(md, name).split("\n")
    .filter((l) => /^\s*[-*]\s+\S/.test(l) && !/^\s*[-*]\s+none\b/i.test(l))
    .map((l) => l.replace(/^\s*[-*]\s+/, "").trim());
}

// "`src/a.ts` | why: ..." or "src/a.ts: reason" -> "src/a.ts"
const firstPath = (b) => b.split(/\s*\|\s*|:\s/)[0].trim().replace(/^[`'"*]+|[`'"*:]+$/g, "").replace(/\\/g, "/").replace(/^\.\//, "");

function otherBriefs(dir, current) {
  const out = [];
  const cur = fs.realpathSync(current);
  for (const f of fs.existsSync(dir) ? fs.readdirSync(dir) : []) {
    const p = `${dir}/${f}`;
    if (!f.endsWith(".md") || fs.realpathSync(p) === cur) continue;
    try {
      const b = parseBrief(p);
      out.push({ id: b.id || f.replace(/\.md$/, ""), globs: b.allowed, res: b.allowed.map(globToRegex) });
    } catch { /* a broken brief owns nothing */ }
  }
  return out;
}

function scope(briefFile, changedFile, reportFile, briefsDir, offLimits, extraOut) {
  const own = parseBrief(briefFile).allowed.map(globToRegex);
  const others = otherBriefs(briefsDir, briefFile);
  const changed = read(changedFile).split("\n").filter(Boolean).map((f) => f.replace(/\\/g, "/"));
  const declared = new Set(bullets(read(reportFile), "Extra edits").map(firstPath));
  const outside = changed.filter((f) => !own.some((r) => r.test(f)));
  const undeclared = outside.filter((f) => !declared.has(f));
  const owned = outside.filter((f) => declared.has(f))
    .map((f) => ({ f, by: others.find((o) => o.res.some((r) => r.test(f)))?.id }))
    .filter((x) => x.by);
  const extra = outside.filter((f) => declared.has(f));
  // Off-limits files (dependencies, CI, build config, migrations) may change only when the brief lists them.
  const offRes = String(offLimits || "").split(/\s+/).filter(Boolean).map(globToRegex);
  const offHits = extra.filter((f) => offRes.some((r) => r.test(f)));
  fs.writeFileSync(extraOut, extra.join("\n"));
  console.log([
    `SC_EXTRA=${extra.length}`,
    `SC_UNDECLARED=${sh(undeclared.join(", "))}`,
    `SC_OWNED=${sh(owned.map((x) => `${x.f} (owned by brief ${x.by})`).join(", "))}`,
    `SC_PROTECTED=${sh(offHits.join(", "))}`,
  ].join("\n"));
  process.exit(undeclared.length || owned.length || offHits.length ? 1 : 0);
}

function unquote(s) {
  s = s.trim();
  const q = s[0];
  if ((q === '"' || q === "'") && s.length > 1 && s.at(-1) === q && !s.slice(1, -1).includes(q)) return s.slice(1, -1);
  return s;
}

// Glob to RegExp: ** crosses directories, * and ? stay inside one segment, dotfiles match.
function globToRegex(pattern) {
  const p = pattern.replace(/\\/g, "/").replace(/^\.\//, "");
  let re = "";
  for (let i = 0; i < p.length; i++) {
    const c = p[i];
    if (c === "*" && p[i + 1] === "*") {
      i++;
      if (p[i + 1] === "/") { i++; re += "(?:.*/)?"; } else re += ".*";
    } else if (c === "*") re += "[^/]*";
    else if (c === "?") re += "[^/]";
    else re += c.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`^${re}$`);
}

function events(file, textOut, errOut) {
  let session = "", error = "";
  const texts = [];
  for (const line of read(file).split("\n").filter(Boolean)) {
    let e;
    try { e = JSON.parse(line); } catch { continue; }
    if (!session && e.sessionID) session = e.sessionID;
    if (e.type === "error") error = e.error?.data?.message || e.error?.message || e.error?.name || "unknown error";
    if (e.type === "text" && e.part?.text) texts.push(e.part.text);
  }
  fs.writeFileSync(textOut, texts.at(-1) || "");
  fs.writeFileSync(errOut, error);
  console.log(`EV_SESSION=${sh(session)}`);
}

function sessionFigures(file) {
  const src = read(file);
  const i = src.indexOf("{");
  let j = null;
  try { j = i >= 0 ? JSON.parse(src.slice(i)) : null; } catch { j = null; }
  if (!j?.info) {
    console.log("SS_OK=0");
    return;
  }
  const t = j.info.tokens || {};
  let peak = 0, prev = 0, compacted = 0, steps = 0;
  for (const m of j.messages || []) {
    if (/compact/i.test(m.type || "") || (m.content || []).some((c) => /compact/i.test(c.type || ""))) compacted = 1;
    if (m.type !== "assistant" || !m.tokens) continue;
    steps++;
    const k = m.tokens, cr = k.cache?.read || 0, cw = k.cache?.write || 0;
    const prompt = (k.input || 0) >= cr + cw ? k.input || 0 : (k.input || 0) + cr + cw;
    if (prev > 50000 && prompt < prev * 0.6) compacted = 1; // context shrank sharply: compaction
    peak = Math.max(peak, prompt);
    prev = prompt;
  }
  console.log([
    "SS_OK=1",
    `SS_INPUT=${t.input || 0}`, `SS_OUTPUT=${t.output || 0}`, `SS_REASONING=${t.reasoning || 0}`,
    `SS_CACHE_READ=${t.cache?.read || 0}`, `SS_CACHE_WRITE=${t.cache?.write || 0}`,
    `SS_COST=${(j.info.cost || 0).toFixed(6)}`, `SS_PEAK=${peak}`, `SS_COMPACTED=${compacted}`, `SS_STEPS=${steps}`,
    `SS_VARIANT=${sh(j.info.model?.variant || "")}`, `SS_OUTCOME=${sh(j.info.outcome || "")}`,
    `SS_MODEL=${sh(j.info.model?.providerID && j.info.model?.id ? `${j.info.model.providerID}/${j.info.model.id}` : "")}`,
  ].join("\n"));
}

const FINDING = /^\s*(?:[-*]|\d+[.)])?\s*\**\s*FINDING\s*\**\s*\[(inside|outside|scope)\]\s*\**\s*(.*)$/i;
const SCOPE_OK = /^\s*(?:[-*]|\d+[.)])?\s*\**\s*SCOPE OK\s*\**\s*:?\s*(.*)$/i;

function findings(file, fixOut, extraFile) {
  const src = read(file);
  const found = { inside: [], outside: [], scope: [] }, scopeOk = [];
  for (const line of src.split("\n")) {
    const m = line.match(FINDING);
    if (m) { found[m[1].toLowerCase()].push(m[2].trim()); continue; }
    const ok = line.match(SCOPE_OK);
    if (ok) scopeOk.push(ok[1].trim());
  }
  const extra = read(extraFile).split("\n").map((f) => f.trim()).filter(Boolean);
  // The extra-edit file a verdict is about: the longest declared path its text contains, so "pkg.json:12",
  // "**a.ts**" or a path with spaces still match. A verdict naming no declared file keeps its own first path.
  const fileOf = (text) => {
    const t = text.replace(/\\/g, "/");
    return extra.filter((f) => t.includes(f)).sort((a, b) => b.length - a.length)[0]
      || firstPath(text).replace(/:\d+(?::\d+)?$/, "");
  };
  const rejected = [...new Set(found.scope.map(fileOf).filter(Boolean))];
  const judged = new Set([...scopeOk.map(fileOf), ...rejected]);
  const unverified = extra.filter((f) => !judged.has(f));
  const none = /NO FINDINGS/i.test(src);
  fs.writeFileSync(fixOut, [
    ...found.inside.map((f) => `- ${f}`),
    ...found.scope.map((f) => `- (extra edit not justified) ${f}`),
  ].join("\n"));
  console.log([
    `FD_INSIDE=${found.inside.length}`, `FD_OUTSIDE=${found.outside.length}`, `FD_SCOPE=${found.scope.length}`,
    `FD_UNVERIFIED=${sh(unverified.join(", "))}`,
    `FD_SCOPE_FILES=${sh(rejected.join("\n"))}`,
    `FD_PARSED=${found.inside.length || found.outside.length || found.scope.length || scopeOk.length || none ? 1 : 0}`,
  ].join("\n"));
}

// Pages the reviewer fetched, and whether its verdicts cite them.
function reviewWeb(exportFile, reviewFile) {
  const src = read(exportFile);
  let j = null;
  try { j = JSON.parse(src.slice(src.indexOf("{"))); } catch { j = null; }
  const fetched = [], blocked = [], docs = [];
  for (const m of j?.messages || []) for (const c of m.content || []) {
    if (c.type !== "tool") continue;
    if (c.name !== "webfetch") continue;
    const url = c.state?.input?.url || "";
    const ok = c.state?.status === "completed";
    const lib = url.match(/^https:\/\/context7\.com\/api\/v2\/context\?(?:.*&)?libraryId=([^&]+)/);
    if (lib && ok) docs.push(decodeURIComponent(lib[1]));
    else if (!/^https:\/\/context7\.com\//.test(url) || !ok) (ok ? fetched : blocked).push(url);
  }
  const review = read(reviewFile);
  const cited = [...review.matchAll(/source:\s*<?((?:https?:\/\/|context7\s+)[^\s)>]+)/gi)].map((m) => m[1]);
  console.log([
    `RW_FETCHED=${sh([...new Set(fetched)].join(" "))}`,
    `RW_BLOCKED=${sh([...new Set(blocked)].join(" "))}`,
    `RW_DOCS=${sh([...new Set(docs)].join(" "))}`,
    `RW_CITED=${sh([...new Set(cited)].join(" "))}`,
    `RW_UNCITED=${(fetched.length || docs.length) && !cited.length ? 1 : 0}`,
  ].join("\n"));
}

function followups(reportFile, reviewFile) {
  const items = bullets(read(reportFile), "Follow-ups").map((b) => `- ${b}`);
  for (const line of read(reviewFile).split("\n")) {
    const m = line.match(FINDING);
    if (m && m[1].toLowerCase() === "outside") items.push(`- (second-pass review) ${m[2].trim()}`);
  }
  const seen = new Set();
  const unique = items.filter((i) => {
    const key = i.replace(/\s+/g, " ").toLowerCase();
    return seen.has(key) ? false : (seen.add(key), true);
  });
  if (unique.length) console.log(unique.join("\n"));
}

function discoveries(file) {
  console.log(bullets(read(file), "Discoveries").length);
}

function attempts(logFile, feature, brief) {
  let n = 0;
  for (const line of read(logFile).split("\n").filter(Boolean)) {
    try {
      const e = JSON.parse(line);
      if (e.event === "run" && e.feature === feature && String(e.brief) === String(brief)) n++;
    } catch { /* skip a bad line */ }
  }
  console.log(n);
}

function log(logFile, pairs) {
  const rec = { ts: new Date().toISOString() };
  for (const p of pairs) {
    const i = p.indexOf("=");
    const k = p.slice(0, i), v = p.slice(i + 1);
    rec[k] = /^-?\d+(\.\d+)?$/.test(v) && !["brief", "base"].includes(k) ? Number(v) : v;
  }
  fs.appendFileSync(logFile, JSON.stringify(rec) + "\n");
}

try {
  if (cmd === "brief") {
    const b = parseBrief(args[0]);
    checkBriefBody(args[0], b.body);
    console.log(`BRIEF_ID=${sh(b.id)}\nBRIEF_TITLE=${sh(b.title)}`);
  } else if (cmd === "lines") {
    const b = parseBrief(args[0]);
    for (const l of args[1] === "allowed" ? b.allowed : b.acceptance) console.log(l);
  } else if (cmd === "owned") {
    for (const o of otherBriefs(args[0], args[1])) for (const g of o.globs) console.log(`${g}\tbrief ${o.id}`);
  } else if (cmd === "scope") scope(args[0], args[1], args[2], args[3], args[4], args[5]);
  else if (cmd === "events") events(args[0], args[1], args[2]);
  else if (cmd === "session") sessionFigures(args[0]);
  else if (cmd === "findings") findings(args[0], args[1], args[2]);
  else if (cmd === "followups") followups(args[0], args[1]);
  else if (cmd === "reviewweb") reviewWeb(args[0], args[1]);
  else if (cmd === "discoveries") discoveries(args[0]);
  else if (cmd === "attempts") attempts(args[0], args[1], args[2]);
  else if (cmd === "log") log(args[0], args.slice(1));
  else throw new Error(`unknown command: ${cmd}`);
} catch (err) {
  console.error(`lib.mjs: ${err.message}`);
  process.exit(2);
}
