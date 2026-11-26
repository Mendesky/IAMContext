import Foundation
import IAMContextShared

/// 授權範圍的檢查與正規化（指令守門用的純函式）。
/// 設計：`docs/discussions/2026-11-25-scoped-permission-grant.md` D7（依權限限定種類）、D8（多項取聯集）、D10（一定要帶範圍）。
///
/// 寫入端嚴格：不認得的種類、內容不完整一律拒絕。讀取端寬鬆（`GrantScope` 解碼不丟錯、不認得的種類只略過那一項），
/// 兩邊刻意不同：寫入擋住錯的資料，讀取讓日後新增的種類不會把舊版弄壞。
package enum GrantScopeRules {
    /// 檢查一次授權帶的 `grantScopes`，回傳正規化後的範圍（只含範圍化的權限）。
    /// - `grantScopes` 裡的權限一定要在這次授予的 `permissions` 裡。
    /// - 範圍化的權限（`allowedKinds` 有的）每個都要有至少一項範圍，種類要在允許的清單裡。
    /// - 不是範圍化的權限不能帶範圍。
    package static func validatedGrant(
        permissions: [String],
        grantScopes: [String: [GrantScope]],
        allowedKinds: [String: Set<GrantScopeKind>]
    ) throws -> [String: [GrantScope]] {
        let requested = Set(permissions)
        if let extra = grantScopes.keys.sorted().first(where: { !requested.contains($0) }) {
            throw ContextError<EmployeeAccessError>.grantScopeNotApplicable(message: "grantScopes has permission \(extra) that is not being granted")
        }
        var result: [String: [GrantScope]] = [:]
        for permission in requested.sorted() {
            if let allowed = allowedKinds[permission] {
                result[permission] = try validated(grantScopes[permission] ?? [], allowed: allowed, permission: permission)
            } else if grantScopes[permission] != nil {
                throw ContextError<EmployeeAccessError>.grantScopeNotApplicable(message: "permission \(permission) does not take a grant scope")
            }
        }
        return result
    }

    /// 檢查一個範圍化權限的範圍清單並正規化：至少一項、每項種類在允許清單內、內容合法；去重、排序。
    package static func validated(_ scopes: [GrantScope], allowed: Set<GrantScopeKind>, permission: String) throws -> [GrantScope] {
        guard !scopes.isEmpty else {
            throw ContextError<EmployeeAccessError>.grantScopeRequired(message: "permission \(permission) requires at least one grant scope")
        }
        var result: Set<GrantScope> = []
        for scope in scopes {
            guard let kind = scope.knownKind else {
                throw ContextError<EmployeeAccessError>.grantScopeInvalid(message: "unknown grant scope kind \"\(scope.kind)\" for \(permission)")
            }
            guard allowed.contains(kind) else {
                throw ContextError<EmployeeAccessError>.grantScopeKindNotAllowed(message: "grant scope kind \(kind.rawValue) is not allowed for \(permission)")
            }
            result.insert(try normalized(scope, kind: kind, permission: permission))
        }
        return result.sorted { sortKey($0) < sortKey($1) }
    }

    /// 一項範圍的內容檢查與正規化。
    /// - 全公司、本人的所、本人的組：不能帶清單。
    /// - 指定所：至少一個所、每個都要是統編（8 碼數字）；去重、排序。
    /// - 指定組：至少一組、所要是統編、組名不能空白；去重、排序。
    /// 只檢查統編格式，不比對 StaffContext 的所別清單（IAM 不依賴 StaffContext，2026-09-03 決定）。
    static func normalized(_ scope: GrantScope, kind: GrantScopeKind, permission: String) throws -> GrantScope {
        let firms = (scope.firms ?? []).map(trimmed)
        let departments = (scope.departments ?? []).map { GrantScopeDepartment(firm: trimmed($0.firm), department: trimmed($0.department)) }
        func invalid(_ reason: String) -> ContextError<EmployeeAccessError> {
            .grantScopeInvalid(message: "\(kind.rawValue) scope for \(permission): \(reason)")
        }
        switch kind {
        case .company, .ownFirm, .ownDepartment:
            guard firms.isEmpty, departments.isEmpty else { throw invalid("must not carry firms or departments") }
            return GrantScope(kind: kind.rawValue)
        case .firms:
            guard departments.isEmpty else { throw invalid("must not carry departments") }
            guard !firms.isEmpty else { throw invalid("needs at least one firm") }
            guard firms.allSatisfy(isBusinessId) else { throw invalid("firm must be an 8-digit business id (統編)") }
            return .firms(Array(Set(firms)).sorted())
        case .departments:
            guard firms.isEmpty else { throw invalid("must not carry firms") }
            guard !departments.isEmpty else { throw invalid("needs at least one department") }
            guard departments.allSatisfy({ isBusinessId($0.firm) }) else {
                throw invalid("department firm must be an 8-digit business id (統編)")
            }
            guard !departments.contains(where: { $0.department.isBlank }) else {
                throw invalid("department name must not be blank")
            }
            return .departments(Array(Set(departments)).sorted { ($0.firm, $0.department) < ($1.firm, $1.department) })
        }
    }

    /// 統編：剛好 8 個半形數字（全形數字、少一碼、所別名稱都不算）。
    package static func isBusinessId(_ s: String) -> Bool {
        s.count == 8 && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesNewlinesAndFullWidthSpace)
    }

    private static func sortKey(_ scope: GrantScope) -> String {
        let firms = (scope.firms ?? []).joined(separator: ",")
        let departments = (scope.departments ?? []).map { "\($0.firm):\($0.department)" }.joined(separator: ",")
        return "\(scope.kind)|\(firms)|\(departments)"
    }
}
