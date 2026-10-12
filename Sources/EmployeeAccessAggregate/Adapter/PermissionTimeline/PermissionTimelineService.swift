import DDDKit
import Foundation
import KurrentDB
import IAMContextShared

package struct PermissionTimelineService: EffectivePermissionsReader {
    private let kdbClient: KurrentDBClient
    private let roleDirectory: RoleDirectory

    package init(kdbClient: KurrentDBClient, roleDirectory: RoleDirectory) {
        self.kdbClient = kdbClient
        self.roleDirectory = roleDirectory
    }

    package func effectivePermissions(userIds: [String]) async throws -> [String: Set<String>] {
        var employeeEntries: [String: [TimelineEntry]] = [:]
        for userId in userIds {
            let streamName = GetPermissionsPresenter.getStreamName(id: userId)
            if let entries = try await readEmployeeEntries(streamName: streamName, resolveLinks: true) {
                employeeEntries[userId] = entries
            }
        }
        return try await replayAll(employeeEntries)
    }

    package func effectivePermissions(userId: String) async throws -> Set<String>? {
        try await effectivePermissions(userIds: [userId])[userId]
    }

    package func effectivePermissions(employeeAccessId: String) async throws -> Set<String> {
        let streamName = EmployeeAccess.getStreamName(id: employeeAccessId)
        guard let entries = try await readEmployeeEntries(streamName: streamName, resolveLinks: false) else { return [] }
        return try await replayAll([employeeAccessId: entries])[employeeAccessId] ?? []
    }

    package func candidateUserIds(permission: String) async throws -> [String] {
        let holdersPresenter = GetPermissionHoldersPresenter(
            coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
        )
        var granted: [String] = []
        if let fetched = try await holdersPresenter.coordinator.fetchEvents(byId: permission) {
            for case let event as PrivilegeGranted in fetched.events where !granted.contains(event.userId) {
                granted.append(event.userId)
            }
        }

        let roleIds = try await roleDirectory.rolesEverContaining(permission: permission)
        var viaRoles: Set<String> = []
        if !roleIds.isEmpty {
            let roleHoldersPresenter = GetRoleHoldersPresenter(
                coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
            )
            for roleId in roleIds.sorted() {
                guard let fetched = try await roleHoldersPresenter.coordinator.fetchEvents(byId: roleId) else { continue }
                for case let event as RolesAssigned in fetched.events where event.roles.contains(roleId) {
                    viaRoles.insert(event.userId)
                }
            }
        }
        return granted + viaRoles.subtracting(granted).sorted()
    }

    private func replayAll(_ employeeEntries: [String: [TimelineEntry]]) async throws -> [String: Set<String>] {
        let mentioned = employeeEntries.mapValues { PermissionTimeline.mentionedRoleIds(in: $0) }
        let allRoleIds = mentioned.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        var roleEntries: [TimelineEntry] = []
        if !allRoleIds.isEmpty {
            roleEntries = try await roleDirectory.history(ofRoles: allRoleIds)
        }
        var result: [String: Set<String>] = [:]
        for (key, entries) in employeeEntries {
            let mine = mentioned[key] ?? []
            let relevant = roleEntries.filter { entry in entry.event.roleId.map { mine.contains($0) } ?? false }
            result[key] = PermissionTimeline.replay(entries + relevant)
        }
        return result
    }

    private func readEmployeeEntries(streamName: String, resolveLinks: Bool) async throws -> [TimelineEntry]? {
        let mapper = EmployeeAccessAggregateEventMapper()
        var entries: [TimelineEntry] = []
        var sawEvent = false
        do {
            let responses = try await kdbClient.streams(specified: streamName).read {
                $0.direction = .forward
                $0.revision = .start
                $0.resolveLinks = resolveLinks
            }
            for try await response in responses {
                guard case let .event(readEvent) = response else {
                    throw PermissionTimelineError.unresolvableEvent(stream: streamName)
                }
                sawEvent = true
                let record = readEvent.record
                guard let event = try mapper.mapping(eventData: record) else {
                    throw PermissionTimelineError.unmappedEvent(stream: streamName, eventType: record.eventType)
                }
                let position = LogPosition(commit: record.position.commit, prepare: record.position.prepare)
                switch event {
                case let created as UserAccessProfileCreated:
                    entries.append(.init(position: position, event: .profileCreated(permissions: created.permissions, roles: created.roles)))
                case let granted as PrivilegeGranted:
                    entries.append(.init(position: position, event: .privilegeGranted(permissions: Set(granted.permissions))))
                case let revoked as PrivilegeRevoked:
                    entries.append(.init(position: position, event: .privilegeRevoked(permissions: Set(revoked.permissions))))
                case let assigned as RolesAssigned:
                    entries.append(.init(position: position, event: .rolesAssigned(roleIds: Set(assigned.roles))))
                case let revokedRoles as RolesRevoked:
                    entries.append(.init(position: position, event: .rolesRevoked(roleIds: Set(revokedRoles.roles))))
                case is UserPromoted, is DepartmentTransferred, is EmployeeAccessDeleted:
                    continue
                default:
                    throw PermissionTimelineError.unhandledEvent(stream: streamName, eventType: record.eventType)
                }
            }
        } catch KurrentError.resourceNotFound(_) {
            return nil
        }
        return sawEvent ? entries : nil
    }
}
