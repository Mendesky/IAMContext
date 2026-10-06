import DDDKit
import Foundation
import KurrentDB
import IAMContextShared
import protocol EmployeeAccessAggregate.RoleDirectory
import struct EmployeeAccessAggregate.LogPosition
import struct EmployeeAccessAggregate.TimelineEntry
import enum EmployeeAccessAggregate.PermissionTimelineError

/// `RoleDirectory` 的生產實作（docs/tasks/permission-timeline-composition.md §b）。
///
/// - `resolve`：對每個 roleId rehydrate Role aggregate（強一致）；`find(byId:)` 對不存在／已刪除回 nil → 略過。
/// - `history`：直接讀角色原始 stream，提供權限時間軸重播所需事件（強一致）。
/// - `rolesEverContaining`：掃描 `IAM_GetRoles-all` 的新增權限事件，找出任何時候含過權限的角色（最終一致）。
///
/// 只持有 `KurrentDBClient`（Sendable），repository 與 presenter 每次呼叫時建立——
/// 與 ApiHandler 的 `repository` computed property 同一模式，避免把非 Sendable 的
/// `KurrentStorageCoordinator` 存進要跨 actor（PermissionsService）持有的值。
package struct RoleAggregateDirectory: RoleDirectory {
    private let kdbClient: KurrentDBClient

    package init(kdbClient: KurrentDBClient) {
        self.kdbClient = kdbClient
    }

    private var repository: RoleRepository {
        .init(coordinator: .init(client: kdbClient, eventMapper: RoleAggregateEventMapper()))
    }

    package func resolve(roleIds: Set<String>) async throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let repository = self.repository
        for roleId in roleIds {
            // 不存在／已刪除（repository.find 預設 hiddingDeleted）→ nil → 不進字典。
            guard let role = try await repository.find(byId: roleId) else { continue }
            result[roleId] = role.permissions ?? []
        }
        return result
    }

    package func history(ofRoles roleIds: Set<String>) async throws -> [TimelineEntry] {
        let mapper = RoleAggregateEventMapper()
        var entries: [TimelineEntry] = []
        for roleId in roleIds.sorted() {
            let streamName = Role.getStreamName(id: roleId)
            do {
                let responses = try await kdbClient.streams(specified: streamName).read {
                    $0.direction = .forward
                    $0.revision = .start
                }
                for try await response in responses {
                    guard case let .event(readEvent) = response else {
                        throw PermissionTimelineError.unresolvableEvent(stream: streamName)
                    }
                    let record = readEvent.record
                    guard let event = try mapper.mapping(eventData: record) else {
                        throw PermissionTimelineError.unmappedEvent(stream: streamName, eventType: record.eventType)
                    }
                    let position = LogPosition(commit: record.position.commit, prepare: record.position.prepare)
                    switch event {
                    case is RoleCreated:
                        entries.append(.init(position: position, event: .roleCreated(roleId: roleId)))
                    case let added as RolePermissionsAdded:
                        entries.append(.init(position: position, event: .rolePermissionsAdded(roleId: roleId, permissions: added.permissions)))
                    case let removed as RolePermissionsRemoved:
                        entries.append(.init(position: position, event: .rolePermissionsRemoved(roleId: roleId, permissions: removed.permissions)))
                    case is RoleDeleted:
                        entries.append(.init(position: position, event: .roleDeleted(roleId: roleId)))
                    case is RoleRenamed, is RoleDescriptionUpdated:
                        continue
                    default:
                        throw PermissionTimelineError.unhandledEvent(stream: streamName, eventType: record.eventType)
                    }
                }
            } catch KurrentError.resourceNotFound(_) {
                continue
            }
        }
        return entries
    }

    package func rolesEverContaining(permission: String) async throws -> Set<String> {
        let presenter = GetRolesPresenter(coordinator: .init(client: kdbClient, eventMapper: RoleAggregateEventMapper()))
        guard let fetched = try await presenter.coordinator.fetchEvents(byId: GetRolesInput().id) else { return [] }
        var roleIds: Set<String> = []
        for case let event as RolePermissionsAdded in fetched.events where event.permissions.contains(permission) {
            roleIds.insert(event.roleId)
        }
        return roleIds
    }

}
