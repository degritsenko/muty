import Foundation
import AppKit
import SwiftUI

/// Interface languages the app can be forced into from Settings → General.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }
}

/// Returns the translation for an English interface string.
///
/// The English strings themselves are the keys in `Localizable.strings`; a missing key falls
/// back to the English text, which keeps every screen usable while translations are added.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localizes a format string and substitutes arguments.
func LF(_ format: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(format, comment: ""), arguments: arguments)
}

/// Persists the interface language choice and applies it on the next launch.
///
/// macOS resolves bundled localizations (`Bundle.main`, SwiftUI `LocalizedStringKey`, AppKit
/// menus) from the app's `AppleLanguages` preference, so the choice is written there and the
/// user is asked to restart. System language is the default and removes the override.
@MainActor final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()

    private enum Keys {
        static let language = "appLanguage"
        static let appleLanguages = "AppleLanguages"
        static let appleLocale = "AppleLocale"
    }

    private let defaults: UserDefaults
    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            apply()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system
    }

    private func apply() {
        defaults.set(language.rawValue, forKey: Keys.language)
        switch language {
        case .system:
            defaults.removeObject(forKey: Keys.appleLanguages)
            defaults.removeObject(forKey: Keys.appleLocale)
        case .english:
            defaults.set(["en"], forKey: Keys.appleLanguages)
            defaults.set("en_US", forKey: Keys.appleLocale)
        case .russian:
            defaults.set(["ru"], forKey: Keys.appleLanguages)
            defaults.set("ru_RU", forKey: Keys.appleLocale)
        }
    }

    /// Relaunches the packaged app so the next launch resolves the new localization.
    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
}
