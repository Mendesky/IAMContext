import DDDKit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCServiceLifecycle
import Hummingbird
import KurrentDB
import Logging
import OpenAPIHummingbird
import ServiceLifecycle
import EmployeeAccessAggregate

import IAMContextShared

import struct EmployeeAccessAggregate.ApiHandler


@main
@MainActor
struct IAMContextServer {
    static let logger = Logger(label: "IAMContext")

    static func main() async throws {
        let router = Router()
        // TODO: add middleware (CORS / auth / logging) as needed for your project.

        let esdbSettings = ProcessInfo.processInfo.environment["ESDB_URL"]
            ?? "kurrent://admin:changeit@localhost:2113?tls=false"
        let settings: ClientSettings = try esdbSettings.parse()
        let kdbClient = KurrentDBClient(settings: settings)

        let serverURL = URL(string: "/")!

        try EmployeeAccessAggregate.ApiHandler(kdbClient: kdbClient)
            .registerHandlers(on: router, serverURL: serverURL, middlewares: [])

        // TODO(Phase 1.m v2): projection subscription wiring
        //   - Stream naming: Genesis projection JS uses `$ce-<SourceCategoryPrefix><Aggregate>`
        //     (e.g. `$ce-IAMUserAccessProfile`，非 `$ce-UserAccessProfile`)，
        //     prefix 由 ReadModelRenderer 從 contextName 衍生（IAMContext → "IAM"，OpportunityContext → "OC"）。
        //     詳見 docs/decisions.md Phase 1.g ratification 的 SourceCategoryPrefix 規則。
        //   - Create KurrentDB persistent subscription per stream
        //   - Setup EventBus + EventMappers per source aggregate
        //   - Dispatch RecordedEvent via mappers → eventBus → projectors
        //   - Until subscription is wired, read endpoints return empty/notFound
        //     (projection state stays empty without event ingestion).
        //   See OC `OCServer.swift` for production-level pattern with retry/nack.

        let portString = ProcessInfo.processInfo.environment["PORT"] ?? "8080"
        let port = Int(portString) ?? 8080
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("0.0.0.0", port: port))
        )

        // Context-to-context entry point (mirrors IdentityContext: HTTP for frontend/external,
        // gRPC for inter-context calls — Identity pairs 24200/24201, IAM pairs PORT/GRPC_PORT).
        let grpcPortString = ProcessInfo.processInfo.environment["GRPC_PORT"] ?? "24203"
        let grpcPort = Int(grpcPortString) ?? 24203
        let grpcServer = GRPCServer(transport: .http2NIOPosix(
            address: .ipv4(host: "0.0.0.0", port: grpcPort),
            transportSecurity: .plaintext
          ), services: [
            PermissionsService(kdbClient: kdbClient)
          ])

        logger.info("starting IAMContextServer on 0.0.0.0:\(port) (HTTP) / 0.0.0.0:\(grpcPort) (gRPC)")
        let serviceGroup = ServiceGroup(services: [app, grpcServer], logger: logger)
        try await serviceGroup.run()
    }
}
