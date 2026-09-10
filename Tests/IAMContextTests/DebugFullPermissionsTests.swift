import Testing
import KurrentDB
import GRPCCore
import Generated
import EmployeeAccessAggregate
import IAMContextShared
import IAMPermissionCatalog
@testable import IAMContextServer

/// Unit tests for IAM_DEBUG_FULL_PERMISSIONS mode (no KDB connection required).
///
/// These tests exercise the service layer directly — no integration with KurrentDB.
/// The debug flag is injected via the `debugOverridePermissions` parameter so the
/// tests are hermetic and fast.
@Suite struct DebugFullPermissionsTests {

    // MARK: - GetPermissionsApplicationService

    /// debug on: any userId returns the full catalog (non-empty).
    @Test func service_debugOn_returnsFullCatalog() async throws {
        let fullCatalog = Array(PermissionCatalog.allRawValues).sorted()
        #expect(!fullCatalog.isEmpty, "catalog must have entries for this test to be meaningful")

        let kdbClient = makeTestKurrentDBClient()
        let sut = GetPermissionsApplicationService(
            kdbClient: kdbClient,
            debugOverridePermissions: fullCatalog
        )

        // Use an obviously unknown userId — should NOT hit KDB at all.
        let result = try await sut.execute(input: .init(userId: "debug-test-user-does-not-exist"))
        #expect(result == fullCatalog)
    }

    /// debug on: returns ALL catalog rawValues, including "holder marker" style permissions.
    @Test func service_debugOn_includesAllCatalogRawValues() async throws {
        let fullCatalog = Array(PermissionCatalog.allRawValues).sorted()
        let kdbClient = makeTestKurrentDBClient()
        let sut = GetPermissionsApplicationService(
            kdbClient: kdbClient,
            debugOverridePermissions: fullCatalog
        )

        let result = try await sut.execute(input: .init(userId: "any-user"))
        let resultSet = Set(result)
        let catalogSet = PermissionCatalog.allRawValues
        #expect(resultSet == catalogSet)
    }

    /// debug off: unknown userId still throws notFound (normal path unchanged).
    @Test func service_debugOff_unknownUser_throwsNotFound() async throws {
        let kdbClient = makeTestKurrentDBClient()
        let sut = GetPermissionsApplicationService(
            kdbClient: kdbClient,
            debugOverridePermissions: nil  // debug OFF
        )

        let error = await #expect(throws: ContextError<EmployeeAccessQueryError>.self) {
            let _: [String] = try await sut.execute(input: .init(userId: "non-existent-user-debug-off"))
        }
        #expect(error?.error == .notFound)
    }

    // MARK: - DebugConfig

    /// DebugConfig reads IAM_DEBUG_FULL_PERMISSIONS=1 correctly.
    @Test func debugConfig_envVarOn_fullPermissionsTrue() {
        let config = DebugConfig.fromEnvironment(["IAM_DEBUG_FULL_PERMISSIONS": "1"])
        #expect(config.fullPermissions == true)
    }

    /// DebugConfig is off by default (env var absent).
    @Test func debugConfig_envVarAbsent_fullPermissionsFalse() {
        let config = DebugConfig.fromEnvironment([:])
        #expect(config.fullPermissions == false)
    }

    /// DebugConfig: value "0" keeps it off.
    @Test func debugConfig_envVarZero_fullPermissionsFalse() {
        let config = DebugConfig.fromEnvironment(["IAM_DEBUG_FULL_PERMISSIONS": "0"])
        #expect(config.fullPermissions == false)
    }

    // MARK: - gRPC PermissionsService

    /// debug on (gRPC): any userId returns the full catalog with x-iam-debug header.
    @Test func grpc_debugOn_returnsFullCatalog() async throws {
        let kdbClient = makeTestKurrentDBClient()
        let sut = PermissionsService(
            kdbClient: kdbClient,
            debugConfig: DebugConfig(fullPermissions: true)
        )
        let request = ServerRequest<IAMContext_GetPermissionsRequest>(
            metadata: [:],
            message: .with { $0.userID = "any-user-grpc-debug" }
        )
        let ctx = ServerContext(
            descriptor: .init(fullyQualifiedService: "IAMContext.PermissionsService", method: "GetPermissions"),
            remotePeer: "test",
            localPeer: "test",
            cancellation: .init()
        )

        let response = try await sut.getPermissions(request: request, context: ctx)

        switch response.accepted {
        case .success(let contents):
            #expect(!contents.message.permissions.isEmpty)
            let catalogSet = PermissionCatalog.allRawValues
            let responseSet = Set(contents.message.permissions)
            #expect(responseSet == catalogSet)
            // x-iam-debug header should be set
            let debugHeaders = Array(contents.metadata[stringValues: "x-iam-debug"])
            #expect(debugHeaders.contains("1"))
        case .failure(let error):
            Issue.record("expected success with full catalog, got gRPC error: \(error)")
        }
    }

    /// debug off (gRPC): unknown userId returns empty success (existing behaviour preserved).
    @Test func grpc_debugOff_unknownUser_returnsEmptySuccess() async throws {
        let kdbClient = makeTestKurrentDBClient()
        let sut = PermissionsService(
            kdbClient: kdbClient,
            debugConfig: DebugConfig(fullPermissions: false)
        )
        let request = ServerRequest<IAMContext_GetPermissionsRequest>(
            metadata: [:],
            message: .with { $0.userID = "non-existent-user-grpc-off" }
        )
        let ctx = ServerContext(
            descriptor: .init(fullyQualifiedService: "IAMContext.PermissionsService", method: "GetPermissions"),
            remotePeer: "test",
            localPeer: "test",
            cancellation: .init()
        )

        let response = try await sut.getPermissions(request: request, context: ctx)

        switch response.accepted {
        case .success(let contents):
            #expect(contents.message.permissions.isEmpty)
        case .failure(let error):
            Issue.record("expected success with empty permissions, got gRPC error: \(error)")
        }
    }
}
