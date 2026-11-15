---
name: wavewrangler-feature-review
description: >-
  Use when a WaveWrangler feature is complete and the user requests an
  "end-of-feature review", "feature-review", final quality gate, or PR review
  against the project's Swift ownership, persistence/media, performance,
  documentation and test patterns. Also use for a completed change's final
  maintainability or handoff check without those exact phrases. Does NOT
  implement features, run a full-codebase audit, replace a focused generic bug
  or security review, author skills, finish/merge PRs, or grant Git, media,
  model, experiment or host permissions.
---

# WaveWrangler feature review

Review the completed change, not the whole repository. Default to read-only
findings; apply fixes or run permission-sensitive work only when the current
request authorizes it.

## Gotchas to load when relevant

For executor, cache, inverse or native-save changes, use the guide's
[currency and failure checks](../../../docs/engineering/feature-review.md#check-executors-currency-and-failure).
For optimization, use its
[retained-resource checks](../../../docs/engineering/feature-review.md#check-bounded-performance-without-changing-the-contract);
for test/readiness claims, use its
[validation checks](../../../docs/engineering/feature-review.md#select-and-interpret-validation).
Those sections carry the concrete contracts; do not substitute generic advice.

## Procedure

1. Read [AGENTS](../../../AGENTS.md) and the canonical
   [feature-review procedure](../../../docs/engineering/feature-review.md).
   Establish the real diff/base, dirty ownership, intended contract and directly
   dependent callers. With supplied excerpts only, state that limit and use only
   supplied evidence.
2. Use the procedure to trace ownership, executor settings, admission/currency,
   failure/native lifecycle, bounded work and validation. Load focused contracts
   from the [engineering index](../../../docs/engineering/README.md) only for
   affected concerns. Do not mechanically propose actors, protocols or caching.
3. Inspect negative paths and tests that could falsify each finding. Distinguish
   a static mechanism from reachable behavior, a dynamic reproduction and a
   measured improvement. Identify compatibility decisions and unsupported
   capabilities rather than inventing safe defaults.
4. Select the smallest authorized checks through
   [testing](../../../docs/engineering/testing.md). Record positive executed
   identities, intentional skips and blocked native/model/provider coverage.
   Compile-only or inventory checks must remain labeled as such.
5. Reconcile related documentation using AGENTS' routing table. For docs-only
   changes, do not demand product suites merely because this is a feature review.
6. Return the short format in [reference/report.md](reference/report.md).
   Read that reference when composing the handoff. A clean reviewed change may
   have no blocking findings; do not widen scope to find something to report.

The guide is the single source of review standards. Keep this entry point thin;
do not turn historical reports into permanent product diagnoses.
