import Foundation

/// 授權範圍：範圍化權限（權限清單上標了 `grantScopeKinds` 的權限）授權時帶的一項範圍。
/// 一個權限可以有多項範圍，取聯集。設計：`docs/discussions/2026-11-25-scoped-permission-grant.md`（D7～D9）。
///
/// - `kind` 以字串存，不用 enum 解碼：日後新增種類時，舊版讀到不認得的種類只略過那一項（`knownKind == nil`），
///   不能讓整筆 `PrivilegeGranted` 解碼失敗（解碼失敗會讓那個人的權限整個讀不出來）。
/// - 解碼同樣寬鬆：缺欄位或型別不符的欄位當成沒有，不丟錯。是否合法由寫入端的指令檢查，讀取端只略過不認得的項目。
/// - 所別一律統編（`docs/tasks/2026-09-03-firm-format-and-scope-check.md`）；組在同一所內才唯一，所以存（所統編, 組名）。
/// - 「本人的所／組」只存標記，由消費端查詢當下用 StaffContext 名冊解析（D11），IAM 不解析。
package struct GrantScope: Codable, Hashable, Sendable {
    package let kind: String
    /// `kind == firms` 時的所統編清單。
    package let firms: [String]?
    /// `kind == departments` 時的組清單。
    package let departments: [GrantScopeDepartment]?

    package init(kind: String, firms: [String]? = nil, departments: [GrantScopeDepartment]? = nil) {
        self.kind = kind
        self.firms = firms
        self.departments = departments
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        self.firms = try? container.decodeIfPresent([String].self, forKey: .firms)
        self.departments = try? container.decodeIfPresent([GrantScopeDepartment].self, forKey: .departments)
    }

    /// 這一項的種類；不認得（日後新增的種類、或資料不完整）時是 nil，讀取端略過這一項。
    package var knownKind: GrantScopeKind? { GrantScopeKind(rawValue: kind) }

    package static let company = GrantScope(kind: GrantScopeKind.company.rawValue)
    package static let ownFirm = GrantScope(kind: GrantScopeKind.ownFirm.rawValue)
    package static let ownDepartment = GrantScope(kind: GrantScopeKind.ownDepartment.rawValue)
    package static func firms(_ firms: [String]) -> GrantScope {
        GrantScope(kind: GrantScopeKind.firms.rawValue, firms: firms)
    }
    package static func departments(_ departments: [GrantScopeDepartment]) -> GrantScope {
        GrantScope(kind: GrantScopeKind.departments.rawValue, departments: departments)
    }
}

/// 指定組：組名只在同一所內唯一，所以帶所統編。
package struct GrantScopeDepartment: Codable, Hashable, Sendable {
    package let firm: String
    package let department: String

    package init(firm: String, department: String) {
        self.firm = firm
        self.department = department
    }
}

/// 目前認得的範圍種類。權限清單的 `grantScopeKinds` 也只能寫這幾個值。
package enum GrantScopeKind: String, Codable, CaseIterable, Sendable {
    /// 全公司。
    case company
    /// 指定所（可多個）。
    case firms
    /// 指定組（可多個，所＋組）。
    case departments
    /// 本人的所（消費端用名冊解析）。
    case ownFirm
    /// 本人的組（消費端用名冊解析）。
    case ownDepartment
}
