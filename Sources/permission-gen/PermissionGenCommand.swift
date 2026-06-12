//
//  PermissionGenCommand.swift
//  PermissionKit
//
//  CLI invoked by PermissionGenPlugin during `swift build` (and runnable by hand). Mirrors the
//  shape of DDDKit's `generate` tool: reads the YAML document, renders the two Swift files into
//  an output directory.
//

import ArgumentParser
import Foundation
import PermissionGenerator

@main
struct PermissionGenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permission-gen",
        abstract: "Generate Permission.swift + PermissionRules.swift from a permission YAML document."
    )

    @Argument(help: "Path to the permission YAML document.")
    var input: String

    @Option(name: .customLong("output-dir"), help: "Directory to write Permission.swift and PermissionRules.swift into.")
    var outputDir: String

    func run() throws {
        let document = try PermissionDocument.load(yamlPath: input)
        let output = try PermissionEmitter(document: document).render()

        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try output.permissionSwift.write(to: dir.appendingPathComponent("Permission.swift"), atomically: true, encoding: .utf8)
        try output.rulesSwift.write(to: dir.appendingPathComponent("PermissionRules.swift"), atomically: true, encoding: .utf8)
    }
}
