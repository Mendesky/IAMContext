//
//  Plugin.swift
//  PermissionKit — PermissionCatalogPlugin
//
//  Build-tool plugin for an AGGREGATOR target (e.g. IAM): finds ALL `*permissions.yaml` files in the
//  target and runs `permission-catalog-gen` to emit one PermissionCatalog.swift (the cross-context,
//  enumerable catalog) during `swift build`. Unlike PermissionGenPlugin (one yaml → enforcement code
//  for one context), this consumes MANY yamls and emits pure data (no rules, no Middleware dep).
//

import Foundation
import PackagePlugin

@main
struct PermissionCatalogPlugin {
    func createBuildCommands(
        pluginWorkDirectory: URL,
        tool: (String) throws -> URL,
        sourceFiles: FileList,
        targetName: String
    ) throws -> [Command] {
        let inputs = sourceFiles
            .filter { $0.url.lastPathComponent.hasSuffix("permissions.yaml") }
            .map { $0.url }
        guard !inputs.isEmpty else { return [] }

        let generatedDirectory = pluginWorkDirectory.appending(component: "generated", directoryHint: .isDirectory)
        let output = generatedDirectory.appending(path: "PermissionCatalog.swift")

        var arguments = ["--output-dir", generatedDirectory.path()]
        arguments.append(contentsOf: inputs.map { $0.path() })

        return [
            try .buildCommand(
                displayName: "Aggregating permission catalog from \(inputs.count) document(s)",
                executable: tool("permission-catalog-gen"),
                arguments: arguments,
                inputFiles: inputs,
                outputFiles: [output]
            )
        ]
    }
}

extension PermissionCatalogPlugin: BuildToolPlugin {
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

extension PermissionCatalogPlugin: XcodeBuildToolPlugin {
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
