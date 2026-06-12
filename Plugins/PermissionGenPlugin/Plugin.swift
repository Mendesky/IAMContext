//
//  Plugin.swift
//  PermissionKit
//
//  Build-tool plugin (mirrors DDDKit's DomainEventGeneratorPlugin): finds the target's
//  `*permissions.yaml`, and runs `permission-gen` to emit Permission.swift + PermissionRules.swift
//  into the plugin work directory so they compile as part of the target — automatically, on every
//  `swift build`. SSOT is the YAML; the generated files are never checked in / hand-edited.
//

import Foundation
import PackagePlugin

@main
struct PermissionGenPlugin {
    func createBuildCommands(
        pluginWorkDirectory: URL,
        tool: (String) throws -> URL,
        sourceFiles: FileList,
        targetName: String
    ) throws -> [Command] {
        // No permission document in this target → nothing to do (the plugin is harmless to attach).
        guard let input = sourceFiles.first(where: { $0.url.lastPathComponent.hasSuffix("permissions.yaml") }) else {
            return []
        }

        let generatedDirectory = pluginWorkDirectory.appending(component: "generated", directoryHint: .isDirectory)
        let permissionOutput = generatedDirectory.appending(path: "Permission.swift")
        let rulesOutput = generatedDirectory.appending(path: "PermissionRules.swift")

        return [
            try .buildCommand(
                displayName: "Generating permissions from \(input.url.lastPathComponent)",
                executable: tool("permission-gen"),
                arguments: [
                    "--output-dir", generatedDirectory.path(),
                    input.url.path(),
                ],
                inputFiles: [input.url],
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
