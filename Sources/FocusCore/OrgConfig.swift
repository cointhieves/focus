import Foundation

/// Company-wide values baked into the app from Resources/Org.plist at build time.
/// Empty when missing, so a build for another company never silently uses another's values.
public enum OrgConfig {
    private static let values: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Org", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return dict.compactMapValues { $0 as? String }
    }()

    public static var jiraSite: String { values["JiraSite"] ?? "" }
    public static var slackClientID: String { values["SlackClientID"] ?? "" }
}
