import DDDCore
import EventSourcing
import KurrentSupport
import IAMContextShared


package struct GetPermissionHoldersInput: CQRSProjectorInput {
    /// id 對應 KDB stream `IAM_PermissionHolders-<permission rawValue>`。
    package let id: String

    package init(permission: String) {
        self.id = permission
    }
}

package struct GetPermissionHoldersPresenter: GetPermissionHoldersProjectorProtocol {
    package typealias Input = GetPermissionHoldersInput
    package typealias StorageCoordinator = KurrentStorageCoordinator<Self>
    package typealias ReadModelType = PermissionHoldersReadModel

    /// 讀取 `IAM_PermissionHolders-<permission rawValue>` stream，前綴 `IAM_` 與 GetPermissions 一致。
    package static var categoryRule: StreamCategoryRule { .fromClass(withPrefix: "IAM_") }

    package var coordinator: KurrentStorageCoordinator<GetPermissionHoldersPresenter>

    package init(coordinator: KurrentStorageCoordinator<GetPermissionHoldersPresenter>) {
        self.coordinator = coordinator
    }

    package func buildReadModel(input: Input) throws -> PermissionHoldersReadModel? {
        return .init(permission: input.id)
    }

    package func when(readModel: inout ReadModelType, event: PrivilegeGranted) throws {
        // 聯集加入：userId 尚未在清單中才加入（防重）。
        if !readModel.userIds.contains(event.userId) {
            readModel.userIds.append(event.userId)
        }
    }

    package func when(readModel: inout ReadModelType, event: PrivilegeRevoked) throws {
        // 差集移除：若 revoke 事件的 permissions 包含本 stream 對應的 permission，移除該 userId。
        // 注意：PrivilegeRevoked.permissions 可能是批次移除多個，只要包含本 permission 即移除。
        if event.permissions.contains(readModel.permission) {
            readModel.userIds.removeAll { $0 == event.userId }
        }
    }
}
