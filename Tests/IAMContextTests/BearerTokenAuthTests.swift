import Testing
import IAMContextShared

// 純單元測試（無 KDB / 無 gRPC server）：驗證 24203 bearer-token 守門的授權決策邏輯。
// grpc 接線在 IAMContextServer/BearerTokenServerInterceptor.swift，只是把 metadata 取出後委派給這裡。
@Suite struct BearerTokenAuthTests {
    let token = "s3cr3t-shared-token"

    @Test func authorizes_bearer_scheme() {
        #expect(BearerTokenAuth.decide(authorizationValues: ["Bearer \(token)"], expectedToken: token) == .authorized)
    }

    @Test func authorizes_bearer_scheme_case_insensitive() {
        #expect(BearerTokenAuth.decide(authorizationValues: ["bEaReR \(token)"], expectedToken: token) == .authorized)
    }

    @Test func authorizes_bare_token() {
        #expect(BearerTokenAuth.decide(authorizationValues: [token], expectedToken: token) == .authorized)
    }

    @Test func missing_when_no_values() {
        #expect(BearerTokenAuth.decide(authorizationValues: [], expectedToken: token) == .missing)
    }

    @Test func missing_when_only_blank_values() {
        #expect(BearerTokenAuth.decide(authorizationValues: ["", "   "], expectedToken: token) == .missing)
    }

    @Test func invalid_when_wrong_token() {
        #expect(BearerTokenAuth.decide(authorizationValues: ["Bearer not-the-token"], expectedToken: token) == .invalid)
    }

    @Test func invalid_when_token_is_prefix_of_expected() {
        // 防「前綴即通過」：presented 是 expected 的前綴也必須 invalid。
        #expect(BearerTokenAuth.decide(authorizationValues: ["Bearer s3cr3t"], expectedToken: token) == .invalid)
    }

    @Test func picks_first_non_blank_value() {
        #expect(BearerTokenAuth.decide(authorizationValues: ["  ", "Bearer \(token)"], expectedToken: token) == .authorized)
    }

    @Test func constant_time_equals_basic() {
        #expect(BearerTokenAuth.constantTimeEquals("abc", "abc") == true)
        #expect(BearerTokenAuth.constantTimeEquals("abc", "abd") == false)
        #expect(BearerTokenAuth.constantTimeEquals("abc", "ab") == false)
        #expect(BearerTokenAuth.constantTimeEquals("", "") == true)
        #expect(BearerTokenAuth.constantTimeEquals("a", "") == false)
    }

    @Test func strip_bearer_scheme_variants() {
        #expect(BearerTokenAuth.stripBearerScheme("Bearer xyz") == "xyz")
        #expect(BearerTokenAuth.stripBearerScheme("bearer  xyz  ") == "xyz")
        #expect(BearerTokenAuth.stripBearerScheme("xyz") == "xyz")
    }
}
