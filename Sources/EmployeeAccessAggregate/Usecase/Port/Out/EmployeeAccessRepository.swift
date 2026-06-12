import DDDKit

package struct EmployeeAccessRepository: EventSourcingRepository {
    package typealias AggregateRootType = EmployeeAccess
    package typealias StorageCoordinator = KurrentStorageCoordinator<EmployeeAccess>

    package let coordinator: StorageCoordinator

    package init(coordinator: StorageCoordinator) {
        self.coordinator = coordinator
    }
}
