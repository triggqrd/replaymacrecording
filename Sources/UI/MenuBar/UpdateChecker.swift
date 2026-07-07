import Foundation

public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public let releaseURL: URL

    public init(version: String, releaseURL: URL) {
        self.version = version
        self.releaseURL = releaseURL
    }
}

public enum UpdateChecker {
    public static var currentAppVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    // The GitHub release fetch itself lives in the app target
    // (AppDelegate+Updates.swift) so that App Store builds, which compile
    // the app target with -DAPPSTORE, contain no trace of it. This module
    // keeps only the pure version comparison used by the fetch and by tests.
    public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard let candidateComponents = versionComponents(from: candidate),
              let currentComponents = versionComponents(from: current) else {
            return false
        }

        let count = max(candidateComponents.count, currentComponents.count)
        for index in 0..<count {
            let candidateValue = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentValue = index < currentComponents.count ? currentComponents[index] : 0
            if candidateValue != currentValue {
                return candidateValue > currentValue
            }
        }
        return false
    }

    private static func versionComponents(from version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(where: \.isNumber) else {
            return nil
        }

        let numericPrefix = trimmed[start...].prefix { character in
            character.isNumber || character == "."
        }
        let components = numericPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            return nil
        }
        let values = components.compactMap { Int($0) }
        return values.count == components.count ? values : nil
    }
}

