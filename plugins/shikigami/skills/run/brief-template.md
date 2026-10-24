---
id: 1
title: Short name of the subtask
allowed_files:
  - path/to/file.ts
  - path/to/file.test.ts
acceptance:
  - npm test -- path/to/file.test.ts
  - npx tsc --noEmit
---

## Goal

One or two sentences: what this subtask achieves and why.

## Context

The findings and decisions from the plan that this brief depends on, including what experiments showed. Point to the contract stubs instead of restating them.

## Steps

A suggested order of work. This is a starting point, not a complete list: do what the goal needs, within the discovery rule.

1. Add X to Y.
2. Wire Z into W.

## Acceptance checklist

The minimum that must be true, not the maximum.

- [auto] Behaviour covered by an acceptance command or a test case below.
- [review] Something checked by reading the diff.

## Test cases

Inputs and expected results to turn into tests.

- Given A, expect B.
- Given an empty input, expect C.

## Hard cases

Tests that break weak implementations. Write "none" only with the reason.

- Concurrency: the same operation 20 times at once; every call succeeds and the end state is consistent.
- Injected failure: the write fails halfway; nothing partial is left behind.
- Platform: behaviour that differs between Windows, macOS and Linux.
- Large input: the biggest size the code is meant to handle.

## Interfaces to keep

Signatures, types, formats and behaviour that must not change. Anything that must not be touched at all goes here, because a worker may make small, proven extra edits outside `allowed_files`.

## Out of scope

Work that is not part of this brief's goal.

## Discovery rule

Fix it inside `allowed_files` when you can. A small, proven fix outside them is an extra edit: allowed only in files no other brief owns, within the extra-edit limit, keeping the interfaces above, and declared under Extra edits with proof. Report anything else that is wrong as a follow-up. Stop only when the problem blocks this brief and no allowed fix exists.
