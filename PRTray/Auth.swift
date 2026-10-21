import Foundation
import Security
import AppKit
import Observation

/// Token storage in the macOS Keychain (generic password, service com.akkikens.prtray).
enum Keychain {
    private static let service = "com.akkikens.prtray"
    private static let account = "github-token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        delete()
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}

/// Reads `gh auth token` (developer fallback when there is no Keychain token).
enum GHCLI {
    static func token() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/env"]
        for path in candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = path == "/usr/bin/env" ? ["gh", "auth", "token"] : ["auth", "token"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { continue }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0,
               let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty { return s }
        }
        return nil
    }
}

enum DeviceFlowError: LocalizedError {
    case notConfigured, expired, denied, network(String), server(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "This build has no GitHub OAuth client ID. Set GitHubClientID in project.yml."
        case .expired: return "The code expired. Try signing in again."
        case .denied: return "Authorization was denied."
        case .network(let m): return "Can't reach GitHub: \(m)"
        case .server(let m): return "GitHub: \(m)"
        }
    }
}

/// OAuth device flow: https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow
@Observable
@MainActor
final class DeviceFlow {
    enum Phase: Equatable { case starting, waiting, done, failed(String) }

    var phase: Phase = .starting
    var userCode = ""
    var verificationURL = URL(string: "https://github.com/login/device")!

    private var task: Task<Void, Never>?
    var onToken: ((String) -> Void)?

    static var clientID: String? {
        let id = Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String
        guard let id, !id.isEmpty, id != "REPLACE_WITH_CLIENT_ID" else { return nil }
        return id
    }

    func start() {
        cancel()
        phase = .starting
        task = Task { await run() }
    }

    func cancel() { task?.cancel(); task = nil }

    private func run() async {
        do {
            guard let clientID = Self.clientID else { throw DeviceFlowError.notConfigured }
            let codeResp = try await post("https://github.com/login/device/code",
                                          ["client_id": clientID, "scope": "repo read:org"])
            guard let device = codeResp["device_code"] as? String,
                  let user = codeResp["user_code"] as? String else {
                throw DeviceFlowError.server(codeResp["error_description"] as? String ?? "bad response")
            }
            userCode = user
            if let s = codeResp["verification_uri"] as? String, let u = URL(string: s) { verificationURL = u }
            phase = .waiting
            var interval = codeResp["interval"] as? Int ?? 5
            let expiresIn = codeResp["expires_in"] as? Int ?? 900
            let deadline = Date().addingTimeInterval(Double(expiresIn))
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(interval))
                if Date() > deadline { throw DeviceFlowError.expired }
                let r = try await post("https://github.com/login/oauth/access_token", [
                    "client_id": clientID, "device_code": device,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
                if let token = r["access_token"] as? String, !token.isEmpty {
                    phase = .done
                    onToken?(token)
                    return
                }
                switch r["error"] as? String {
                case "authorization_pending": continue
                case "slow_down": interval = (r["interval"] as? Int) ?? (interval + 5)
                case "expired_token": throw DeviceFlowError.expired
                case "access_denied": throw DeviceFlowError.denied
                default: throw DeviceFlowError.server(r["error_description"] as? String ?? "unexpected response")
                }
            }
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func post(_ url: String, _ params: [String: String]) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw DeviceFlowError.server("bad url") }
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("PRTray", forHTTPHeaderField: "User-Agent")
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch {
            if error is CancellationError { throw error }
            throw DeviceFlowError.network(error.localizedDescription)
        }
    }
}
