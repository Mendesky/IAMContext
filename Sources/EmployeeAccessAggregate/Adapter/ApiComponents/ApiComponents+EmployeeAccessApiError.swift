import IAMContextShared


extension Components.Schemas.EmployeeAccessApiError {
    // TODO: log unmapped domain error when project-wide logging is introduced.
    package init(from error: ContextError<EmployeeAccessError>) {
        self = .init(from: error.error) ?? .undefinedDomainError
    }

    package init?(from error: EmployeeAccessError) {
        switch error {
        case .userIdNotExist: self = .userIdNotExist
        case .permissionNotMatch: self = .permissionNotMatch
        case .employeeNotActive: self = .employeeNotActive
        // 2026-06-05: 已加進 openapi.yaml 的 EmployeeAccessApiError enum → 各自映射 → 走 422（不再 fallback 503）。
        case .permissionAlreadyExists: self = .permissionAlreadyExists
        case .permissionNotExist: self = .permissionNotExist
        case .roleAlreadyExists: self = .roleAlreadyExists
        case .roleNotExist: self = .roleNotExist
        case .departmentUnchanged: self = .departmentUnchanged
        // 2026-06-12: 整合性守門錯誤（code review 補洞）→ 客戶端錯誤，走 422。
        case .userIdMismatch: self = .userIdMismatch
        case .profileAlreadyExists: self = .profileAlreadyExists
        // 2026-08-05: 建檔必填欄位驗證（human-authorized）→ 客戶端錯誤，走 422。
        case .firmRequired: self = .firmRequired
        }
    }
}
