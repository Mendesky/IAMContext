import Foundation
import IAMContextShared

/// 授權範圍的檢查與正規化（指令守門用的純函式）。
/// 設計：`docs/discussions/2026-11-25-scoped-permission-grant.md` D7（依權限限定類型與種類）、D8（多項取聯集）、
/// D10（一定要帶範圍）、D22（範圍先有類型）。
///
/// 這裡不認得任何具體的類型、種類：類型、種類、值的格式都由權限清單的類型定義（`GrantScopeRule`）決定，
/// 以後加類型不用改這裡。
///
/// 寫入端嚴格：類型不對、不認得的種類、內容不合格式一律拒絕。讀取端寬鬆（`GrantScope` 解碼不丟錯、不完整的項目只略過），
/// 兩邊刻意不同：寫入擋住錯的資料，讀取讓日後新增的類型、種類不會把舊版弄壞。
package enum GrantScopeRules {
    /// 檢查一次授權帶的 `grantScopes`，回傳正規化後的範圍（只含範圍化的權限）。
    /// - `grantScopes` 裡的權限一定要在這次授予的 `permissions` 裡。
    /// - 範圍化的權限（`rules` 有的）每個都要有至少一項範圍，每項都要符合它的規則。
    /// - 不是範圍化的權限不能帶範圍。
    package static func validatedGrant(
        permissions: [String],
        grantScopes: [String: [GrantScope]],
        rules: [String: GrantScopeRule]
    ) throws -> [String: [GrantScope]] {
        let requested = Set(permissions)
        if let extra = grantScopes.keys.sorted().first(where: { !requested.contains($0) }) {
            throw ContextError<EmployeeAccessError>.grantScopeNotApplicable(message: "grantScopes has permission \(extra) that is not being granted")
        }
        var result: [String: [GrantScope]] = [:]
        for permission in requested.sorted() {
            if let rule = rules[permission] {
                result[permission] = try validated(grantScopes[permission] ?? [], rule: rule, permission: permission)
            } else if grantScopes[permission] != nil {
                throw ContextError<EmployeeAccessError>.grantScopeNotApplicable(message: "permission \(permission) does not take a grant scope")
            }
        }
        return result
    }

    /// 檢查一個範圍化權限的範圍清單並正規化：至少一項；每項的類型要是這個權限的類型、種類要在允許清單內、
    /// 值要符合種類的定義；去重、排序。
    package static func validated(_ scopes: [GrantScope], rule: GrantScopeRule, permission: String) throws -> [GrantScope] {
        guard !scopes.isEmpty else {
            throw ContextError<EmployeeAccessError>.grantScopeRequired(message: "permission \(permission) requires at least one grant scope")
        }
        var result: Set<GrantScope> = []
        for scope in scopes {
            guard scope.type == rule.type.type else {
                throw ContextError<EmployeeAccessError>.grantScopeKindNotAllowed(message: "grant scope type \"\(scope.type)\" is not allowed for \(permission) (expects \(rule.type.type))")
            }
            guard let definition = rule.type.kinds[scope.kind] else {
                throw ContextError<EmployeeAccessError>.grantScopeInvalid(message: "unknown grant scope kind \"\(scope.kind)\" in type \(rule.type.type) for \(permission)")
            }
            guard rule.allowedKinds.contains(scope.kind) else {
                throw ContextError<EmployeeAccessError>.grantScopeKindNotAllowed(message: "grant scope kind \(scope.kind) is not allowed for \(permission)")
            }
            result.insert(try normalized(scope, definition: definition, type: rule.type.type, permission: permission))
        }
        return result.sorted { sortKey($0) < sortKey($1) }
    }

    /// 一項範圍的內容檢查與正規化。
    /// - 不帶值的種類：不能有值。
    /// - 帶值的種類：至少一個值；每個值去頭尾空白（含全形空白）後不能是空白、要整個符合種類的格式；去重、排序。
    static func normalized(_ scope: GrantScope, definition: GrantScopeKindDefinition, type: String, permission: String) throws -> GrantScope {
        let values = (scope.values ?? []).map(trimmed)
        func invalid(_ reason: String) -> ContextError<EmployeeAccessError> {
            .grantScopeInvalid(message: "\(type).\(definition.kind) scope for \(permission): \(reason)")
        }
        guard definition.takesValues else {
            guard values.isEmpty else { throw invalid("must not carry values") }
            return GrantScope(type: type, kind: definition.kind)
        }
        guard !values.isEmpty else { throw invalid("needs at least one value") }
        guard !values.contains(where: \.isBlank) else { throw invalid("value must not be blank") }
        if let pattern = definition.valuePattern {
            let regex: Regex<AnyRegexOutput>
            do {
                regex = try Regex(pattern)
            } catch {
                throw invalid("value pattern \(pattern) in the permission catalog is not a valid regular expression")
            }
            if let bad = values.first(where: { (try? regex.wholeMatch(in: $0)) == nil }) {
                throw invalid("value \"\(bad)\" does not match \(pattern)")
            }
        }
        return GrantScope(type: type, kind: definition.kind, values: Array(Set(values)).sorted())
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesNewlinesAndFullWidthSpace)
    }

    private static func sortKey(_ scope: GrantScope) -> String {
        "\(scope.type)|\(scope.kind)|\((scope.values ?? []).joined(separator: ","))"
    }
}
