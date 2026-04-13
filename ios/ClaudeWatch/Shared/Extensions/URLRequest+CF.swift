import Foundation

extension URLRequest {
    /// Injects Cloudflare Access Service Token headers if configured.
    /// Set "cf_client_id" and "cf_client_secret" in UserDefaults to enable.
    mutating func addCloudflareAccessHeaders() {
        let id = UserDefaults.standard.string(forKey: "cf_client_id") ?? ""
        let secret = UserDefaults.standard.string(forKey: "cf_client_secret") ?? ""
        guard !id.isEmpty else { return }
        setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
        setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
    }
}
