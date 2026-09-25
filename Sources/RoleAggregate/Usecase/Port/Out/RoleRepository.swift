import DDDKit

package struct RoleRepository: EventSourcingRepository {
    package typealias AggregateRootType = Role
    package typealias StorageCoordinator = KurrentStorageCoordinator<Role>

    package let coordinator: StorageCoordinator

    package init(coordinator: StorageCoordinator) {
        self.coordinator = coordinator
    }
}
