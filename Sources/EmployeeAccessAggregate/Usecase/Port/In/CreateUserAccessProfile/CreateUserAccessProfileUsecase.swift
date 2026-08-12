import DDDKit
import IAMContextShared

package protocol CreateUserAccessProfileUsecase: Usecase where Input == CreateUserAccessProfileInput, Output == CreateUserAccessProfileOutput {
    var repository: EmployeeAccessRepository { get }
}

extension CreateUserAccessProfileUsecase {
    package func execute(input: CreateUserAccessProfileInput) async throws -> CreateUserAccessProfileOutput {
        do {
            // DUPLICATE GUARD (code review 2026-06-12): KurrentStorageCoordinator.append 對新 aggregate（version==nil）
            // 用 expectedRevision = .any，重複 create 會把第二個 UserAccessProfileCreated 直接 append 進既有 stream →
            // 事件流出現兩個 createdEvent（污染重播）。先檢查 stream 是否已存在（含 soft-deleted，故 hiddingDeleted:false，
            // 避免在已刪除的 stream 上再 append create），存在即擋。
            if try await repository.find(byId: input.employeeAccessId, hiddingDeleted: false) != nil {
                throw ContextError<EmployeeAccessError>.profileAlreadyExists(function: #function, message: "a profile already exists for employeeAccessId \(input.employeeAccessId)")
            }
            // FIRM GUARD (human-authorized 2026-08-05): firm 必填——nil 或空字串都拒絕。
            // 注意：event/aggregate 的 firm 保持 String?（舊事件相容），驗證只在建檔入口做。
            guard let firm = input.firm, !firm.isEmpty else {
                throw ContextError<EmployeeAccessError>.firmRequired(function: #function, message: "firm must be present and non-empty when creating a profile")
            }
            let employeeAccess = try EmployeeAccess(id: input.employeeAccessId, userId: input.userId, department: input.department, jobTitle: input.jobTitle, firm: firm)
            try await repository.save(aggregateRoot: employeeAccess, userId: input.operatorId)
            return .init(id: employeeAccess.id, message: nil)
        } catch let error as ContextError<EmployeeAccessError> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
    }
}
