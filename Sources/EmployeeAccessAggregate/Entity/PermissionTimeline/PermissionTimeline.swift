import Foundation
import IAMContextShared

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
    /// `grantScopes`：範圍化權限授予時帶的範圍（2026-11-25 設計文件 D12）；舊事件、不是範圍化的權限沒有。
    case privilegeGranted(permissions: Set<String>, grantScopes: [String: [GrantScope]] = [:])
    case privilegeRevoked(permissions: Set<String>)
    /// 改範圍（2026-11-26 設計文件 D12）：只換範圍，不改有效權限。
    case privilegeScopeChanged(permission: String, grantScopes: [GrantScope])
    case rolesAssigned(roleIds: Set<String>)
    case rolesRevoked(roleIds: Set<String>)
    // Role stream
    case roleCreated(roleId: String)
    case rolePermissionsAdded(roleId: String, permissions: Set<String>)
    case rolePermissionsRemoved(roleId: String, permissions: Set<String>)
    case roleDeleted(roleId: String)
}

/// 重播結果：有效權限，以及其中範圍化權限的授權範圍。
package struct EffectiveAccess: Sendable, Equatable {
    package let permissions: Set<String>
    /// 有效權限裡、直接授予時帶了範圍的權限 → 範圍清單。
    package let grantScopes: [String: [GrantScope]]

    package init(permissions: Set<String>, grantScopes: [String: [GrantScope]] = [:]) {
        self.permissions = permissions
        self.grantScopes = grantScopes
    }
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
        case .profileCreated, .privilegeGranted, .privilegeRevoked, .privilegeScopeChanged, .rolesAssigned, .rolesRevoked:
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
            case .privilegeGranted, .privilegeRevoked, .privilegeScopeChanged,
                 .roleCreated, .rolePermissionsAdded, .rolePermissionsRemoved, .roleDeleted:
                break   // 不列 default：日後新增 case 時編譯器會強迫這裡表態
            }
        }
        return roleIds
    }

    /// 重播：`entries` 可為任意順序（員工事件與角色事件混在一起），內部依 `(position, 輸入順序)` 排序。
    /// 規則見 §d。純函式、無 I/O。結果與 `replayAccess(_:).permissions` 相同。
    package static func replay(_ entries: [TimelineEntry]) -> Set<String> {
        replayAccess(entries).permissions
    }

    /// 重播出有效權限，以及其中範圍化權限的授權範圍（2026-11-25 設計文件 D12）。
    /// 範圍只來自直接授予（角色不能放範圍化的權限，D13），規則：
    /// - 建檔：範圍清空（建檔是重設起點）。
    /// - 授予 p：帶了範圍就記下（覆蓋），沒帶就清掉。
    /// - 撤銷 p（不論來源）：範圍一起拿掉。
    /// - 改範圍：p 仍有效時換成新範圍；p 已經不是有效權限時不理（指令會擋，這裡防禦）。
    /// - 最後只保留仍是有效權限的範圍。
    /// 範圍原樣保留（含不認得的種類）；略過不認得的種類是查詢端的事。
    package static func replayAccess(_ entries: [TimelineEntry]) -> EffectiveAccess {
        var effective: Set<String> = []           // S：有效權限集合
        var scopes: [String: [GrantScope]] = [:]  // 直接授予時帶的範圍
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
                scopes = [:]
            case let .privilegeGranted(permissions, grantScopes):
                effective.formUnion(permissions)
                for permission in permissions {
                    scopes[permission] = grantScopes[permission]
                }
            case let .privilegeRevoked(permissions):
                effective.subtract(permissions)
                for permission in permissions {
                    scopes[permission] = nil
                }
            case let .privilegeScopeChanged(permission, grantScopes):
                if effective.contains(permission) {
                    scopes[permission] = grantScopes
                }
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
        return EffectiveAccess(permissions: effective, grantScopes: scopes.filter { effective.contains($0.key) })
    }
}
