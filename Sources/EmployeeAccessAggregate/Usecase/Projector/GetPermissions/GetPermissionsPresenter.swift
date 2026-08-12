import DDDCore
import EventSourcing
import KurrentSupport
import IAMContextShared


package struct GetPermissionsInput: CQRSProjectorInput {
    package let id: String

    package init(userId: String) {
        self.id = userId
    }
}

package struct GetPermissionsPresenter: GetPermissionsProjectorProtocol {
    package typealias Input = GetPermissionsInput
    package typealias StorageCoordinator = KurrentStorageCoordinator<Self>
    package typealias ReadModelType = PermissionsReadModel
    package static var categoryRule: StreamCategoryRule { .fromClass(withPrefix: "IAM_") }

    package var coordinator: KurrentStorageCoordinator<GetPermissionsPresenter>

    package init(coordinator: KurrentStorageCoordinator<GetPermissionsPresenter>) {
        self.coordinator = coordinator
    }

    package func buildReadModel(input: Input) throws -> PermissionsReadModel? {
        return .init(userId: input.id)
    }

    package func when(readModel: inout ReadModelType, event: PrivilegeGranted) throws {
        // hand-fill (human-authorized 2026-06-03): 聯集加入新權限（去重、保留順序）。
        var permissions = readModel.permissions ?? []
        for permission in event.permissions where !permissions.contains(permission) {
            permissions.append(permission)
        }
        readModel.permissions = permissions
    }

    package func when(readModel: inout ReadModelType, event: PrivilegeRevoked) throws {
        // hand-fill (human-authorized 2026-06-03): 差集移除被撤銷的權限。
        readModel.permissions = (readModel.permissions ?? []).filter { !event.permissions.contains($0) }
    }

    package func when(readModel: inout ReadModelType, event: RolesAssigned) throws {
        // hand-fill (human-authorized 2026-06-03): no-op — GetPermissions read model 只投影 permissions，不追蹤 roles。
        _ = readModel
        _ = event
    }

    package func when(readModel: inout ReadModelType, event: RolesRevoked) throws {
        // hand-fill (human-authorized 2026-06-03): no-op — GetPermissions read model 只投影 permissions，不追蹤 roles。
        _ = readModel
        _ = event
    }

    package func when(readModel: inout ReadModelType, event: UserPromoted) throws {
        // hand-fill (human-authorized 2026-06-03): no-op — GetPermissions read model 只投影 permissions，不追蹤 jobTitle。
        _ = readModel
        _ = event
    }

    package func when(readModel: inout ReadModelType, event: DepartmentTransferred) throws {
        // 追蹤部門變動，讓 department 欄位反映最新部門（供 GetPermissionHolders 的 department 過濾使用）。
        readModel.department = event.newDepartment
        // 若轉調事件帶 newFirm，同步更新所別。
        if let newFirm = event.newFirm {
            readModel.firm = newFirm
        }
    }

    package func when(readModel: inout ReadModelType, event: UserAccessProfileCreated) throws {
        // hand-fill (human-authorized 2026-06-03): anchor — 設定身分欄位 + 初始 permissions（Set → Array）。
        readModel.employeeAccessId = event.employeeAccessId
        readModel.userId = event.userId
        readModel.permissions = Array(event.permissions)
        readModel.department = event.department
        readModel.firm = event.firm
    }
}
