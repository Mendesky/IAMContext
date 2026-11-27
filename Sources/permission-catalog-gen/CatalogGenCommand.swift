//
//  CatalogGenCommand.swift
//  PermissionKit
//
//  CLI invoked by PermissionCatalogPlugin during `swift build` (and runnable by hand). Reads MANY
//  permission YAML documents and aggregates their catalogs into one PermissionCatalog.swift.
//

import ArgumentParser
import Foundation
import PermissionGenerator

@main
struct PermissionCatalogGenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permission-catalog-gen",
        abstract: "Aggregate multiple permission YAML documents into one enumerable PermissionCatalog.swift."
    )

    @Argument(help: "Paths to permission YAML documents (one per context).")
    var inputs: [String]

    @Option(name: .customLong("output-dir"), help: "Directory to write PermissionCatalog.swift into.")
    var outputDir: String

    @Option(name: .customLong("grant-scope-types"), help: "Path to grant-scope-types.yaml (授權範圍類型定義). Omit when no permission is scoped.")
    var grantScopeTypes: String?

    func run() throws {
        let documents = try inputs.map { try PermissionDocument.load(yamlPath: $0) }
        let types = try grantScopeTypes.map { try GrantScopeTypesDocument.load(yamlPath: $0) } ?? GrantScopeTypesDocument(grantScopeTypes: [])
        let swift = try PermissionCatalogEmitter(documents: documents, grantScopeTypes: types).render()

        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try swift.write(to: dir.appendingPathComponent("PermissionCatalog.swift"), atomically: true, encoding: .utf8)
    }
}
