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
