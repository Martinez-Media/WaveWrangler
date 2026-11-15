# Review handoff

State the reviewed source/diff identity, actual paths/contracts inspected and
omissions. Do not imply every line or every runtime layer was checked.

For each meaningful finding give:

- Evidence: real path/line and static mechanism, reachable counterexample,
  dynamic reproduction or measured workload.
- Consequence: impact, likelihood and confidence separately.
- Proposal: surgical correction, risk/relative effort, compatibility decision.
- Validation: smallest selector or check that would fail without the correction,
  prerequisites and any blocked evidence.

Lead with blocking issues if present. Separate nonblocking improvements from
unmeasured performance hypotheses; say "no blocking findings in the reviewed
scope" when warranted. Do not reproduce a generic SOLID checklist.

Use `[x]` for verified work, `[~]` for partial evidence, `[!]` for blockers and
`[ ]` for remaining decisions. Keep counts aggregate-safe: test identities and
parameterized executions are different, and overlapping UI profiles do not sum
to total coverage. Distinguish this run from parent/historical evidence.

End with only the decisions/evidence needed for handoff. Do not silently mark a
feature ready because required native runtime evidence is blocked.
