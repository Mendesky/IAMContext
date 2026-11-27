import Foundation

/// 授權範圍：範圍化權限（權限清單上標了 `grantScope` 的權限）授權時帶的一項範圍。
/// 一個權限可以有多項範圍，取聯集。設計：`docs/discussions/2026-11-25-scoped-permission-grant.md`（D7～D9、D22）。
///
/// 格式是「類型＋種類＋值清單」：`type` 說這是哪一類範圍（目前只有 `organization` 組織），`kind` 是那個類型底下的種類
/// （組織有 company、firms、departments、ownFirm、ownDepartment），`values` 的意思由類型與種類決定（組織的 firms 是所統編、
/// departments 是「所統編/組名」）。有哪些類型、種類，值要什麼格式，寫在權限清單的 `grant-scope-types.yaml`，
/// 由 `GrantScopeTypeDefinition` 帶進來；這個型別本身不認得任何類型，以後加類型不用改它，事件、API、gRPC 格式都不變。
///
/// - 解碼寬鬆：缺欄位或型別不符的欄位當成沒有，不丟錯（解碼失敗會讓那個人的權限整個讀不出來）。
///   是否合法由寫入端的指令檢查；讀取端只略過不完整的項目（`isComplete`），不認得的類型、種類由消費端略過。
/// - 「本人的所／組」這類相對的種類只存標記，由消費端查詢當下解析（D11），IAM 不解析。
package struct GrantScope: Codable, Hashable, Sendable {
    /// 範圍類型，例如 `organization`。
    package let type: String
    /// 類型底下的種類，例如 `firms`。
    package let kind: String
    /// 值清單；不帶值的種類（全公司、本人的所、本人的組）是 nil。
    package let values: [String]?

    package init(type: String, kind: String, values: [String]? = nil) {
        self.type = type
        self.kind = kind
        self.values = values
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? ""
        self.kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        self.values = try? container.decodeIfPresent([String].self, forKey: .values)
    }

    /// 類型與種類都有值。不完整的項目（例如 2026-11-27 改格式前 .55 寫的 `{kind, firms}`）讀取端略過。
    package var isComplete: Bool { !type.isEmpty && !kind.isEmpty }
}

/// 一種授權範圍類型的定義（來源：權限清單 `grant-scope-types.yaml`，由 IAMContextServer 組裝時帶入）。
package struct GrantScopeTypeDefinition: Hashable, Sendable {
    package let type: String
    /// 不限範圍的種類（組織是 company）。除錯模式 `IAM_DEBUG_FULL_PERMISSIONS` 回這個；沒有就是 nil，除錯模式不列這類權限。
    package let unrestrictedKind: String?
    /// 種類 → 定義。
    package let kinds: [String: GrantScopeKindDefinition]

    package init(type: String, unrestrictedKind: String? = nil, kinds: [GrantScopeKindDefinition]) {
        self.type = type
        self.unrestrictedKind = unrestrictedKind
        self.kinds = Dictionary(uniqueKeysWithValues: kinds.map { ($0.kind, $0) })
    }
}

/// 一個種類的定義：要不要帶值、值的格式。
package struct GrantScopeKindDefinition: Hashable, Sendable {
    package let kind: String
    /// 要不要帶值清單（指定所、指定組要；全公司、本人的所／組不能帶）。
    package let takesValues: Bool
    /// 每個值要整個符合的正規表示式；nil＝只要求不是空白。
    package let valuePattern: String?

    package init(kind: String, takesValues: Bool, valuePattern: String? = nil) {
        self.kind = kind
        self.takesValues = takesValues
        self.valuePattern = valuePattern
    }
}

/// 一個範圍化權限的範圍規則：用哪個類型、允許那個類型底下哪些種類（權限清單的 `grantScope: {type, kinds}`）。
package struct GrantScopeRule: Hashable, Sendable {
    package let type: GrantScopeTypeDefinition
    package let allowedKinds: Set<String>

    package init(type: GrantScopeTypeDefinition, allowedKinds: Set<String>) {
        self.type = type
        self.allowedKinds = allowedKinds
    }
}
