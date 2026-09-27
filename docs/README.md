# Project documentation

## Current workflow

- [Development procedure](DEVELOPMENT_PROCEDURE.md): setup, checks, canaries, exclusions and evidence retention.
- [CI and validation](CI_PLAN.md): implemented portable checks and remaining native CI work.
- [Repository cleanup](REPO_CLEANUP.md): preservation, Git state and validation of the cleanup pass.
- [Windows handoff](WINDOWS_HANDOFF.md): what transfers through Git and what is needed for reference captures.
- [User guide](../USER_GUIDE.md): application behavior and controls.

## Architecture and compatibility

- [Shader pipeline](SHADER_PIPELINE.md), [script host](SCRIPT_HOST_BINDINGS.md), [text format](TEXT_OBJECT_FORMAT.md).
- [Playback matrix](PLAYBACK_COMPATIBILITY_MATRIX.md) and [parity progress](WINDOWS_PARITY_PROGRESS.md).
- [Implementation tasks](IMPLEMENTATION_TASKS.md) and [standalone roadmap](STANDALONE_SCENE_ROADMAP.md).

## Historical context

- [Development history](archive/DEVELOPMENT_HISTORY.md): detailed feature regressions and pass-by-pass evidence.
- [Execution log](EXECUTION_LOG.md): historical implementation record.
- [Legacy engine archive](archive/README.md): preserved local upstream bridge modifications and recovery instructions.
- Migration-era reference maps: [upstream parse flow](PARSE_FLOW.md), [upstream runtime](RUNTIME_UPDATE_FLOW.md), [Phase 5 render mapping](RENDER_PASS_MAP.md). These describe historical scope, not the current native feature set.

Historical measurements and partial acceptance reports do not imply current full parity.
