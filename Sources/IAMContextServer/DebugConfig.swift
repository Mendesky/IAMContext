import Foundation

/// IAM debug configuration resolved from environment variables at startup.
///
/// ⚠️  IAM_DEBUG_FULL_PERMISSIONS=1 makes every getPermissions call return the entire
/// permission universe (all catalog rawValues) regardless of the requesting userId.
/// This is a development-only escape hatch — NEVER enable in production.
struct DebugConfig: Sendable {
    /// When true, getPermissions (HTTP + gRPC) bypasses per-user lookup and returns the
    /// full catalog.  getPermissionHolders is intentionally NOT affected.
    let fullPermissions: Bool

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> DebugConfig {
        DebugConfig(fullPermissions: env["IAM_DEBUG_FULL_PERMISSIONS"] == "1")
    }
}
