import DDDKit
import Foundation
import IAMContextShared

package class Role: RoleAggregateProtocol {
    package let id: String
    package var metadata: AggregateRootMetadata = .init()

    package var name: String?
    package var description: String?
    package var permissions: Set<String>?

    package static var category: String {
        "IAM\(Self.self)"
    }

    package init(id: String, name: String, description: String?, permissions: Set<String>) throws {
        self.id = id
        self.name = name
        self.description = description
        self.permissions = permissions
        let event = RoleCreated(
            roleId: id,
            name: name,
            description: description,
            occurred: .now
        )
        try self.apply(event: event)
    }

    package convenience init(name: String, description: String?) throws {
        try self.init(
            id: UUID().uuidString,
            name: name,
            description: description,
            permissions: []
        )
    }

    package required convenience init?(first createdEvent: RoleCreated, other events: [any DomainEvent]) throws {
        try self.init(
            id: createdEvent.roleId,
            name: createdEvent.name,
            description: createdEvent.description,
            permissions: []
        )
        try self.apply(events: events)
        try self.clearAllDomainEvents()
    }

    package func ensureInvariant() throws {
        guard let name, !name.isEmpty else {
            throw ContextError<RoleError>.roleNameRequired(function: #function, message: "role name must be present and non-empty")
        }
    }
}
