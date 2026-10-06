import Foundation

/// KurrentDB 全域日誌位置（`$all` 的排序鍵）。P-a：client 的 `StreamPosition` 只有 Equatable，排序鍵自己定義。
/// 全序：先比 commit、再比 prepare（字典序，與 `$all` 自己的排序一致）。
package struct LogPosition: Sendable, Hashable, Comparable {
    package let commit: UInt64
    package let prepare: UInt64

    package init(commit: UInt64, prepare: UInt64) {
        self.commit = commit
        self.prepare = prepare
    }

    package static func < (lhs: LogPosition, rhs: LogPosition) -> Bool {
        (lhs.commit, lhs.prepare) < (rhs.commit, rhs.prepare)
    }
}

/// 時間軸上的一個事件的中性表示（不含 codegen 事件型別，可跨 target 傳遞）。
/// 員工事件（前 5 個）與角色事件（後 4 個）併在同一個 enum，讓引擎只面對一種輸入。
/// 不影響權限的事件型別——員工側 `UserPromoted`／`DepartmentTransferred`／`EmployeeAccessDeleted`、
/// 角色側 `RoleRenamed`／`RoleDescriptionUpdated`——由讀取端在 `switch` 裡**逐一列名忽略**，不進時間軸；
/// 型別若既不在「處理」也不在「明確忽略」清單（例如日後新增的事件），讀取端拋 `PermissionTimelineError.unhandledEvent`。
package enum TimelineEvent: Sendable, Equatable {
    // EmployeeAccess stream
    case profileCreated(permissions: Set<String>, roles: Set<String>)
    case privilegeGranted(permissions: Set<String>)
    case privilegeRevoked(permissions: Set<String>)
    case rolesAssigned(roleIds: Set<String>)
    case rolesRevoked(roleIds: Set<String>)
    // Role stream
    case roleCreated(roleId: String)
    case rolePermissionsAdded(roleId: String, permissions: Set<String>)
    case rolePermissionsRemoved(roleId: String, permissions: Set<String>)
    case roleDeleted(roleId: String)
}

package struct TimelineEntry: Sendable, Equatable {
    /// 原始事件的全域位置（P-a：link 事件取 `record` 的位置，不是 link 自己的位置）。
    package let position: LogPosition
    package let event: TimelineEvent

    package init(position: LogPosition, event: TimelineEvent) {
        self.position = position
        self.event = event
    }
}

/// 時間軸讀取的 fail-closed 錯誤（`[inferred]` I-5、I-12）：權限系統寧可 503／gRPC aborted，也不猜測。
/// 讀取端（`RoleAggregateDirectory.history`、`PermissionTimelineService.readEmployeeEntries`）共用。
package enum PermissionTimelineError: Error, Sendable, Equatable {
    /// 讀取回應不是可用事件（`Streams.ReadResponse.unserviceable`：link 指向的原始事件已不存在或無法解析）。
    case unresolvableEvent(stream: String)
    /// `EventTypeMapper.mapping` 回 `nil`：eventType 不在對照表，或內容不是 JSON。
    case unmappedEvent(stream: String, eventType: String)
    /// mapper 解得出、但既不是時間軸要處理、也不在「明確忽略」清單的事件型別。
    case unhandledEvent(stream: String, eventType: String)
}

extension TimelineEvent {
    /// role 事件所屬的 roleId；員工事件回 nil。
    package var roleId: String? {
        switch self {
        case let .roleCreated(roleId),
             let .rolePermissionsAdded(roleId, _),
             let .rolePermissionsRemoved(roleId, _),
             let .roleDeleted(roleId):
            return roleId
        case .profileCreated, .privilegeGranted, .privilegeRevoked, .rolesAssigned, .rolesRevoked:
            return nil
        }
    }
}

package enum PermissionTimeline {
    /// 員工事件裡出現過的所有 roleId（建檔初始角色、曾被指派或撤銷的角色）——
    /// 這些角色的歷史都要讀（從角色建立開始，D2）。
    package static func mentionedRoleIds(in entries: [TimelineEntry]) -> Set<String> {
        var roleIds: Set<String> = []
        for entry in entries {
            switch entry.event {
            case let .profileCreated(_, roles):
                roleIds.formUnion(roles)
            case let .rolesAssigned(ids), let .rolesRevoked(ids):
                roleIds.formUnion(ids)
            case .privilegeGranted, .privilegeRevoked,
                 .roleCreated, .rolePermissionsAdded, .rolePermissionsRemoved, .roleDeleted:
                break   // 不列 default：日後新增 case 時編譯器會強迫這裡表態
            }
        }
        return roleIds
    }

    /// 重播：`entries` 可為任意順序（員工事件與角色事件混在一起），內部依 `(position, 輸入順序)` 排序。
    /// 規則見 §d。純函式、無 I/O。
    package static func replay(_ entries: [TimelineEntry]) -> Set<String> {
        var effective: Set<String> = []           // S：有效權限集合
        var held: Set<String> = []                // H：員工目前持有的 roleId
        var content: [String: Set<String>] = [:]  // C[r]：角色 r 重播到目前時間點的內容

        func contents(of roleIds: Set<String>) -> Set<String> {
            roleIds.reduce(into: Set<String>()) { $0.formUnion(content[$1] ?? []) }
        }

        let ordered = entries.enumerated()
            .sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }
            .map(\.element)

        for entry in ordered {
            switch entry.event {
            case let .profileCreated(permissions, roles):
                // 建檔是「重設起點」，不是加入：同一個 userId 若被建檔兩次（例如重新匯入），
                // 後一次建檔取代先前的權限與持有角色。與 1.4.0 GetPermissionsPresenter 覆寫
                // readModel.permissions 的行為一致（2026-10-01 部署前檢查發現，開發環境 354 人有兩筆建檔）。
                held = roles
                effective = permissions.union(contents(of: roles))
            case let .privilegeGranted(permissions):
                effective.formUnion(permissions)
            case let .privilegeRevoked(permissions):
                effective.subtract(permissions)
            case let .rolesAssigned(roleIds):
                held.formUnion(roleIds)
                effective.formUnion(contents(of: roleIds))
            case let .rolesRevoked(roleIds):
                let removing = held.intersection(roleIds)
                held.subtract(removing)
                effective.subtract(contents(of: removing).subtracting(contents(of: held)))
            case let .roleCreated(roleId):
                content[roleId] = content[roleId] ?? []
            case let .rolePermissionsAdded(roleId, permissions):
                content[roleId, default: []].formUnion(permissions)
                if held.contains(roleId) { effective.formUnion(permissions) }
            case let .rolePermissionsRemoved(roleId, permissions):
                content[roleId, default: []].subtract(permissions)
                if held.contains(roleId) {
                    effective.subtract(permissions.subtracting(contents(of: held.subtracting([roleId]))))
                }
            case let .roleDeleted(roleId):
                let removed = content[roleId] ?? []
                content[roleId] = []
                if held.contains(roleId) {
                    effective.subtract(removed.subtracting(contents(of: held.subtracting([roleId]))))
                }
            }
        }
        return effective
    }
}
