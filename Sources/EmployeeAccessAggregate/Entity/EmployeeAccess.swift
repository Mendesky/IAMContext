import DDDKit
import Foundation
import IAMContextShared
import IAMPermissionCatalog
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
    package var jobTitle: String?
    package var status: EmployeeStatus?

    package static var category: String {
        // NOTE: prefix 必須是 "IAM"（IAMContext → IAM），與 projection 的 $ce-IAMEmployeeAccess 及 presenter
        // categoryRule .fromClass(withPrefix: "IAM_") 對齊。原 codegen 產 "IAMC"（誤取 IAMContext 大寫字母）
        // → 寫入落在 $ce-IAMCEmployeeAccess、projection 訂 $ce-IAMEmployeeAccess → 事件流不到 projector、read model 永遠空。
        "IAM\(Self.self)"
    }

    // 入職 placeholder（human-authorized 2026-06-03）：權限細項未規劃 → 新人先給「全部權限」。
    // 來源改為「衍生自聚合 catalog」（PermissionCatalog，由 IAMPermissionCatalog target 內各 context 的
    // *.permissions.yaml 快照在 build 時產出），不再手抄 OC 清單 —— OC 改 slot 命名 / 增減權限時，只要重 sync
    // 那份 yaml，這裡就自動跟著更新、永不漂移（先前手抄版會落後，例如 OC 把 Query/Workflow 改成 module 名）。
    // 範圍＝OpportunityContext（維持原本「給 OC 全權限」的行為；是否納入 EPC 等其他 context 另議）。
    // TODO: 待 permission 方案定案後，依 (department, jobTitle) 推導真正 baseline，取代「全給」。
    package static let allPermissions: Set<String> =
        Set(PermissionCatalog.permissions(inContext: "OpportunityContext").map(\.rawValue))

    package init(id: String, userId: String, department: String, jobTitle: String, permissions: Set<String>, roles: Set<String>, status: EmployeeStatus) throws {
        self.id = id
        self.userId = userId
        self.department = department
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
            occurred: .now
        )
        try self.apply(event: event)
    }
    // Create entry point used by the create use-case (/usecase Create pattern). The use-case Input does
    // NOT carry non-input createdEvent payload field(s) [permissions, roles, status], so deriving them is domain logic.
    package convenience init(id: String, userId: String, department: String, jobTitle: String) throws {
        // domain-fill placeholder (human-authorized 2026-06-03)：權限細項未規劃 → 新人先給「全部權限」、roles 空集合、status .Active。
        // TODO: 待 permission 方案定案後，依 (department, jobTitle) 推導真正的 permissions / roles。
        try self.init(
            id: id,
            userId: userId,
            department: department,
            jobTitle: jobTitle,
            permissions: Self.allPermissions,
            roles: [],
            status: .Active
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
            status: createdEvent.status
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
