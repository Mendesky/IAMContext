//
//  GrantScopeTypesDocument.swift
//  PermissionKit
//
//  授權範圍類型的定義檔（IAM 的 `grant-scope-types.yaml`）。權限清單裡範圍化的權限寫
//  `grantScope: { type, kinds }`，類型與種類要在這裡有定義；permission-catalog-gen 在 build 時檢查兩邊對得上，
//  再把定義一起產進 PermissionCatalog.swift。設計：IAMContext docs/discussions/2026-11-25-scoped-permission-grant.md D22。
//
//  ```yaml
//  grantScopeTypes:
//    - type: organization
//      name: 組織
//      unrestrictedKind: company      # 不限範圍的種類（除錯模式回這個）；可省略
//      kinds:
//        - kind: company
//          name: 全公司
//        - kind: firms
//          name: 指定所
//          values: 所統編               # 有寫 values＝這個種類要帶值清單（內容是值的說明）
//          valuePattern: '^[0-9]{8}$'   # 每個值要整個符合；可省略
//  ```
//

import Foundation
import Yams

public struct GrantScopeTypesDocument: Codable, Sendable {
    public let grantScopeTypes: [GrantScopeTypeSpec]

    public init(grantScopeTypes: [GrantScopeTypeSpec]) {
        self.grantScopeTypes = grantScopeTypes
    }

    public static func load(yaml: String) throws -> GrantScopeTypesDocument {
        try YAMLDecoder().decode(GrantScopeTypesDocument.self, from: yaml)
    }

    public static func load(yamlPath: String) throws -> GrantScopeTypesDocument {
        try load(yaml: String(contentsOfFile: yamlPath, encoding: .utf8))
    }
}

/// 一種授權範圍類型。
public struct GrantScopeTypeSpec: Codable, Sendable, Hashable {
    public let type: String
    /// 顯示名稱（console 用）。
    public let name: String?
    /// 不限範圍的種類；要是這個類型底下、不帶值的種類。
    public let unrestrictedKind: String?
    public let kinds: [GrantScopeKindSpec]

    public init(type: String, name: String? = nil, unrestrictedKind: String? = nil, kinds: [GrantScopeKindSpec]) {
        self.type = type
        self.name = name
        self.unrestrictedKind = unrestrictedKind
        self.kinds = kinds
    }
}

/// 類型底下的一個種類。
public struct GrantScopeKindSpec: Codable, Sendable, Hashable {
    public let kind: String
    /// 顯示名稱（console 用）。
    public let name: String?
    /// 有寫＝要帶值清單，內容是值的說明（例如「所統編」）；沒寫＝不能帶值。
    public let values: String?
    /// 每個值要整個符合的正規表示式；只有要帶值的種類能寫。
    public let valuePattern: String?

    public init(kind: String, name: String? = nil, values: String? = nil, valuePattern: String? = nil) {
        self.kind = kind
        self.name = name
        self.values = values
        self.valuePattern = valuePattern
    }
}

/// 類型定義、權限的 `grantScope` 寫錯時，permission-catalog-gen 丟這個錯讓 build 失敗。
public struct GrantScopeCatalogError: Error, CustomStringConvertible, Equatable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

extension GrantScopeTypesDocument {
    /// 檢查類型定義本身：類型、種類不重複，每個類型至少一個種類；不限範圍的種類要存在且不帶值；
    /// 只有要帶值的種類能寫格式，格式要是合法的正規表示式。
    public func validate() throws {
        var seenTypes = Set<String>()
        for type in grantScopeTypes {
            guard !type.type.isEmpty else { throw GrantScopeCatalogError("grant scope type name must not be empty") }
            guard seenTypes.insert(type.type).inserted else { throw GrantScopeCatalogError("grant scope type \(type.type) is defined twice") }
            guard !type.kinds.isEmpty else { throw GrantScopeCatalogError("grant scope type \(type.type) has no kinds") }
            var seenKinds = Set<String>()
            for kind in type.kinds {
                guard !kind.kind.isEmpty else { throw GrantScopeCatalogError("grant scope type \(type.type) has a kind with an empty name") }
                guard seenKinds.insert(kind.kind).inserted else {
                    throw GrantScopeCatalogError("grant scope kind \(type.type).\(kind.kind) is defined twice")
                }
                if let pattern = kind.valuePattern {
                    guard kind.values != nil else {
                        throw GrantScopeCatalogError("grant scope kind \(type.type).\(kind.kind) has valuePattern but takes no values")
                    }
                    guard (try? Regex(pattern)) != nil else {
                        throw GrantScopeCatalogError("grant scope kind \(type.type).\(kind.kind) has an invalid valuePattern \(pattern)")
                    }
                }
            }
            if let unrestricted = type.unrestrictedKind {
                guard let kind = type.kinds.first(where: { $0.kind == unrestricted }), kind.values == nil else {
                    throw GrantScopeCatalogError("unrestrictedKind \(unrestricted) of \(type.type) must be one of its kinds that takes no values")
                }
            }
        }
    }

    /// 檢查一個權限的 `grantScope`：類型要有定義、至少一個種類、種類都要在那個類型底下、不重複。
    public func validate(_ spec: GrantScopeSpec, permission: String) throws {
        guard let type = grantScopeTypes.first(where: { $0.type == spec.type }) else {
            throw GrantScopeCatalogError("\(permission): grant scope type \(spec.type) is not defined in grant-scope-types.yaml")
        }
        guard !spec.kinds.isEmpty else { throw GrantScopeCatalogError("\(permission): grantScope.kinds must not be empty") }
        guard Set(spec.kinds).count == spec.kinds.count else { throw GrantScopeCatalogError("\(permission): grantScope.kinds has duplicates") }
        let known = Set(type.kinds.map(\.kind))
        if let unknown = spec.kinds.first(where: { !known.contains($0) }) {
            throw GrantScopeCatalogError("\(permission): grant scope kind \(unknown) is not defined in type \(spec.type)")
        }
    }
}
