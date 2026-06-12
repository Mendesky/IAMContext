/// Read-side projection drift signal — existence anchor reached, but downstream projection's derived fields / related read models are missing.
///
/// Lives in `{Ctx}Shared` because multiple read ApplicationServices (e.g. GetX / GetY) share the same semantics:
/// "not that the resource doesn't exist, but the internal projection hasn't caught up."
///
/// ApiHandler does not catch this type specifically — it falls through to the generic `catch { ... 503 }` branch,
/// signaling to the client "service temporarily unavailable" rather than a misleading 404.
///
/// `cause` indicates which projection / read source drifted (e.g. `"GetUserAccessProfile"`);
/// `message` describes the specific entity / id, used for log debugging.
package struct ProjectionReadInconsistency: Error {
    package let cause: String
    package let message: String

    package init(cause: String, message: String) {
        self.cause = cause
        self.message = message
    }
}
