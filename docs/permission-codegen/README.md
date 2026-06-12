# PermissionKit

A SwiftPM **build-tool plugin** that turns a single permission document (YAML) into a context's
`Permission.swift` (the catalog) and `PermissionRules.swift` (the endpoint→permission rules) — on
every `swift build`. The YAML is the single source of truth; the two Swift files are generated and
never hand-edited (mirrors how DDDKit generates domain events).

## The permission document (SSOT)

One YAML file per context, named `*permissions.yaml`. It is **split into two decoupled sections** —
the catalog (what permissions exist) and the rules (which route requires which permission(s)):

```yaml
context: OpportunityContext          # permission namespace + rules enum name
serverPrefix: /opportunity-context   # prepended to every rule's path regex ("" for none)

# ① catalog — what permissions exist
permissions:
  - slot: AuditQuoting               # an Aggregate name, or Workflow / Query / File
    operationId: editAccountingType  # PascalCased → permission's last segment
    description: 編輯帳務類型           # optional, for humans
  - slot: Workflow
    operationId: closeDeal

# ② rules — which route requires which permission(s), by "<slot>.<operationId>" reference
rules:
  - method: patch                    # get | post | put | patch | delete
    path: /audit-quotings/{quotingId}/accounting-type   # {param} → [^/]+ in the regex
    requires: [AuditQuoting.editAccountingType]         # AND of catalog refs (usually one)
  # a route may require multiple permissions (AND), and multiple routes may share one:
  - method: post
    path: /audit-quotings/{quotingId}/final-approve
    requires: [AuditQuoting.editAccountingType, Workflow.closeDeal]
```

The generator derives, from the **catalog**:

| Output | Value |
|---|---|
| permission rawValue | `OpportunityContext.AuditQuoting.EditAccountingType` |
| Swift const | `auditQuotingEditAccountingType` (`lowerFirst(slot)+Pascal(op)`) |

…and from each **rule**:

| Output | Value |
|---|---|
| path regex | `/opportunity-context/audit-quotings/[^/]+/accounting-type` |
| rule | `PermissionRule(PathValidator(try Regex(#"…"#)), methods: [.patch], requires: [Permission.auditQuotingEditAccountingType.rawValue])` |

Why split? It lets a route require **multiple** permissions (AND) and lets **multiple** routes share
one permission — neither expressible by a fused "1 entry = 1 perm = 1 rule" model. A catalog
permission with no rule is allowed (catalog-only). The generator validates each method, fails on a
permission-const collision, and **fails on a dangling `requires` reference** (a rule pointing at a
permission not declared in `permissions:`).

## How a context adopts it

```swift
// Package.swift
dependencies: [
    .package(url: "git@github.com:Mendesky/PermissionKit.git", from: "1.0.0"),
    // ...Middleware (for PermissionRule / PathValidator) + swift-http-types (for HTTPRequest.Method)
],
targets: [
    .target(
        name: "YourServer",
        dependencies: [
            .product(name: "Middleware", package: "Middleware"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
        ],
        plugins: [
            .plugin(name: "PermissionGenPlugin", package: "PermissionKit"),
        ]
    ),
]
```

Drop `YourContext.permissions.yaml` into that target. `swift build` then generates and compiles
`Permission.swift` + `PermissionRules.swift`. Use them as usual:

```swift
let rules = try YourContextPermissionRules.make()
let middleware = PermissionMiddleware(rules: rules, provider: /* your context's IAMContextGRPCClient — see OpportunityContext Sources/IAMContextClient */)
```

(SPM emits an "unhandled resource" warning for the `.yaml` — harmless, same as DDDKit's `event.yaml`.)

## Aggregating across contexts (`PermissionCatalogPlugin`)

The per-context plugin above generates *enforcement* code for one context. A second plugin,
`PermissionCatalogPlugin`, does the opposite: it reads **many** `*permissions.yaml` files in a target
and emits one **`PermissionCatalog.swift`** — a flat, enumerable, cross-context catalog (no rules).
For an *aggregator* (e.g. IAM) that needs every context's permissions for role design or a
permission-granting UI.

```swift
.target(
    name: "PermissionCatalog",
    plugins: [ .plugin(name: "PermissionCatalogPlugin", package: "PermissionKit") ]
)
```

Drop one `<Context>.permissions.yaml` per context into that target; `swift build` emits:

```swift
public struct PermissionInfo { let context, slot, operationId, rawValue: String; let description: String? }

public enum PermissionCatalog {
    public static let all: [PermissionInfo]                       // every permission, every context
    public static let contexts: [String]                          // context names, sorted
    public static let allRawValues: Set<String>                   // the universe — e.g. validate a grant
    public static func permissions(inContext:) -> [PermissionInfo]
    public static func permissions(inSlot:) -> [PermissionInfo]
}
```

It reads only the `permissions:` (catalog) of each document — `rules:` are ignored — and needs no
Middleware/HTTPTypes (pure data). Permissions are deduped by rawValue (the `context.` prefix keeps
them globally unique). How the per-context yamls reach the aggregator's folder (copy vs sync) is a
separate deployment concern.

## Package layout

| Part | Path |
|---|---|
| YAML model + Swift emitter (pure, no runtime deps) | `Sources/PermissionGenerator` |
| CLI invoked by the plugin (and runnable by hand) | `Sources/permission-gen` |
| Build-tool plugin | `Plugins/PermissionGenPlugin` |
| Parity tests (generated set == OpportunityContext's 153) | `Tests/PermissionGeneratorTests` |
| One-off fixture deriver from OC openapi (read-only) | `scripts/oc_to_yaml.py` |

Run the generator by hand:

```bash
swift run permission-gen --output-dir ./out path/to/YourContext.permissions.yaml
```

## Validation

`swift test` proves the generator reproduces OpportunityContext's existing **153 permissions and
153 rules** exactly (set equality of permission rawValues and of `(pathRegex, method, const)` rule
tuples), from a YAML fixture derived read-only from OC's openapi. The sibling `PermissionKitExample`
package proves the plugin runs and its output compiles inside `swift build`.
