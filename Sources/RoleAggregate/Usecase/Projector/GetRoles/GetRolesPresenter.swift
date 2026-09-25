import DDDCore
import EventSourcing
import KurrentSupport
import IAMContextShared


package struct GetRolesInput: CQRSProjectorInput {
    /// id 固定對應 KDB stream `IAM_GetRoles-all`。
    package let id: String = "all"

    package init() {}
}

package struct GetRolesPresenter: GetRolesProjectorProtocol {
    package typealias Input = GetRolesInput
    package typealias StorageCoordinator = KurrentStorageCoordinator<Self>
    package typealias ReadModelType = RolesReadModel

    /// 讀取 `IAM_GetRoles-all` stream，前綴 `IAM_` 必須與 projection linkTo 保持一致。
    package static var categoryRule: StreamCategoryRule { .fromClass(withPrefix: "IAM_") }

    package var coordinator: KurrentStorageCoordinator<GetRolesPresenter>

    package init(coordinator: KurrentStorageCoordinator<GetRolesPresenter>) {
        self.coordinator = coordinator
    }

    package func buildReadModel(input: Input) throws -> RolesReadModel? {
        _ = input
        return .init()
    }

    package func when(readModel: inout ReadModelType, event: RoleCreated) throws {
        readModel.roles.append(
            RoleSummary(
                roleId: event.roleId,
                name: event.name,
                description: event.description
            )
        )
    }

    package func when(readModel: inout ReadModelType, event: RoleRenamed) throws {
        guard let index = readModel.roles.firstIndex(where: { $0.roleId == event.roleId }) else { return }
        readModel.roles[index].name = event.newName
    }

    package func when(readModel: inout ReadModelType, event: RoleDescriptionUpdated) throws {
        guard let index = readModel.roles.firstIndex(where: { $0.roleId == event.roleId }) else { return }
        readModel.roles[index].description = event.newDescription
    }

    package func when(readModel: inout ReadModelType, event: RolePermissionsAdded) throws {
        guard let index = readModel.roles.firstIndex(where: { $0.roleId == event.roleId }) else { return }
        for permission in event.permissions where !readModel.roles[index].permissions.contains(permission) {
            readModel.roles[index].permissions.append(permission)
        }
    }

    package func when(readModel: inout ReadModelType, event: RolePermissionsRemoved) throws {
        guard let index = readModel.roles.firstIndex(where: { $0.roleId == event.roleId }) else { return }
        readModel.roles[index].permissions.removeAll { event.permissions.contains($0) }
    }

    package func when(readModel: inout ReadModelType, event: RoleDeleted) throws {
        readModel.roles.removeAll { $0.roleId == event.aggregateRootId }
    }
}
