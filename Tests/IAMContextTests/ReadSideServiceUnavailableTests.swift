import Testing
import Foundation
import KurrentDB
import EmployeeAccessAggregate
import RoleAggregate

// 讀取端失敗路徑：「只把 stream 不存在（DDDError.eventsNotFound）視為空，其他錯誤一律回 503」。
//
// 「stream 不存在 → 200 空陣列」那一半已由 RoleApiHandlerIntegrationTests
// （get_role_holders_with_unknown_roleId_returns_200_with_empty_array）等整合測試保護；
// 這裡補另一半：KurrentDB 不可用（或 role directory 出錯）時，HTTP 層回 503 而不是被誤當空清單。
//
// 做法：建一個指向「本機沒人聽的 port」的 KurrentDBClient。連線被拒是立即失敗，不需要靠 sleep 等逾時，
// 也不需要 KurrentDB 在跑——這個檔案的前三個測試與本機 KDB 狀態完全無關。
@Suite(.serialized)
struct ReadSideServiceUnavailableTests {

    // MARK: - KurrentDB 不可用 → 503

    @Test(.timeLimit(.minutes(1)))
    func get_roles_returns_503_when_kurrentdb_is_unreachable() async throws {
        let handler = RoleAggregate.ApiHandler(kdbClient: try makeUnreachableKurrentDBClient())

        let output = try await handler.getRoles(.init())

        guard case .serviceUnavailable(let response) = output else {
            Issue.record("expected 503, got \(output)")
            return
        }
        #expect(try response.body.json.error == .serviceUnavailable)
    }

    @Test(.timeLimit(.minutes(1)))
    func get_role_holders_returns_503_when_kurrentdb_is_unreachable() async throws {
        let handler = EmployeeAccessAggregate.ApiHandler(
            kdbClient: try makeUnreachableKurrentDBClient(),
            roleDirectory: FakeRoleDirectory()
        )

        let output = try await handler.getRoleHolders(.init(query: .init(role: "any-role")))

        guard case .serviceUnavailable(let response) = output else {
            Issue.record("expected 503, got \(output)")
            return
        }
        #expect(try response.body.json.error == .serviceUnavailable)
    }

    @Test(.timeLimit(.minutes(1)))
    func get_permission_holders_returns_503_when_kurrentdb_is_unreachable() async throws {
        let handler = EmployeeAccessAggregate.ApiHandler(
            kdbClient: try makeUnreachableKurrentDBClient(),
            roleDirectory: FakeRoleDirectory()
        )

        let output = try await handler.getPermissionHolders(.init(query: .init(permission: "Nope.Not.Real")))

        guard case .serviceUnavailable(let response) = output else {
            Issue.record("expected 503, got \(output)")
            return
        }
        #expect(try response.body.json.error == .serviceUnavailable)
    }

    // MARK: - RoleDirectory 出錯 → 503（getPermissionHolders 建立候選人時讀完直接持有者後才呼叫 directory）

    // KurrentDB 不可用時 getPermissionHolders 在第一段（直接持有者）就失敗，走不到角色候選人查詢；
    // 這個測試用真的 KDB（讀不存在的權限 stream → eventsNotFound → 視為零位直接持有者）＋會丟錯的 directory，
    // 單獨保護第二段的失敗路徑。需要本機 KurrentDB localhost:2113。
    @Test(.timeLimit(.minutes(1)))
    func get_permission_holders_returns_503_when_role_directory_throws() async throws {
        let handler = EmployeeAccessAggregate.ApiHandler(
            kdbClient: makeTestKurrentDBClient(),
            roleDirectory: ThrowingRoleDirectory()
        )
        // 唯一的權限字串：其 IAM_GetPermissionHolders-<permission> stream 必不存在。
        let permission = "Nope.NoSuchPermission.\(UUID().uuidString)"

        let output = try await handler.getPermissionHolders(.init(query: .init(permission: permission)))

        guard case .serviceUnavailable(let response) = output else {
            Issue.record("expected 503, got \(output)")
            return
        }
        #expect(try response.body.json.error == .serviceUnavailable)
    }

    // MARK: - helpers

    private struct ThrowingRoleDirectory: RoleDirectory {
        struct Failure: Error {}
        func resolve(roleIds: Set<String>) async throws -> [String: Set<String>] { throw Failure() }
        func history(ofRoles roleIds: Set<String>) async throws -> [TimelineEntry] { throw Failure() }
        func rolesEverContaining(permission: String) async throws -> Set<String> { throw Failure() }
    }
}

/// 指向「本機此刻沒有任何程序在聽的 port」的 client：連線被拒（立即失敗），不必等逾時。
/// 探索次數壓成 1 次，避免 KurrentDB client 內建的節點探索重試拖長失敗時間。
private func makeUnreachableKurrentDBClient() throws -> KurrentDBClient {
    let port = try unusedLocalPort()
    return KurrentDBClient(settings: ClientSettings.localhost(ports: port).maxDiscoveryAttempts(1))
}

/// 讓 OS 配一個暫用 port 後立刻關掉——這個 port 此刻保證沒人在聽（不寫死 1、9 之類「應該沒人用」的號碼）。
private func unusedLocalPort() throws -> UInt32 {
    // Linux（Glibc）的 SOCK_STREAM 是 __socket_type 列舉，要轉成 Int32；macOS 直接是 Int32。
    #if os(Linux)
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { throw PortLookupFailure(reason: "socket() failed, errno=\(errno)") }
    defer { close(fd) }

    var address = sockaddr_in()
    #if !os(Linux)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)   // sin_len 只有 BSD／macOS 有
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0   // 由 OS 挑
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw PortLookupFailure(reason: "bind() failed, errno=\(errno)") }

    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length)
        }
    }
    guard nameResult == 0 else { throw PortLookupFailure(reason: "getsockname() failed, errno=\(errno)") }
    return UInt32(UInt16(bigEndian: bound.sin_port))
}

private struct PortLookupFailure: Error {
    let reason: String
}
