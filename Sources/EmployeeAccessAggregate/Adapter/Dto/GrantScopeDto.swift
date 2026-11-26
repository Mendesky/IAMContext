import IAMContextShared

/// 授權範圍在 HTTP（openapi 產生的 Components.Schemas.GrantScope）與領域型別（IAMContextShared.GrantScope）之間的轉換。
extension GrantScope {
    package init(dto: Components.Schemas.GrantScope) {
        self.init(
            kind: dto.kind,
            firms: dto.firms,
            departments: dto.departments?.map { GrantScopeDepartment(firm: $0.firm, department: $0.department) }
        )
    }
}

extension Components.Schemas.GrantScope {
    package init(domain: GrantScope) {
        self.init(
            kind: domain.kind,
            firms: domain.firms,
            departments: domain.departments?.map { .init(firm: $0.firm, department: $0.department) }
        )
    }
}
