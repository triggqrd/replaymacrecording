import AppKit
import UniformTypeIdentifiers

@MainActor
enum ExportDestinationPicker {
    static func chooseDestination(
        suggestedURL: URL,
        contentType: UTType,
        title: String
    ) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.directoryURL = suggestedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = suggestedURL.lastPathComponent
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
