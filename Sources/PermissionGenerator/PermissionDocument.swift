//
//  PermissionDocument.swift
//  PermissionKit
//
//  The permission document is the single source of truth, split into two decoupled sections:
//    • permissions: the CATALOG — what permissions exist (slot + operationId).
//    • rules:       the ROUTING  — which route requires which permission(s), by reference.
//  This decoupling lets a route require multiple permissions (AND) and lets multiple routes share
//  one permission — neither of which a fused "1 entry = 1 perm = 1 rule" model can express.
//
//  Those two sections now live in TWO files (one document, two consumers):
//    • <Context>.permissions.yaml — context + serverPrefix + permissions (the CATALOG; IAM/role design).
//    • <Context>.rules.yaml       — rules (the ROUTING; this context's enforcement middleware).
//  `load(permissionsPath:rulesPath:)` merges them back into one `PermissionDocument`, so the existing
//  emitter validation (incl. the dangling-`requires` check) covers cross-file references unchanged.
//  `load(yamlPath:)` still loads a single file (a catalog-only or combined document) — used by the
//  cross-context aggregator (permission-catalog-gen) which only ever reads `permissions:`.
//

import Foundation
import Yams

/// Top-level permission document (one YAML file per context).
///
/// ```yaml
/// context: OpportunityContext
/// serverPrefix: /opportunity-context
///
/// # ① catalog — what permissions exist
/// permissions:
///   - slot: AuditQuoting          # Aggregate name, or Workflow / Query / File
///     operationId: editAccountingType
///     description: 編輯帳務類型      # optional
///
/// # ② rules — which route requires which permission(s), referenced by "<slot>.<operationId>"
/// rules:
///   - method: patch               # get | post | put | patch | delete
///     path: /audit-quotings/{quotingId}/accounting-type   # {param} → [^/]+
///     requires: [AuditQuoting.editAccountingType]         # AND of catalog refs
/// ```
public struct PermissionDocument: Codable, Sendable {
    /// Context name: permission namespace prefix + rules enum name.
    public let context: String
    /// Server URL prefix prepended to every rule's path regex (use "" for no prefix).
    public let serverPrefix: String
    /// The catalog: every permission that exists in this context.
    public let permissions: [PermissionCatalogEntry]
    /// The routing: each route + the permissions it requires (AND), by reference into the catalog.
    public let rules: [RuleEntry]

    public init(context: String, serverPrefix: String,
                permissions: [PermissionCatalogEntry], rules: [RuleEntry]) {
        self.context = context
        self.serverPrefix = serverPrefix
        self.permissions = permissions
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey { case context, serverPrefix, permissions, rules }

    // Lenient decoding: serverPrefix defaults to "", and permissions/rules default to [] when absent —
    // so a catalog-only document (no rules) parses fine for the aggregation use case.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.context = try c.decode(String.self, forKey: .context)
        self.serverPrefix = try c.decodeIfPresent(String.self, forKey: .serverPrefix) ?? ""
        self.permissions = try c.decodeIfPresent([PermissionCatalogEntry].self, forKey: .permissions) ?? []
        self.rules = try c.decodeIfPresent([RuleEntry].self, forKey: .rules) ?? []
    }

    public static func load(yamlPath: String) throws -> PermissionDocument {
        let data = try Data(contentsOf: URL(fileURLWithPath: yamlPath))
        return try YAMLDecoder().decode(PermissionDocument.self, from: data)
    }

    public static func load(yaml: String) throws -> PermissionDocument {
        try YAMLDecoder().decode(PermissionDocument.self, from: yaml)
    }

    // MARK: - two-file (split) loading

    /// Load the split layout — a catalog file (`<Context>.permissions.yaml`: context + serverPrefix +
    /// permissions) and a rules file (`<Context>.rules.yaml`: rules) — and merge them into one document.
    public static func load(permissionsPath: String, rulesPath: String) throws -> PermissionDocument {
        let catalogYAML = try String(contentsOf: URL(fileURLWithPath: permissionsPath), encoding: .utf8)
        let rulesYAML = try String(contentsOf: URL(fileURLWithPath: rulesPath), encoding: .utf8)
        return try merge(permissionsYAML: catalogYAML, rulesYAML: rulesYAML)
    }

    /// Merge a catalog document and a rules fragment into one `PermissionDocument`.
    /// `context` / `serverPrefix` come from the catalog (the catalog is authoritative); if the rules
    /// fragment carries either, it must agree with the catalog (else we fail — a silent mismatch would
    /// generate rules against the wrong namespace/prefix). The catalog must NOT itself carry rules when
    /// a separate rules file is supplied (that would be two sources for the same data).
    public static func merge(permissionsYAML: String, rulesYAML: String) throws -> PermissionDocument {
        let catalog = try YAMLDecoder().decode(PermissionDocument.self, from: permissionsYAML)
        guard catalog.rules.isEmpty else {
            throw DocumentError.catalogContainsRules(count: catalog.rules.count)
        }
        let fragment = try YAMLDecoder().decode(RulesFragment.self, from: rulesYAML)
        if let c = fragment.context, c != catalog.context {
            throw DocumentError.contextMismatch(catalog: catalog.context, rules: c)
        }
        if let p = fragment.serverPrefix, p != catalog.serverPrefix {
            throw DocumentError.serverPrefixMismatch(catalog: catalog.serverPrefix, rules: p)
        }
        return PermissionDocument(context: catalog.context, serverPrefix: catalog.serverPrefix,
                                  permissions: catalog.permissions, rules: fragment.rules)
    }

    /// Split this (combined) document into the two-file layout, as YAML strings.
    /// The catalog half = context + serverPrefix + permissions; the rules half = context + rules
    /// (the rules file carries `context:` for the consistency check / standalone decode, per the
    /// permission-doc skill convention; serverPrefix lives only in the catalog file).
    /// Used by `permission-gen --all` to migrate a combined document into the split files.
    public func splitYAML() throws -> (permissionsYAML: String, rulesYAML: String) {
        let encoder = YAMLEncoder()
        let catalog = CatalogFile(context: context, serverPrefix: serverPrefix, permissions: permissions)
        let rulesFile = RulesFragment(context: context, rules: rules)
        return (try encoder.encode(catalog), try encoder.encode(rulesFile))
    }

    /// The catalog half of the split layout (no rules) — encode-only shape for `splitYAML()`.
    private struct CatalogFile: Encodable {
        let context: String
        let serverPrefix: String
        let permissions: [PermissionCatalogEntry]
    }
}

/// Errors raised while merging the split (two-file) layout into one document.
public enum DocumentError: Error, CustomStringConvertible {
    case catalogContainsRules(count: Int)
    case contextMismatch(catalog: String, rules: String)
    case serverPrefixMismatch(catalog: String, rules: String)

    public var description: String {
        switch self {
        case let .catalogContainsRules(count):
            return "the catalog file (.permissions.yaml) must not contain `rules:` when a separate rules file is supplied (found \(count)) — move them to the .rules.yaml"
        case let .contextMismatch(catalog, rules):
            return "context mismatch between files: catalog says '\(catalog)', rules file says '\(rules)'"
        case let .serverPrefixMismatch(catalog, rules):
            return "serverPrefix mismatch between files: catalog says '\(catalog)', rules file says '\(rules)'"
        }
    }
}

/// The rules-only file (`<Context>.rules.yaml`): `rules:` is the payload. `context`/`serverPrefix`
/// are optional and, when present, are only used to consistency-check against the catalog file.
public struct RulesFragment: Codable, Sendable {
    public let context: String?
    public let serverPrefix: String?
    public let rules: [RuleEntry]

    private enum CodingKeys: String, CodingKey { case context, serverPrefix, rules }

    public init(context: String? = nil, serverPrefix: String? = nil, rules: [RuleEntry]) {
        self.context = context
        self.serverPrefix = serverPrefix
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.context = try c.decodeIfPresent(String.self, forKey: .context)
        self.serverPrefix = try c.decodeIfPresent(String.self, forKey: .serverPrefix)
        self.rules = try c.decodeIfPresent([RuleEntry].self, forKey: .rules) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(context, forKey: .context)
        try c.encodeIfPresent(serverPrefix, forKey: .serverPrefix)
        try c.encode(rules, forKey: .rules)
    }
}

/// A catalog entry: declares that a permission exists. No route lives here — routing is in `rules`.
public struct PermissionCatalogEntry: Codable, Sendable {
    /// Permission slot: an Aggregate name, or one of the reserved slots `Workflow` / `Query` / `File`.
    public let slot: String
    /// The operation id; PascalCased it becomes the permission's last segment + const name suffix.
    public let operationId: String
    /// Optional human description (carried for catalog/docs; not used by codegen).
    public let description: String?

    /// The reference key used by a rule's `requires`: `"<slot>.<operationId>"`.
    public var ref: String { "\(slot).\(operationId)" }

    public init(slot: String, operationId: String, description: String? = nil) {
        self.slot = slot
        self.operationId = operationId
        self.description = description
    }
}

/// A rule: a route, and the permissions it requires (AND), referenced by `"<slot>.<operationId>"`.
public struct RuleEntry: Codable, Sendable {
    /// HTTP method: get | post | put | patch | delete.
    public let method: String
    /// Route path with `{param}` placeholders (no server prefix); `{param}` → `[^/]+` in the regex.
    public let path: String
    /// References into the catalog (`"<slot>.<operationId>"`); AND semantics. Usually one.
    public let requires: [String]
    /// Optional human description.
    public let description: String?

    public init(method: String, path: String, requires: [String], description: String? = nil) {
        self.method = method
        self.path = path
        self.requires = requires
        self.description = description
    }
}
