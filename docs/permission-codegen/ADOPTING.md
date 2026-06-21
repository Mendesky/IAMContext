# Adopting endpoint-permission codegen in another context

This is the handoff contract for a **consuming context** (e.g. OpportunityContext, AuditContext)
that wants build-time, endpoint-level permission enforcement generated from YAML. The generator and
the SwiftPM build-tool plugin live in **IAMContext** (the provider); you depend on it.

What you get: on every `swift build`, two YAML files become two Swift files —
`Permission.swift` (the permission catalog) and `<Context>PermissionRules.swift` (the
endpoint→permission rules your middleware enforces). The YAML is the SSOT; the Swift is generated
into `.build/` and is never hand-edited or committed.

> Authoring the YAML is a separate, reusable step — use the `/permission-doc` skill. This doc is
> only about *wiring the plugin into your package* and the *contract you take on by enforcing it*.

---

## 0. Prerequisite — dependency-graph compatibility (read first)

The codegen is **bundled inside IAMContext** (a deliberate decision — it is not a thin standalone
package). So when you add `.package(... IAMContext)`, SPM resolves **IAMContext's entire dependency
graph** into your `Package.resolved`, including its `gradyzhuo/swift-ddd-kit` fork — even though the
plugin's own closure is only Yams + ArgumentParser.

**Consequence:** if your context depends on a *different* DDDKit fork (e.g. `Mendesky/DDDKit`), SPM
resolution can conflict (same modules, different package identity). Before adopting:

- If you don't use DDDKit, or you use the **same** `gradyzhuo/swift-ddd-kit` fork → no problem.
- If you use a **different** fork → align on one fork first, or raise it with the IAM team. Don't
  push past a resolution error by mixing forks.

---

## 1. Add the dependency

```swift
// Package.swift
dependencies: [
    // the codegen provider:
    .package(url: "git@github.com:Mendesky/IAMContext.git", from: "<version>"),
    //   …or during local dev: .package(path: "../IAMContext"),

    // the GENERATED PermissionRules.swift does `import Middleware` + `import HTTPTypes`,
    // so YOUR target must provide these (IAMContext does not vend them):
    .package(url: "<your Middleware package>", from: "<version>"),          // PermissionRule / PathValidator / PermissionMiddleware
    .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"), // HTTPRequest.Method
],
```

## 2. Wire the plugin into your server target

Attach the plugin to the target that owns your HTTP handlers (the one with
`registerHandlers(serverURL:)`):

```swift
.target(
    name: "YourServer",
    dependencies: [
        .product(name: "Middleware", package: "<your Middleware package>"),
        .product(name: "HTTPTypes",  package: "swift-http-types"),
    ],
    plugins: [
        .plugin(name: "PermissionGenPlugin", package: "IAMContext"),
    ]
),
```

## 3. Drop in the two YAML files (paired)

The document is **two files, paired by filename prefix**, both inside the plugin-enabled target:

```
Sources/YourServer/
  YourContext.permissions.yaml   # context + serverPrefix + permissions (the catalog)
  YourContext.rules.yaml         # context + rules (the routing)
```

- Author/maintain them with `/permission-doc` (it applies the inclusion, slot, and naming rules).
- A `.permissions.yaml` with **no matching `.rules.yaml`** is a build error — the plugin tells you
  to run `permission-gen --all`.
- Migrating from an old single combined file:
  `swift run --package-path /path/to/IAMContext permission-gen --all path/to/Combined.yaml`
  (writes both split files together).
- SPM emits a harmless "unhandled resource" warning for the `.yaml` files (same as DDDKit's
  `event.yaml`). **Do not** put migration/handoff files (e.g. a rename mapping table) inside the
  target dir — they'd trigger the same warning; keep them elsewhere in the repo.

## 4. Enforce at runtime

```swift
let rules = try YourContextPermissionRules.make()       // generated enum, name = <Context>PermissionRules
let permissionMiddleware = PermissionMiddleware(
    rules: rules,
    provider: yourIAMClient                              // conforms to Middleware.PermissionsProvider
)
```

`yourIAMClient` is *your* gRPC adapter that asks IAM "what permissions does this user have", generated
from `IAMContext/proto/PermissionsService.proto` (see OpportunityContext's `IAMContextGRPCClient`).
This doc/plugin defines **what an endpoint requires**; IAM defines **what a user has**.

## 5. Verify

```bash
# quick: render only, no build
swift run --package-path /path/to/IAMContext permission-gen \
  --permissions Sources/YourServer/YourContext.permissions.yaml \
  --rules       Sources/YourServer/YourContext.rules.yaml \
  --output-dir  /tmp/permcheck

# integration: the plugin runs inside your build (pairs the two files, generates, compiles)
swift build --target YourServer
```

The generator fails the build on: an invalid HTTP method, a same-slot const collision, or a
**dangling `requires` reference** (a rule pointing at a permission not in the catalog — checked
across the two files after merge).

---

## The contract you take on

1. **A permission only works if IAM grants it.** Every permission rawValue your rules require must be
   registered in IAM and granted to the relevant roles/users — otherwise the endpoint returns **403**.
   This applies to **new permissions and to renamed ones** (a slot/operationId change *is* a new
   rawValue). Coordinate adds/renames with the IAM team and hand them the before/after list. Safe
   rollout for a rename: **add-new → re-grant → remove-old**.
2. **Slot = the module/folder that owns the handler.** Single-aggregate op → the aggregate name
   (drop the `Aggregate` suffix); cross-aggregate / composition op → the composition module name
   (e.g. `OpportunityContext`, `OCShared`); generic object-storage infra (files/images) → the one
   reserved slot `Storage`. The old reserved words `Query` / `Workflow` are abolished. (The
   `/permission-doc` skill enforces this.)
3. **YAML is the SSOT.** Never hand-edit `Permission.swift` / `PermissionRules.swift`; they are
   generated into `.build/` and are not committed.
4. **`serverPrefix` lives only in the catalog file**, never in a rule's `path`.
5. **Pin the IAMContext version.** The generated `Permission` API changes when slots/operationIds
   change — treat that as an IAM-coordination event, not a silent bump.

## Automating with Claude Code (optional)

- `/permission-doc` — author/maintain the two YAML files from your API surface.
- `/adopt-permission-codegen` — do the wiring in this section (deps, plugin, middleware, verify) and
  print the IAM-grant reminder. Copy it into your repo's `.claude/skills/` if your team uses it.
