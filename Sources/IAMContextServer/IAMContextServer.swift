import DDDKit
import Foundation
import Hummingbird
import KurrentDB
import Logging
import OpenAPIHummingbird
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
        logger.info("starting IAMContextServer on 0.0.0.0:\(port)")
        try await app.runService()
    }
}
