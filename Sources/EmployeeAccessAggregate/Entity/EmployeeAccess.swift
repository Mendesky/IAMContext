import DDDKit
import Foundation
import IAMContextShared
package class EmployeeAccess: EmployeeAccessAggregateProtocol {
    package let id: String
    package var metadata: AggregateRootMetadata = .init()

    // NOTE: removed duplicate `package var id: String?` (scaffold/adapter emitted bundle-state `id` on top of
    // DDDKit's required `package let id: String` above → invalid redeclaration). Proper long-term fix: exclude
    // `id` from state mapping in swift-adapter.yaml so a future `genesis new` won't reintroduce it.
    package var userId: String?
    package var permissions: Set<String>?
    package var roles: Set<String>?
    package var department: String?
    package var firm: String?
    package var jobTitle: String?
    package var status: EmployeeStatus?

    package static var category: String {
        // NOTE: prefix 必須是 "IAM"（IAMContext → IAM），與 projection 的 $ce-IAMEmployeeAccess 及 presenter
        // categoryRule .fromClass(withPrefix: "IAM_") 對齊。原 codegen 產 "IAMC"（誤取 IAMContext 大寫字母）
        // → 寫入落在 $ce-IAMCEmployeeAccess、projection 訂 $ce-IAMEmployeeAccess → 事件流不到 projector、read model 永遠空。
        "IAM\(Self.self)"
    }

    package init(id: String, userId: String, department: String, jobTitle: String, permissions: Set<String>, roles: Set<String>, status: EmployeeStatus, firm: String? = nil) throws {
        self.id = id
        self.userId = userId
        self.department = department
        self.firm = firm
        self.jobTitle = jobTitle
        self.permissions = permissions
        self.roles = roles
        self.status = status
        // GENESIS-STUB: validate input via ensureInvariant() before emitting createdEvent
        let event = UserAccessProfileCreated(
            employeeAccessId: id,
            userId: userId,
            department: department,
            jobTitle: jobTitle,
            permissions: permissions,
            roles: roles,
            status: status,
            firm: firm,
            occurred: .now
        )
        try self.apply(event: event)
    }
    // Create entry point used by the create use-case (/usecase Create pattern). The use-case Input does
    // NOT carry non-input createdEvent payload field(s) [permissions, roles, status], so deriving them is domain logic.
    package convenience init(id: String, userId: String, department: String, jobTitle: String, firm: String? = nil) throws {
        // 建立時「不」預先給權限：profile 以空權限起始，權限之後由 grantPrivilege 顯式授予
        // （human decision 2026-06-22，推翻先前「新人先給全部權限」placeholder）。roles 空集合、status .Active。
        try self.init(
            id: id,
            userId: userId,
            department: department,
            jobTitle: jobTitle,
            permissions: [],
            roles: [],
            status: .Active,
            firm: firm
        )
    }
    package required convenience init?(first createdEvent: UserAccessProfileCreated, other events: [any DomainEvent]) throws {
        try self.init(
            id: createdEvent.employeeAccessId,
            userId: createdEvent.userId,
            department: createdEvent.department,
            jobTitle: createdEvent.jobTitle,
            permissions: createdEvent.permissions,
            roles: createdEvent.roles,
            status: createdEvent.status,
            firm: createdEvent.firm
        )
        try self.apply(events: events)
        try self.clearAllDomainEvents()
    }

    package func ensureInvariant() throws {
        // domain-fill: (a) userIdNotExist + (c) employeeNotActive 由人口述轉錄；(b) permissionNotMatch held。
        // Bundle-declared invariants:
        //   - 確認 User ID 存在 (userIdNotExist): userId !== nil; userId !== null
        //   - 確認使用者身上的權限符合部門、職稱 (permissionNotMatch): userPermissions ⊇ baseline(department, jobTitle)
        //   - 員工必須在職 (employeeNotActive): status == activate

        // (a) 確認 User ID 存在 — userId 必須存在且非空字串（nil 或 "" 都擋）
        guard let userId, !userId.isEmpty else {
            throw ContextError<EmployeeAccessError>.userIdNotExist(function: #function, message: "userId must be present and non-empty")
        }

        // (c) 員工必須在職 — status 必須為 .Active
        guard status == .Active else {
            throw ContextError<EmployeeAccessError>.employeeNotActive(function: #function, message: "employee status must be Active")
        }

        // (b) 確認權限符合部門、職稱 — userPermissions ⊇ baseline(department, jobTitle)
        //     placeholder (human-authorized 2026-06-03)：baseline 細項未規劃 → 暫不強制（required = []）→ 一律通過。
        //     TODO: 權限方案定案後改為真正 baseline（例如 static [String: Set<String>] 對照表）。
        let required: Set<String> = []
        guard (permissions ?? []).isSuperset(of: required) else {
            throw ContextError<EmployeeAccessError>.permissionNotMatch(function: #function, message: "permissions do not satisfy baseline")
        }
    }
}
