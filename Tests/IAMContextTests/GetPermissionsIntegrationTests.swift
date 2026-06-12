import Testing
import DDDKit
import KurrentDB
import TestUtility
import EmployeeAccessAggregate
import IAMContextShared

// read-side 整合 test（透過 GetPermissionsApplicationService → GetPermissionsPresenter projector）。
// 註：read model 的資料來自 KDB projection（IAM_GetPermissionsProjection.js）。該 projection 未部署時，
//     任何 userId 的 per-user stream 皆空 → presenter 回 nil → notFound。
//     happy-path（回真 permissions）需 projection 部署 + 事件 ingest，屬 runtime infra，不在單元測試覆蓋。
@Suite(.serialized)
struct GetPermissionsIntegrationTests {
    let kdbClient: KurrentDBClient = .init(settings: .localhost())

    // 未知 userId（read-model stream 空）→ EmployeeAccessQueryError.notFound。
    @Test func get_permissions_unknown_user_throws_notFound() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let userId = await bundle.generateId(for: "userId")
            let service = GetPermissionsApplicationService(kdbClient: kdbClient)
            let error = await #expect(throws: ContextError<EmployeeAccessQueryError>.self) {
                let _: [String] = try await service.execute(input: .init(userId: userId))
            }
            #expect(error?.error == .notFound)
        }
    }
}
