import Foundation

/// Pure rules for deciding whether a running application should be treated as a
/// game for auto-record. Kept free of AppKit so the classification logic lives
/// in one place and can be unit tested without a live workspace.
public enum GameAppClassifier {
    /// Whether an `LSApplicationCategoryType` string is one of Apple's App Store
    /// "Games" categories. The parent category is `public.app-category.games`;
    /// every genre subcategory ends in `-games`
    /// (e.g. `public.app-category.action-games`, `public.app-category.role-playing-games`).
    public static func isGameCategory(_ category: String?) -> Bool {
        guard let category, category.hasPrefix("public.app-category.") else {
            return false
        }
        return category == "public.app-category.games" || category.hasSuffix("-games")
    }

    /// A running app counts as a game when the user has explicitly listed its
    /// bundle identifier, or when its declared category is a games category.
    ///
    /// The manual list is checked first because it needs no file access, so it
    /// keeps working for titles whose category cannot be read (or is missing).
    public static func isGame(
        bundleIdentifier: String?,
        category: String?,
        manualBundleIDs: Set<String>
    ) -> Bool {
        if let bundleIdentifier, !bundleIdentifier.isEmpty, manualBundleIDs.contains(bundleIdentifier) {
            return true
        }
        return isGameCategory(category)
    }
}
