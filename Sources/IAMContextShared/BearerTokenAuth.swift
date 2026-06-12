import Foundation

/// Pure, transport-agnostic bearer-token authorization logic for the cross-context gRPC
/// surface (code review 2026-06-12; user 決策：Bearer token，明文）.
///
/// 24203（PermissionsService）是 IAM 對下游授權的**權威來源**；缺守門時任何能連到 port 的呼叫者
/// 都能查任一 user 的權限視圖 → 下游執法被匿名灌入。本型別只負責「給定 authorization metadata 值與
/// 期望 token，是否放行」的純決策，不依賴 grpc，方便單元測試；grpc 接線在
/// `IAMContextServer/BearerTokenServerInterceptor.swift`。
///
/// 注意：本機制是 app-layer 驗證，**不含傳輸加密**（plaintext）。token 與回應在同網段可被嗅探，
/// 故僅適用可信內網；跨不可信網段需另加 TLS。
public enum BearerTokenAuth {
    public enum Decision: Equatable, Sendable {
        case authorized
        case missing   // 沒帶 authorization metadata（或全為空）→ UNAUTHENTICATED
        case invalid   // 帶了但 token 不符 → UNAUTHENTICATED
    }

    /// 對 `authorization` metadata 的所有字串值做授權決策。
    /// - Parameters:
    ///   - authorizationValues: metadata 中 key=`authorization` 的字串值（可能 0..n 個）。
    ///   - expectedToken: 伺服器設定的共享 token（呼叫端須相符）。
    public static func decide(authorizationValues: [String], expectedToken: String) -> Decision {
        guard let header = authorizationValues.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return .missing
        }
        let presented = stripBearerScheme(header)
        return constantTimeEquals(presented, expectedToken) ? .authorized : .invalid
    }

    /// 接受 "Bearer <token>"（scheme 大小寫不敏感）或裸 token 兩種寫法，回傳實際 token 字串。
    public static func stripBearerScheme(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let scheme = "bearer "
        if trimmed.count >= scheme.count, trimmed.prefix(scheme.count).lowercased() == scheme {
            return String(trimmed.dropFirst(scheme.count)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    /// 常數時間比較，避免以回應時間差推測 token（timing oracle）。長度不同必不等，但仍走完固定長度迴圈。
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        let n = Swift.max(ab.count, bb.count)
        guard n > 0 else { return ab.count == bb.count }   // 兩者皆空才算相等
        var diff = ab.count ^ bb.count
        for i in 0..<n {
            let x: Int = i < ab.count ? Int(ab[i]) : 0
            let y: Int = i < bb.count ? Int(bb[i]) : 0
            diff |= (x ^ y)
        }
        return diff == 0
    }
}
