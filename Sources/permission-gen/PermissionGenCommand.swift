//
//  PermissionGenCommand.swift
//  PermissionKit
//
//  CLI invoked by PermissionGenPlugin during `swift build` (and runnable by hand). Two modes:
//
//    • codegen (default): read the SPLIT document — a catalog file + a rules file — merge them, and
//      render the two Swift files into an output directory.
//          permission-gen --permissions <Ctx>.permissions.yaml --rules <Ctx>.rules.yaml --output-dir <dir>
//
//    • --all (migration): read one COMBINED document and write the two split files together, so a
//      not-yet-split context can adopt the two-file layout in one shot.
//          permission-gen --all <combined>.yaml [--split-dir <dir>]
//
//  There is intentionally no single-file codegen path: codegen requires both files.
//

import ArgumentParser
import Foundation
import PermissionGenerator

@main
struct PermissionGenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permission-gen",
        abstract: "Generate Permission.swift + PermissionRules.swift from a split permission document (catalog + rules), or split a combined document into the two-file layout."
    )

    @Option(name: .long, help: "Codegen: path to the catalog file (<Context>.permissions.yaml) — context + serverPrefix + permissions.")
    var permissions: String?

    @Option(name: .long, help: "Codegen: path to the rules file (<Context>.rules.yaml) — the routing rules.")
    var rules: String?

    @Option(name: .customLong("output-dir"), help: "Codegen: directory to write Permission.swift + PermissionRules.swift into.")
    var outputDir: String?

    @Option(name: .long, help: "Migration: path to a COMBINED document; writes <Context>.permissions.yaml + <Context>.rules.yaml together.")
    var all: String?

    @Option(name: .customLong("split-dir"), help: "Migration: directory to write the two split files into (default: alongside --all).")
    var splitDir: String?

    func validate() throws {
        if all != nil {
            guard permissions == nil, rules == nil, outputDir == nil else {
                throw ValidationError("--all (split mode) cannot be combined with --permissions / --rules / --output-dir.")
            }
        } else {
            guard splitDir == nil else {
                throw ValidationError("--split-dir is only valid together with --all.")
            }
            guard permissions != nil, rules != nil, outputDir != nil else {
                throw ValidationError("codegen needs --permissions <catalog.yaml> --rules <rules.yaml> --output-dir <dir>. (To split a combined file into the two-file layout, use --all <combined>.yaml.)")
            }
        }
    }

    func run() throws {
        if let combined = all {
            try runSplit(combinedPath: combined)
        } else {
            try runCodegen(permissionsPath: permissions!, rulesPath: rules!, outputDir: outputDir!)
        }
    }

    private func runCodegen(permissionsPath: String, rulesPath: String, outputDir: String) throws {
        let document = try PermissionDocument.load(permissionsPath: permissionsPath, rulesPath: rulesPath)
        let output = try PermissionEmitter(document: document).render()

        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try output.permissionSwift.write(to: dir.appendingPathComponent("Permission.swift"), atomically: true, encoding: .utf8)
        try output.rulesSwift.write(to: dir.appendingPathComponent("PermissionRules.swift"), atomically: true, encoding: .utf8)
    }

    private func runSplit(combinedPath: String) throws {
        let combinedURL = URL(fileURLWithPath: combinedPath)
        let document = try PermissionDocument.load(yamlPath: combinedPath)
        let (permissionsYAML, rulesYAML) = try document.splitYAML()

        let dir = splitDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? combinedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let permissionsURL = dir.appendingPathComponent("\(document.context).permissions.yaml")
        let rulesURL = dir.appendingPathComponent("\(document.context).rules.yaml")
        try permissionsYAML.write(to: permissionsURL, atomically: true, encoding: .utf8)
        try rulesYAML.write(to: rulesURL, atomically: true, encoding: .utf8)

        let note = "permission-gen --all: wrote \(permissionsURL.lastPathComponent) + \(rulesURL.lastPathComponent) into \(dir.path)\n"
        FileHandle.standardError.write(Data(note.utf8))
    }
}
