import DDDCore
import EventSourcing
import KurrentSupport
import IAMContextShared


package struct GetRoleHoldersInput: CQRSProjectorInput {
    /// id 對應 KDB stream `IAM_GetRoleHolders-<roleId>`。
    package let id: String

    package init(role: String) {
        self.id = role
    }
}

package struct GetRoleHoldersPresenter: GetRoleHoldersProjectorProtocol {
    package typealias Input = GetRoleHoldersInput
    package typealias StorageCoordinator = KurrentStorageCoordinator<Self>
    package typealias ReadModelType = RoleHoldersReadModel

    /// 讀取 `IAM_GetRoleHolders-<roleId>` stream，前綴 `IAM_` 與 GetPermissionHolders 一致。
    package static var categoryRule: StreamCategoryRule { .fromClass(withPrefix: "IAM_") }

    package var coordinator: KurrentStorageCoordinator<GetRoleHoldersPresenter>

    package init(coordinator: KurrentStorageCoordinator<GetRoleHoldersPresenter>) {
        self.coordinator = coordinator
    }

    package func buildReadModel(input: Input) throws -> RoleHoldersReadModel? {
        return .init(role: input.id)
    }

    package func when(readModel: inout ReadModelType, event: RolesAssigned) throws {
        // 聯集加入：userId 尚未在清單中才加入（防重）。
        if !readModel.userIds.contains(event.userId) {
            readModel.userIds.append(event.userId)
        }
    }

    package func when(readModel: inout ReadModelType, event: RolesRevoked) throws {
        // 差集移除：若 revoke 事件的 roles 包含本 stream 對應的 role，移除該 userId。
        if event.roles.contains(readModel.role) {
            readModel.userIds.removeAll { $0 == event.userId }
        }
    }
}
