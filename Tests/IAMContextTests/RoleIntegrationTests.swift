import Testing
import DDDKit
import Foundation
import KurrentDB
import TestUtility
import EmployeeAccessAggregate
import IAMContextShared
import IAMPermissionCatalog
import RoleAggregate

@Suite(.serialized)
struct RoleIntegrationTests {
    let kdbClient: KurrentDBClient = makeTestKurrentDBClient()
    let roleRepository: RoleRepository
    let employeeAccessRepository: EmployeeAccessRepository

    init() {
        self.roleRepository = RoleRepository(
            coordinator: .init(client: kdbClient, eventMapper: RoleAggregateEventMapper())
        )
        self.employeeAccessRepository = EmployeeAccessRepository(
            coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
        )
    }

    @Test func create_returns_generated_uuid_roleId() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")

            let output = try await CreateRoleService(repository: roleRepository).execute(input: .init(
                name: await bundle.generateId(for: "roleName"),
                description: "Role for UUID generation test",
                operatorId: operatorId
            ))

            #expect(UUID(uuidString: output.roleId) != nil)
        }
    }

    @Test func create_add_remove_permissions_batch_roundtrip() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId)
            let permissions = catalogPermissions(count: 3)

            _ = try await AddPermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleId,
                permissions: permissions,
                operatorId: operatorId
            ))
            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleId,
                permissions: Array(permissions.prefix(2)),
                operatorId: operatorId
            ))

            let remaining = try await GetRolePermissionsApplicationService(repository: roleRepository).execute(input: .init(roleId: roleId))
            #expect(Set(remaining) == Set([permissions[2]]))
        }
    }

    @Test func rename_updates_name_and_noop_rename_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId)
            let newName = await bundle.generateId(for: "newRoleName")
            let service = RenameRoleService(repository: roleRepository)

            _ = try await service.execute(input: .init(roleId: roleId, newName: newName, operatorId: operatorId))
            let role = try #require(try await roleRepository.find(byId: roleId))
            #expect(role.name == newName)

            let error = await #expect(throws: ContextError<RoleError>.self) {
                let _: RenameRoleOutput = try await service.execute(input: .init(
                    roleId: roleId,
                    newName: newName,
                    operatorId: operatorId
                ))
            }
            #expect(error?.error == .roleNameUnchanged)
        }
    }

    @Test func update_description_roundtrip_and_noop_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, description: "Initial description")
            let service = UpdateRoleDescriptionService(repository: roleRepository)

            _ = try await service.execute(input: .init(
                roleId: roleId,
                newDescription: "Updated description",
                operatorId: operatorId
            ))
            let role = try #require(try await roleRepository.find(byId: roleId))
            #expect(role.description == "Updated description")

            let error = await #expect(throws: ContextError<RoleError>.self) {
                let _: UpdateRoleDescriptionOutput = try await service.execute(input: .init(
                    roleId: roleId,
                    newDescription: "Updated description",
                    operatorId: operatorId
                ))
            }
            #expect(error?.error == .descriptionUnchanged)
        }
    }

    @Test func add_batch_with_invalid_permission_rejects_whole_batch() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId)
            let validPermission = catalogPermissions(count: 1)[0]

            let error = await #expect(throws: ContextError<RoleError>.self) {
                let _: AddPermissionsOutput = try await AddPermissionsService(repository: roleRepository).execute(input: .init(
                    roleId: roleId,
                    permissions: [validPermission, "Nope.Not.Real"],
                    operatorId: operatorId
                ))
            }
            #expect(error?.error == .invalidPermission)

            let permissions = try await GetRolePermissionsApplicationService(repository: roleRepository).execute(input: .init(roleId: roleId))
            #expect(permissions.isEmpty)
        }
    }

    @Test func add_batch_net_empty_throws_permissionsUnchanged() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId)
            let permissions = catalogPermissions(count: 2)
            let service = AddPermissionsService(repository: roleRepository)

            _ = try await service.execute(input: .init(roleId: roleId, permissions: permissions, operatorId: operatorId))
            let error = await #expect(throws: ContextError<RoleError>.self) {
                let _: AddPermissionsOutput = try await service.execute(input: .init(
                    roleId: roleId,
                    permissions: permissions,
                    operatorId: operatorId
                ))
            }
            #expect(error?.error == .permissionsUnchanged)
        }
    }

    @Test func remove_partial_batch_removes_only_present() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId)
            let permissions = catalogPermissions(count: 3)

            _ = try await AddPermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleId,
                permissions: Array(permissions.prefix(2)),
                operatorId: operatorId
            ))
            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleId,
                permissions: [permissions[0], permissions[2]],
                operatorId: operatorId
            ))

            let remaining = try await GetRolePermissionsApplicationService(repository: roleRepository).execute(input: .init(roleId: roleId))
            #expect(Set(remaining) == Set([permissions[1]]))
        }
    }

    @Test func deleted_role_returns_notFound_on_getRolePermissions() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId)

            _ = try await DeleteRoleService(repository: roleRepository).execute(input: .init(roleId: roleId, operatorId: operatorId))
            let error = await #expect(throws: DDDError.self) {
                let _: [String] = try await GetRolePermissionsApplicationService(repository: roleRepository).execute(input: .init(roleId: roleId))
            }
            #expect(error?.code == .aggregateNotFound)
        }
    }

    @Test func getRoles_reflects_create_rename_permissions_delete() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let name = await bundle.generateId(for: "roleName")
            let renamed = await bundle.generateId(for: "renamedRoleName")
            let permissions = catalogPermissions(count: 2)
            let getRoles = GetRolesApplicationService(kdbClient: kdbClient)

            let created = try await CreateRoleService(repository: roleRepository).execute(input: .init(
                name: name,
                description: "Visible description",
                operatorId: operatorId
            ))
            try await waitForProjection()
            var role = try #require(try await roleSummary(roleId: created.roleId, service: getRoles))
            #expect(role.name == name)
            #expect(role.description == "Visible description")

            _ = try await AddPermissionsService(repository: roleRepository).execute(input: .init(
                roleId: created.roleId,
                permissions: permissions,
                operatorId: operatorId
            ))
            try await waitForProjection()
            role = try #require(try await roleSummary(roleId: created.roleId, service: getRoles))
            #expect(Set(role.permissions) == Set(permissions))

            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(
                roleId: created.roleId,
                permissions: [permissions[0]],
                operatorId: operatorId
            ))
            try await waitForProjection()
            role = try #require(try await roleSummary(roleId: created.roleId, service: getRoles))
            #expect(Set(role.permissions) == Set([permissions[1]]))

            _ = try await RenameRoleService(repository: roleRepository).execute(input: .init(
                roleId: created.roleId,
                newName: renamed,
                operatorId: operatorId
            ))
            try await waitForProjection()
            role = try #require(try await roleSummary(roleId: created.roleId, service: getRoles))
            #expect(role.name == renamed)

            _ = try await DeleteRoleService(repository: roleRepository).execute(input: .init(
                roleId: created.roleId,
                operatorId: operatorId
            ))
            try await waitForProjection()
            let deleted = try await roleSummary(roleId: created.roleId, service: getRoles)
            #expect(deleted == nil)
        }
    }

    @Test func create_duplicate_name_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let name = await bundle.generateId(for: "roleName")
            let service = CreateRoleApplicationService(repository: roleRepository, kdbClient: kdbClient)

            _ = try await service.execute(input: .init(name: name, description: nil, operatorId: operatorId))
            try await waitForProjection()

            let error = await #expect(throws: ContextError<RoleError>.self) {
                let _: CreateRoleOutput = try await service.execute(input: .init(
                    name: name,
                    description: "Duplicate",
                    operatorId: operatorId
                ))
            }
            #expect(error?.error == .roleNameDuplicated)
        }
    }

    @Test func assign_then_revoke_roles_reflects_in_role_holders() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId)
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")

            try await seedActiveProfile(
                employeeAccessId: employeeAccessId,
                userId: userId,
                operatorId: operatorId,
                repository: employeeAccessRepository
            )

            _ = try await AssignRolesService(repository: employeeAccessRepository, roleDirectory: FakeRoleDirectory()).execute(input: .init(
                employeeAccessId: employeeAccessId,
                userId: userId,
                roles: [roleId],
                operatorId: operatorId
            ))
            try await waitForProjection()

            let service = GetRoleHoldersApplicationService(kdbClient: kdbClient)
            var holders = try await service.execute(input: .init(role: roleId))
            #expect(holders.contains(userId))

            _ = try await RevokeRolesService(repository: employeeAccessRepository).execute(input: .init(
                employeeAccessId: employeeAccessId,
                userId: userId,
                roles: [roleId],
                operatorId: operatorId
            ))
            try await waitForProjection()

            holders = try await service.execute(input: .init(role: roleId))
            #expect(!holders.contains(userId))
        }
    }

    @Test func role_holders_unknown_role_returns_empty() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let unknownRole = await bundle.generateId(for: "unknownRole")
            let holders = try await GetRoleHoldersApplicationService(kdbClient: kdbClient).execute(input: .init(role: unknownRole))
            #expect(holders.isEmpty)
        }
    }

    private func createRole(
        bundle: TestBundle,
        operatorId: String,
        description: String? = nil
    ) async throws -> String {
        let output = try await CreateRoleService(repository: roleRepository).execute(input: .init(
            name: await bundle.generateId(for: "roleName"),
            description: description,
            operatorId: operatorId
        ))
        return output.roleId
    }

    private func catalogPermissions(count: Int) -> [String] {
        Array(PermissionCatalog.allRawValues.sorted().prefix(count))
    }

    private func waitForProjection() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    private func roleSummary(
        roleId: String,
        service: GetRolesApplicationService
    ) async throws -> RoleSummary? {
        let output = try await service.execute(input: .init())
        return output.roles.first { $0.roleId == roleId }
    }
}
