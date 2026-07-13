import HTTPTypes
import Hummingbird

/// CORS middleware for the IAMContext HTTP API.
///
/// Must be placed before ``AdminTokenMiddleware`` in the middleware chain so that
/// OPTIONS preflight requests are short-circuited with 204 before reaching auth
/// or route handlers.
///
/// Behaviour:
/// - `OPTIONS` → 204 No Content with Access-Control-Allow-* headers (preflight short-circuit).
/// - All other methods → pass through to the next handler, then append
///   `Access-Control-Allow-Origin` to the response.
/// - The `Origin` request header is reflected back; falls back to `"*"` when absent.
struct CORSMiddleware<Context: RequestContext>: RouterMiddleware {

    // MARK: - Cached header names

    private static var originName: HTTPField.Name { HTTPField.Name("origin")! }
    private static var allowOriginName: HTTPField.Name { HTTPField.Name("access-control-allow-origin")! }
    private static var allowMethodsName: HTTPField.Name { HTTPField.Name("access-control-allow-methods")! }
    private static var allowHeadersName: HTTPField.Name { HTTPField.Name("access-control-allow-headers")! }
    private static var maxAgeName: HTTPField.Name { HTTPField.Name("access-control-max-age")! }

    // MARK: - RouterMiddleware

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // Reflect the request Origin, or fall back to wildcard.
        let origin = request.headers[Self.originName] ?? "*"

        if request.method == .options {
            // Preflight: short-circuit before auth / route handlers.
            var headers = HTTPFields()
            headers[Self.allowOriginName] = origin
            headers[Self.allowMethodsName] = "GET, POST, OPTIONS"
            headers[Self.allowHeadersName] = "content-type, authorization, operatorid, userid"
            headers[Self.maxAgeName] = "600"
            return Response(status: .noContent, headers: headers)
        }

        // Non-OPTIONS: forward to the handler chain, then annotate the response.
        // Both the success path and the HTTPError throw path must carry the CORS header
        // so that browsers can read the real status code instead of seeing an opaque
        // CORS failure when a handler returns 4xx/5xx.
        do {
            var response = try await next(request, context)
            response.headers[Self.allowOriginName] = origin
            return response
        } catch var httpError as HTTPError {
            // Inject the CORS header into the error's own header bag.
            // Hummingbird calls HTTPError.response(from:context:) after the middleware
            // chain unwinds, so headers set here will be present on the final response.
            httpError.headers[Self.allowOriginName] = origin
            throw httpError
        } catch {
            // NOTE: For errors that do not conform to HTTPError (unexpected throws converted
            // to 500 by Hummingbird's top-level error handler), the CORS header cannot be
            // injected here because the response is assembled after the middleware stack
            // fully unwinds.  These errors are uncommon in normal operation; prefer throwing
            // HTTPError from handlers so the header reaches the browser in all cases.
            throw error
        }
    }
}
