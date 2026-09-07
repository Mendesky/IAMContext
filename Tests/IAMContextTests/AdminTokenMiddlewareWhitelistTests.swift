import Testing
import Hummingbird
@testable import IAMContextServer

// 純單元測試（無 HTTP server）：驗證 admin-token 中介的「唯讀 POST 白名單」名單內容。
//
// 為什麼測名單而不是測中介行為：`AdminTokenMiddleware.handle` 需要 Hummingbird 的
// Request/RequestContext 與 next closure，在單元測試層組裝成本高且脆弱；而這個白名單是
// 「哪些 POST 路徑免 admin token」的唯一真相，誤加一條就等於把變更端點開放給所有人。
// 名單本身用測試鎖住，接線行為由 handle 的兩行分支保證（見該檔註解）。
@Suite struct AdminTokenMiddlewareWhitelistTests {

    typealias Middleware = AdminTokenMiddleware<BasicRequestContext>

    @Test func whitelist_contains_scope_check() {
        #expect(Middleware.readOnlyPostPaths.contains("/employee-access/scope-check"))
    }

    /// 回歸鎖：白名單只能有唯讀查詢端點。任何變更端點（grant / revoke / assign / promote /
    /// transfer / create-profile）一旦被加進來，就等於免 token 可改授權資料 —— 這條必須擋住。
    @Test func whitelist_excludes_every_mutating_endpoint() {
        let mutatingFragments = [
            "grant-privilege",
            "revoke-privilege",
            "assign-roles",
            "revoke-roles",
            "promote-user",
            "transfer-department",
            "create-user-access-profile",
        ]
        for path in Middleware.readOnlyPostPaths {
            for fragment in mutatingFragments {
                #expect(
                    !path.contains(fragment),
                    "白名單不得含變更端點，但 \(path) 命中 \(fragment)"
                )
            }
        }
    }

    /// 名單維持最小：新增項目時應同步更新本測試，強迫審視「這條真的是唯讀嗎」。
    @Test func whitelist_is_exactly_the_reviewed_set() {
        #expect(Middleware.readOnlyPostPaths == ["/employee-access/scope-check"])
    }
}
