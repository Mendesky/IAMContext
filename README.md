# IAMContext

Bootstrapped by **Genesis v0.1.0-phase1k2** from bundle `057e8202-6f1f-4e2c-b821-3b63d931f5df`.

## Layout

| Path | Contents |
|------|----------|
| `Package.swift` | SwiftPM manifest |
| `Sources/{Aggregate}Aggregate/` | One library target per aggregate (`1` total) |
| `Sources/IAMContextShared/` | Cross-aggregate value types (DTOs / enums / typed IDs) |
| `Tests/IAMContextTests/` | Test target (placeholder until business logic lands) |
| `.ai/contexts/IAMContext/` | Adapter + manifest |
| `.ai/contexts/IAMContext/<Aggregate>/` | Per-aggregate business docs (SSOT) |
| `.ai/conventions/api.md` | Cross-aggregate API conventions |

## Aggregates

- **EmployeeAccess** — 7 use cases

**Total**: 1 aggregate(s), 7 use case(s), 1 DTO(s).

## Build

```bash
swift build
swift test
```

## Next steps

Business logic lives in `.ai/contexts/IAMContext/<Aggregate>/`. See `CLAUDE.md` for how to use Claude Code skills (`/usecase`, `/readmodel`, `/api`) to fill in the stubs.
