//
//  PermissionEmitter.swift
//  PermissionKit
//
//  Pure rendering: PermissionDocument -> (Permission.swift, PermissionRules.swift) source strings.
//  Permission.swift comes from the `permissions:` catalog; PermissionRules.swift comes from `rules:`,
//  with each rule's `requires` refs resolved against the catalog. No file IO, no runtime types.
//

import Foundation

public enum GeneratorError: Error, CustomStringConvertible {
    case invalidMethod(method: String, path: String)
    case constCollision(const: String, rawA: String, rawB: String)
    case danglingReference(ref: String, method: String, path: String)

    public var description: String {
        switch self {
        case let .invalidMethod(method, path):
            return "invalid method '\(method)' for rule '\(path)' (expected get/post/put/patch/delete)"
        case let .constCollision(const, rawA, rawB):
            return "permission const collision '\(const)' maps to both '\(rawA)' and '\(rawB)'"
        case let .danglingReference(ref, method, path):
            return "rule '\(method) \(path)' requires '\(ref)' which is not declared in permissions:"
        }
    }
}

public struct PermissionEmitter {
    public let document: PermissionDocument

    public init(document: PermissionDocument) {
        self.document = document
    }

    public struct Output: Sendable {
        public let permissionSwift: String
        public let rulesSwift: String
    }

    private static let allowedMethods: Set<String> = ["get", "post", "put", "patch", "delete"]

    public func render() throws -> Output {
        try validate()
        return Output(permissionSwift: renderPermission(), rulesSwift: renderRules())
    }

    // MARK: - naming

    static func pascal(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    static func lowerFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }

    /// `lowerFirst(slot) + Pascal(operationId)`, e.g. `auditQuotingEditAccountingType`.
    func constName(slot: String, operationId: String) -> String {
        Self.lowerFirst(slot) + Self.pascal(operationId)
    }

    /// `<context>.<slot>.<Pascal(operationId)>`, e.g. `OpportunityContext.AuditQuoting.EditAccountingType`.
    func rawValue(slot: String, operationId: String) -> String {
        "\(document.context).\(slot).\(Self.pascal(operationId))"
    }

    /// `serverPrefix` + path with every `{param}` replaced by `[^/]+`.
    func pathRegex(_ path: String) -> String {
        var result = ""
        var insideBrace = false
        for ch in path {
            if ch == "{" { insideBrace = true; result += "[^/]+"; continue }
            if ch == "}" { insideBrace = false; continue }
            if insideBrace { continue }
            result.append(ch)
        }
        return document.serverPrefix + result
    }

    /// Map a rule's reference (`"<slot>.<operationId>"`) to its const name, via the catalog.
    private func catalogByRef() -> [String: PermissionCatalogEntry] {
        Dictionary(document.permissions.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - validation

    private func validate() throws {
        // const collisions in the catalog
        var rawByConst: [String: String] = [:]
        for e in document.permissions {
            let c = constName(slot: e.slot, operationId: e.operationId)
            let r = rawValue(slot: e.slot, operationId: e.operationId)
            if let existing = rawByConst[c], existing != r {
                throw GeneratorError.constCollision(const: c, rawA: existing, rawB: r)
            }
            rawByConst[c] = r
        }
        // each rule: valid method + all `requires` refs resolve to a catalog entry
        let refs = Set(document.permissions.map(\.ref))
        for rule in document.rules {
            guard Self.allowedMethods.contains(rule.method.lowercased()) else {
                throw GeneratorError.invalidMethod(method: rule.method, path: rule.path)
            }
            for req in rule.requires where !refs.contains(req) {
                throw GeneratorError.danglingReference(ref: req, method: rule.method, path: rule.path)
            }
        }
    }

    // MARK: - Permission.swift (from the catalog)

    private func renderPermission() -> String {
        // Slot order = first appearance; consts within a slot sorted for stability.
        var slotOrder: [String] = []
        var seenSlot = Set<String>()
        for e in document.permissions where !seenSlot.contains(e.slot) {
            seenSlot.insert(e.slot)
            slotOrder.append(e.slot)
        }

        var bySlot: [String: [(const: String, raw: String)]] = [:]
        for slot in slotOrder {
            var list: [(const: String, raw: String)] = []
            var localSeen = Set<String>()
            for e in document.permissions where e.slot == slot {
                let c = constName(slot: e.slot, operationId: e.operationId)
                if localSeen.contains(c) { continue }
                localSeen.insert(c)
                list.append((c, rawValue(slot: e.slot, operationId: e.operationId)))
            }
            bySlot[slot] = list.sorted { $0.const < $1.const }
        }

        let total = bySlot.values.reduce(0) { $0 + $1.count }

        var lines: [String] = []
        lines.append("// AUTO-GENERATED by PermissionKit (permission-gen). DO NOT EDIT.")
        lines.append("// Source of truth: the permission YAML. Regenerated by `swift build` via PermissionGenPlugin.")
        lines.append("// context: \(document.context); permissions: \(total)")
        lines.append("")
        lines.append("/// A permission string (open set, tolerant of values an external IAM may not know).")
        lines.append("public struct Permission: RawRepresentable, Hashable, Sendable, Codable {")
        lines.append("    public let rawValue: String")
        lines.append("    public init(rawValue: String) { self.rawValue = rawValue }")
        lines.append("    fileprivate init(_ value: String) { self.rawValue = value }")
        lines.append("}")
        lines.append("")

        var allConsts: [String] = []
        for slot in slotOrder {
            let list = bySlot[slot] ?? []
            lines.append("// MARK: - \(slot) (\(list.count))")
            lines.append("extension Permission {")
            for item in list {
                lines.append("    public static let \(item.const) = Permission(\"\(item.raw)\")")
                allConsts.append(item.const)
            }
            lines.append("}")
            lines.append("")
        }

        lines.append("// MARK: - All")
        lines.append("extension Permission {")
        lines.append("    public static let all: [Permission] = [")
        var i = 0
        while i < allConsts.count {
            let chunk = allConsts[i..<min(i + 6, allConsts.count)]
            lines.append("        " + chunk.map { "." + $0 }.joined(separator: ", ") + ",")
            i += 6
        }
        lines.append("    ]")
        lines.append("}")

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - PermissionRules.swift (from rules, resolving refs)

    private func renderRules() -> String {
        let catalog = catalogByRef()

        var lines: [String] = []
        lines.append("// AUTO-GENERATED by PermissionKit (permission-gen). DO NOT EDIT.")
        lines.append("// path regex includes serverPrefix \(document.serverPrefix); PathValidator wholeMatches request.uri.path.")
        lines.append("")
        lines.append("import HTTPTypes")
        lines.append("import Middleware")
        lines.append("")
        lines.append("enum \(document.context)PermissionRules {")
        lines.append("    /// All \(document.rules.count) endpoint permission rules.")
        lines.append("    static func make() throws -> [PermissionRule] {")
        lines.append("        [")
        for rule in document.rules {
            let regex = pathRegex(rule.path)
            let method = "." + rule.method.lowercased()
            let requiresClause = rule.requires.map { ref -> String in
                let entry = catalog[ref]!  // validated non-nil
                return "Permission.\(constName(slot: entry.slot, operationId: entry.operationId)).rawValue"
            }.joined(separator: ", ")
            lines.append("            PermissionRule(PathValidator(try Regex(#\"\(regex)\"#)), methods: [\(method)], requires: [\(requiresClause)]),  // \(rule.method.lowercased()) \(rule.path)")
        }
        lines.append("        ]")
        lines.append("    }")
        lines.append("}")

        return lines.joined(separator: "\n") + "\n"
    }
}
