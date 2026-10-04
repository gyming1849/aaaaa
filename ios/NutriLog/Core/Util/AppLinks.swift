import Foundation

// MARK: - Links configured in Info.plist (DESIGN §F.6 RB-3, RB-5)

/// `NLPrivacyPolicyURL` (https page of the privacy policy) and `NLSupportEmail` (report / contact address). Both are
/// empty until the release values exist; every UI that uses them is hidden meanwhile and `scripts/release-check.sh`
/// fails.
enum AppLinks {
    static var privacyPolicy: URL? {
        guard let raw = info("NLPrivacyPolicyURL"), let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    static var supportEmail: String? {
        guard let raw = info("NLSupportEmail"), raw.contains("@"), !raw.contains(" ") else { return nil }
        return raw
    }

    /// `mailto:<support>?subject=…&body=…`, nil without a support address.
    static func supportMail(subject: String, body: String) -> URL? {
        guard let to = supportEmail else { return nil }
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = to
        comps.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return comps.url
    }

    private static func info(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
