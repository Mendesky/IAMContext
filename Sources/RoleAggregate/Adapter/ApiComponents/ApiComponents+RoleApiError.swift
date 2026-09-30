import IAMContextShared

extension Components.Schemas.RoleApiError {
    package init(from error: ContextError<RoleError>) {
        self = .init(from: error.error) ?? .undefinedDomainError
    }

    package init?(from error: RoleError) {
        switch error {
        case .roleNameRequired: self = .roleNameRequired
        case .roleNameDuplicated: self = .roleNameDuplicated
        case .roleNameUnchanged: self = .roleNameUnchanged
        case .descriptionUnchanged: self = .descriptionUnchanged
        case .permissionsUnchanged: self = .permissionsUnchanged
        case .invalidPermission: self = .invalidPermission
        }
    }
}
