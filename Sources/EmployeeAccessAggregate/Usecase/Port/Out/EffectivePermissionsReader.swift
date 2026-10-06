package protocol EffectivePermissionsReader: Sendable {
    /// 以員工原始 stream（`IAMEmployeeAccess-<employeeAccessId>`，強一致、不經 projection）重播出的有效權限。
    /// stream 不存在回空集合。
    func effectivePermissions(employeeAccessId: String) async throws -> Set<String>
}
