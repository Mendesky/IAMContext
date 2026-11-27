import IAMContextShared

/// 授權範圍在 HTTP（openapi 產生的 Components.Schemas.GrantScope）與領域型別（IAMContextShared.GrantScope）之間的轉換。
extension GrantScope {
    package init(dto: Components.Schemas.GrantScope) {
        self.init(type: dto._type, kind: dto.kind, values: dto.values)
    }
}

extension Components.Schemas.GrantScope {
    package init(domain: GrantScope) {
        self.init(_type: domain.type, kind: domain.kind, values: domain.values)
    }
}
