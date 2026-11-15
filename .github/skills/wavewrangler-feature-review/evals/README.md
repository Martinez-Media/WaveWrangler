# Review-skill smoke fixtures

`triggers.json` contains ten positive and ten near-miss queries. The explicit
hand-assigned split is fixed: six of each label train, four of each validate.
Tune the description on training failures only; do not move failing cases into
another split. Run each query three times in a fresh agent context and record
successful skill-load telemetry, not whether the reply mentions the skill name.
Positive labels need at least two activations; negative labels allow at most one.

`evals.json` contains five supplied-evidence cases: native-save entry,
cache currency/ABA, a value-level library counterexample, public-role keyboard
focus, and a clean docs-only over-reporting control. Assertions are defined before
grading. Compare outputs with and without the skill while making the same project contracts
available in both arms. Record scope violations and invented findings as well
as expected findings. No fixture authorizes its synthetic operations.

Use isolated configuration/state roots and read-only tools; disable external
connections and avoid the real working checkout. Bound concurrent evaluations
to two agents/processes. Record model, skill/guide snapshot, tool/context limits,
activation, exit status, response, duration and token/cost telemetry if available.
Do not retain or publish raw system/reasoning/credential telemetry.

Configuration-root isolation may not isolate the global skill registry; inspect
successful load telemetry and record ambient skills. If competitor skills are
absent, say that the trigger test measures only this skill's routing, not sibling
selection or security/PR workflow behavior.
Repeated runs of one query are correlated. Treat these small fixtures as smoke
evidence; one output per arm is a qualitative comparison, not an efficacy or
latency qualification. Prefer repeated and blind independent grading for any
stronger claim. Preserve unavailable checks and first failures honestly.
