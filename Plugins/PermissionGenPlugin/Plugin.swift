//
//  Plugin.swift
//  PermissionKit
//
//  Build-tool plugin (mirrors DDDKit's DomainEventGeneratorPlugin): finds the target's split
//  permission document — `<Context>.permissions.yaml` (catalog) paired with `<Context>.rules.yaml`
//  (rules) — and runs `permission-gen` to emit Permission.swift + PermissionRules.swift into the
//  plugin work directory so they compile as part of the target, automatically on every `swift build`.
//  SSOT is the YAML; the generated files are never checked in / hand-edited. The document is split
//  into two files; a `.permissions.yaml` with no sibling `.rules.yaml` is an error (run
//  `permission-gen --all <combined>.yaml` to migrate a not-yet-split context).
//

import Foundation
import PackagePlugin

enum PermissionGenPluginError: Error, CustomStringConvertible {
    case missingRulesFile(context: String, catalog: String)

    var description: String {
        switch self {
        case let .missingRulesFile(context, catalog):
            return "PermissionGenPlugin: found \(catalog) but no matching \(context).rules.yaml in the target. " +
                "The permission document is split into two files — add \(context).rules.yaml " +
                "(e.g. `swift run permission-gen --all <combined>.yaml` to split a combined document)."
        }
    }
}

@main
struct PermissionGenPlugin {
    func createBuildCommands(
        pluginWorkDirectory: URL,
        tool: (String) throws -> URL,
        sourceFiles: FileList,
        targetName: String
    ) throws -> [Command] {
        // No catalog file in this target → nothing to do (the plugin is harmless to attach).
        guard let catalog = sourceFiles.first(where: { $0.url.lastPathComponent.hasSuffix(".permissions.yaml") }) else {
            return []
        }
        let catalogName = catalog.url.lastPathComponent
        let context = String(catalogName.dropLast(".permissions.yaml".count))

        // The rules half must sit beside the catalog half (split layout).
        guard let rulesFile = sourceFiles.first(where: { $0.url.lastPathComponent == "\(context).rules.yaml" }) else {
            throw PermissionGenPluginError.missingRulesFile(context: context, catalog: catalogName)
        }

        let generatedDirectory = pluginWorkDirectory.appending(component: "generated", directoryHint: .isDirectory)
        let permissionOutput = generatedDirectory.appending(path: "Permission.swift")
        let rulesOutput = generatedDirectory.appending(path: "PermissionRules.swift")

        return [
            try .buildCommand(
                displayName: "Generating permissions for \(context) from \(catalogName) + \(rulesFile.url.lastPathComponent)",
                executable: tool("permission-gen"),
                arguments: [
                    "--permissions", catalog.url.path(),
                    "--rules", rulesFile.url.path(),
                    "--output-dir", generatedDirectory.path(),
                ],
                inputFiles: [catalog.url, rulesFile.url],
                outputFiles: [permissionOutput, rulesOutput]
            )
        ]
    }
}

extension PermissionGenPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let swiftTarget = target as? SwiftSourceModuleTarget else { return [] }
        return try createBuildCommands(
            pluginWorkDirectory: context.pluginWorkDirectoryURL,
            tool: { try context.tool(named: $0).url },
            sourceFiles: swiftTarget.sourceFiles,
            targetName: target.name
        )
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension PermissionGenPlugin: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        try createBuildCommands(
            pluginWorkDirectory: context.pluginWorkDirectoryURL,
            tool: { try context.tool(named: $0).url },
            sourceFiles: target.inputFiles,
            targetName: target.displayName
        )
    }
}
#endif
