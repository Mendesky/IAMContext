import Testing
import DDDKit
import KurrentDB
import TestUtility
import GRPCCore
import Generated
import EmployeeAccessAggregate
import IAMContextShared
@testable import IAMContextServer

// read-side 整合 test（透過 GetPermissionsApplicationService → GetPermissionsPresenter projector）。
// 註：read model 的資料來自 KDB projection（IAM_GetPermissionsProjection.js）。該 projection 未部署時，
//     任何 userId 的 per-user stream 皆空 → presenter 回 nil → notFound。
//     happy-path（回真 permissions）需 projection 部署 + 事件 ingest，屬 runtime infra，不在單元測試覆蓋。
@Suite(.serialized)
struct GetPermissionsIntegrationTests {
    let kdbClient: KurrentDBClient = makeTestKurrentDBClient()

    // 未知 userId（read-model stream 空）→ EmployeeAccessQueryError.notFound。
    @Test func get_permissions_unknown_user_throws_notFound() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let userId = await bundle.generateId(for: "userId")
            let service = GetPermissionsApplicationService(kdbClient: kdbClient, roleDirectory: FakeRoleDirectory())
            let error = await #expect(throws: ContextError<EmployeeAccessQueryError>.self) {
                let _: [String] = try await service.execute(input: .init(userId: userId))
            }
            #expect(error?.error == .notFound)
        }
    }

    // gRPC handler：未建檔員工（application service 拋 .notFound）→ 不回 gRPC error，
    // 改回成功、空權限清單，讓消費端能乾淨判定 deny→403（而非 fail-closed 502）。
    @Test func getPermissions_handler_unknown_user_returns_empty_success() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let userId = await bundle.generateId(for: "userId")
            let sut = PermissionsService(kdbClient: kdbClient, roleDirectory: FakeRoleDirectory())
            let request = ServerRequest<IAMContext_GetPermissionsRequest>(
                metadata: [:],
                message: .with { $0.userID = userId }
            )
            let ctx = ServerContext(
                descriptor: .init(fullyQualifiedService: "IAMContext.PermissionsService", method: "GetPermissions"),
                remotePeer: "test",
                localPeer: "test",
                cancellation: .init()
            )

            let response = try await sut.getPermissions(request: request, context: ctx)

            // 成功回應（非 gRPC error status），且權限清單為空。
            switch response.accepted {
            case .success(let contents):
                #expect(contents.message.permissions.isEmpty)
            case .failure(let error):
                Issue.record("expected success with empty permissions, got gRPC error: \(error)")
            }
        }
    }
}
