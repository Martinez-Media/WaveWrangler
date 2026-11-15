# End-of-feature review

Use this procedure for a completed feature or pull-request change. It is a
changed-contract review, not a full-codebase audit, automatic refactor, or grant
of Git, media, model, experiment or host permissions. Agents can invoke the
project [wavewrangler-feature-review skill](../../.github/skills/wavewrangler-feature-review/SKILL.md).

## Establish the review surface

Read [AGENTS](../../AGENTS.md), inspect the current diff and dirty-worktree
ownership, and identify the intended behavior and compatibility limits. State
the base/source identity, changed paths, directly dependent callers and tests.
If only supplied excerpts are available, review those and name the omissions;
do not invent checkout evidence or file lines. A synthetic identifier matching
an app type/property does not establish that implementation's storage or
ownership semantics; require supplied evidence before importing those facts.

Follow the [architecture](architecture.md) routing table to the owning layer.
Read only the applicable focused contracts from the [engineering index](README.md).
Do not reopen retired work, reinterpret a historical plan as permission, or
expand a small feature review into a repository-wide inspection.

## Review responsibility and ownership

Trace each changed path from input through validated operation, native adapter,
publication and user-visible failure. Name the owner of canonical state, access
records, derived jobs, native processors and Undo. Confirm directly dependent
callers retain the same semantics.

Apply SOLID/DRY to actual responsibilities and contracts, not class counts.
Prefer validated value transforms and existing protocol seams. Extract repeated
logic when its semantics, numerical behavior and invalidation rules are the same.
A long file alone is not a defect; similar frozen and current DSP kernels are not
automatically interchangeable. Avoid creating one protocol per type or moving
I/O, UI, permission policy or tasks into pure kernels.

For a new `@unchecked Sendable`, unsafe isolation escape or callback bridge, write
down the complete invariant: which lock/queue owns each field, which callbacks
cross it, when cancellation can arrive, and who drains/releases native resources.
Inspect all accesses, not only the happy path. Native synchronous render/capture
boundaries do not become safer merely by wrapping them in an actor.

## Check executors, currency and failure

Inspect manifest and target settings before interpreting `async`/`nonisolated`.
Swift 6 language mode is not proof that caller-isolation defaults are enabled.
[SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)
gates the changed default with `NonisolatedNonsendingByDefault`; `@concurrent`
explicitly hops off the caller actor but does not bound work or guarantee timely
cancellation. [SE-0466](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)
controls optional per-target default isolation. Check the actual call/executor
path before labeling synchronous work a UI stall; do not blanket-enable MainActor
for reusable kernels.

At each suspension and cache hit, identify captured inputs and the live admission
check before adoption. Trace equal-byte Undo/restore, deletion, relink/revocation
and an unrelated edit arriving during work. Actor isolation alone does not prevent
stale writes. Conditional store mutation must be atomic at the owning store;
record equality may not protect ABA, and process-local atomicity is not a
cross-process guarantee. Unsupported conditional capabilities must refuse, not
silently fall back to unconditional save.

Trace errors and cancellation to the established visible path. A `try?` on an
explicit destructive/inverse operation needs a justified policy, not a silent
success-shaped result. When an inverse fails, check the receipt and Undo/Redo
presentation, not just the underlying record. Never retain an Undo group across
an await or claim that an already-applied edit was unchanged.

For saved state, permissions, migration or native lifecycle, consult
[persistence and source access](persistence-and-source-access.md) and the
recordings/native-state sections of [AGENTS](../../AGENTS.md). Review the existing
witnessed gateway, supported-version admission, exact backups, verified publication,
shared document/Undo ownership and native capture barriers as applicable.
An idle pre-captured AppKit save must enter synchronously; inserting a Task can
lose the file-access context. Opening a document or finding a warm cache is not
source-content authorization. Model download consent is not media access/upload
consent. A refusal or compatibility change needs an explicit decision.

## Check bounded performance without changing the contract

Account separately for active workers, queued closures/requests, retained results,
PCM buffers, recipe/key metadata, cache lifetime and native allocations. A serial
lane does not bound its backlog; a PCM-byte cap does not bound slot/recipe metadata.
Check cancellation during CPU work, permit recovery, cursor close and owned-work
join, including cancel-then-restart. Preserve per-consumer versus superseding-job
semantics when proposing shared work.

Start with local repeated-work elimination and existing immutable projections;
retained caching adds invalidation and memory cost. For UI work, measure body
updates and dependency causes with
[Apple's SwiftUI performance tools](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance).
For DSP, compare exact output/evidence before measuring preparation, allocation
or throughput. Read [audio processing](audio-processing.md) and
[program timeline](program-timeline.md) when samples, clocks, routing or effects
are involved. Do not trade native-state safety, source surveillance or numerical
qualification for an apparent speedup.

Report mechanism separately from measured benefit. Use generated workloads,
cold/warm labels, optimized-build identity and repeated isolated measurements.
Do not invent a percentage improvement or universal latency SLA from an
Instruments highlight. Preserve frozen evidence and opt-in experiment gates.

## Select and interpret validation

Follow [testing](testing.md) for the smallest relevant layer and resource budget.
Inspect test discovery, actual selectors, opt-in flags and output before claiming
coverage. A required named pass needs positive executed identity evidence;
an exit-0 empty selection or skipped required test is not a pass. Ordinary passes
may intentionally skip separately admitted heavy suites.

Use admission handshakes and bounded monotonic deadlines in asynchronous tests,
not task-creation order or a single yield as proof of ordering.
[Actor scheduling](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md)
is not FIFO. [Swift Testing `.serialized`](https://developer.apple.com/documentation/testing/parallelization)
serializes suite contents, not unrelated suites; it is not shared-process
isolation. Capture scalar leaves before assertions on heavy native/model graphs.

For UI transition readiness, prefer bounded existence/value/focus predicates and
last-observed diagnostics. Keep deliberate elapsed observation windows that prove
no retry/write/download occurs. Check effective keyboard navigation, key window,
selected tab and actual focus before attributing a failed Tab/Space test to product
behavior. A retry pass does not erase first-failure evidence.

For document-owned recovery/status actions, review the window owner and focus
subtree as well as individual control properties. Visibility, AX presence,
focus bindings or native button substitution do not prove Tab reachability.
If the editor/inspector subtree excludes these actions, place them with the
shared window controls outside that subtree rather than adding autofocus or
private focus repairs. Verify real Tab/Space activation and preserved editor/
timeline traversal; do not generalize one placement fix into a ban on insets.

When keyboard monitors gate on accessibility roles, do not equate failed
`NSAccessibilityProtocol` conformance with noninteractive focus. A focused
SwiftUI accessibility proxy may expose a public role without that conformance.
Verify the public role/event destination before consuming Space or navigation
keys; preserve native controls, menu/popover activation and timeline shortcuts
without relying on private SwiftUI types or APIs. Use the
[public accessibility contract](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol);
Apple's [accessibility guidance](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/EnhancingtheAccessibilityofStandardAppKitControls.html)
also explains why formal protocol adoption is not required for accessible
elements to expose information or actions.

Hosted/UI runtime requires the [leased-VM procedure](gui-testing.md) and
[host readiness](ui-test-vm-hosts.md). Startup permission does not waive lease,
readiness or cleanup. An unavailable VM does not authorize a desktop fallback.
Physical-hardware, model-backed, provider and holdout checks require their own
scope and authorization. Documentation-only changes ordinarily need link and
source-consistency checks, not product builds or app launches.

When presenting evidence, distinguish compilation, static inventory, test
identities, parameterized executions, intentional skips and runtime passes.
Include exact source/patch, build/host/workload identity, failures and omissions.
Historical or parent-run evidence is separate from this review's execution.

## Synchronize documentation and report

Use the documentation routing table in [AGENTS](../../AGENTS.md) to update only
the affected contributor, engineering and product guides. Remove superseded text;
do not copy full contracts into every entry point or embed current review findings
as permanent known bugs. Check changed instructions against source and test paths.

Report actual coverage and findings with path/line evidence, impact, likelihood,
confidence, change risk, effort, concrete proposed correction and smallest
validation. Separate static mechanisms, demonstrated reachable paths, dynamic
reproductions and measurements. Name compatibility or ownership decisions and
challenge unnecessary abstraction. "No blocking findings in the reviewed scope"
is valid; do not manufacture a defect to justify the review.

Use a concise handoff: blocking findings first, then justified opportunities,
unmeasured hypotheses and remaining evidence/decisions. Unless the current
request authorizes fixes, leave product changes as proposals.
