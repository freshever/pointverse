import SwiftUI

private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue = "system"
}

extension EnvironmentValues {
    var appLanguage: String {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}

enum AppLocalization {
    static func string(_ key: String, language: String) -> String {
        guard language != "system",
              let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
        }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}

struct AppText: View {
    @Environment(\.appLanguage) private var language
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(verbatim: AppLocalization.string(key, language: language))
    }
}
