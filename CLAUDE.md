# Claude Code project guide — IAMContext

This project was bootstrapped by **Genesis v0.1.0-phase1k2** from bundle `057e8202-6f1f-4e2c-b821-3b63d931f5df`. The generated domain code marks unfilled business logic with compile-time holes (`#error("GENESIS-TODO: ...")`) — the project will NOT compile until each hole is filled (this is intentional: an aggregate with unimplemented domain logic should not build). Fill the holes (say the domain logic, the skill/LLM writes it) and the `#error`s disappear; business-logic guidance lives in `.ai/contexts/IAMContext/<Aggregate>/`.

## How to fill in business logic

Use Claude Code skills to materialise stubs:

- `/usecase <UseCase>` — fill the body of `{UC}Service.execute(input:)` and the matching `{Aggregate}+{UC}.swift` command + `when(event:)` overloads.
- `/readmodel <ReadModel>` — generate read-model projector files (not yet supported by this scaffold; Phase 1.c does not write `projection-model.yaml`).
- `/api` — emit transport adapter from `.ai/contexts/IAMContext/<Aggregate>/api.md`.

## SSOT discipline

| Master file | Who edits |
|-------------|-----------|
| `.ai/contexts/IAMContext/<Aggregate>/commands.md` | `/usecase` skill + human |
| `.ai/contexts/IAMContext/<Aggregate>/invariants.md` | `/usecase` skill + human |
| `.ai/contexts/IAMContext/<Aggregate>/errors.md` | human |
| `.ai/contexts/IAMContext/<Aggregate>/api.md` | `/api` skill + human |
| `.ai/contexts/IAMContext/<Aggregate>/test-scenarios.md` | human (Gherkin master) |

`docs/tasks/<UC>.md` (when present) is **100% machine-rendered, hand-edits forbidden** (D15 Option D).

## Adapter

`./.ai/contexts/IAMContext/swift-adapter.yaml` controls Genesis behaviour on re-generation (type mapping, custom types, ID strategy, etc.). Schema: see Genesis's `architecture.md §6.2`.

## Manifest

`./.ai/contexts/IAMContext/.scaffold-manifest.json` records the sha256 of every file Genesis generated. Used by `genesis diff` (Phase 3) to detect human edits and decide which changes are safe to auto-apply.
