import Foundation
import SwiftUI

@MainActor
final class AILinkClient: ObservableObject {
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "ailink_server_url") }
    }
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "ailink_api_key") }
    }

    @Published var status: StatusResponse?
    @Published var isConnected = false
    @Published var lastError: String?
    @Published var lastDeliveryMessage: String?
    @Published var customNames: [String: String] {
        didSet { UserDefaults.standard.set(customNames, forKey: "ailink_custom_names") }
    }

    private var pollTask: Task<Void, Never>?

    init() {
        self.serverURL = UserDefaults.standard.string(forKey: "ailink_server_url") ?? "http://127.0.0.1:47812"
        self.apiKey = UserDefaults.standard.string(forKey: "ailink_api_key") ?? ""
        self.customNames = UserDefaults.standard.dictionary(forKey: "ailink_custom_names") as? [String: String] ?? [:]
    }

    /// Handles ailink://pair?url=...&key=... so a phone can be set up by tapping one link.
    func pair(from link: URL) {
        guard link.scheme == "ailink", link.host == "pair",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              let url = items.first(where: { $0.name == "url" })?.value,
              let key = items.first(where: { $0.name == "key" })?.value else { return }
        serverURL = url
        apiKey = key
        Task { await fetchStatus() }
    }

    func displayName(for peer: PeerInfo) -> String {
        if let custom = customNames[peer.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        return peer.name
    }

    func setCustomName(_ name: String, for peerId: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customNames.removeValue(forKey: peerId)
        } else {
            customNames[peerId] = trimmed
        }
    }

    func startPolling() {
        stopPolling()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-mock") {
            func w(_ st: String, _ r: String, _ sn: String?) -> WatchdogStatus { WatchdogStatus(state: st, reason: r, since: nil, snippet: sn) }
            status = StatusResponse(machine: "Pauls-MacBook-Pro", mid: "m", httpPort: 47812, peers: [
                PeerInfo(id: "1", name: "ai-link-9f2c", cli: "claude", cwd: "/Users/pauldenchat/Desktop/Projects/ai-link/ai-remote", remote: false, machine: "mac", pane: "%3", isHost: true, seen: 0, watchdog: w("ok", "", "Edit ContentView.swift\n  ✓ Build succeeded")),
                PeerInfo(id: "2", name: "agy-worker", cli: "agy", cwd: "/Users/pauldenchat/Projects/retro-pi-zero", remote: false, machine: "mac", pane: "%5", isHost: false, seen: 0, watchdog: w("stuck", "Waiting for approval for 4 min", "Allow this command? (y/n)")),
                PeerInfo(id: "3", name: "codex-2", cli: "codex", cwd: "", remote: true, machine: "Studio-iMac", pane: "", isHost: false, seen: 0, watchdog: w("rate_limited", "Rate limit hit", nil)),
            ], tasks: [], updatedAt: 0)
            isConnected = true
            return
        }
        #endif
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchStatus()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func makeRequest(path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        let base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)\(path)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    func fetchStatus() async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isConnected = false
            lastError = "Set the server URL and key in Settings"
            return
        }
        do {
            let req = try makeRequest(path: "/api/status")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                isConnected = false
                lastError = "HTTP \(code)"
                return
            }
            status = try JSONDecoder().decode(StatusResponse.self, from: data)
            isConnected = true
            lastError = nil
        } catch {
            isConnected = false
            lastError = error.localizedDescription
        }
    }

    func sendPrompt(to target: String, text: String, kind: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let payload = PromptPayload(to: target, text: trimmed, kind: kind, fromName: "remote-app")
            let req = try makeRequest(path: "/api/prompt", method: "POST", body: try JSONEncoder().encode(payload))
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                lastDeliveryMessage = "Send failed (HTTP \(code))"
                return
            }
            let decoded = try JSONDecoder().decode(PromptResponse.self, from: data)
            let summary = decoded.delivered.map { "\($0.name) (\($0.via))" }.joined(separator: ", ")
            lastDeliveryMessage = summary.isEmpty ? "No peers delivered" : "Sent to: \(summary)"
            await fetchStatus()
        } catch {
            lastDeliveryMessage = "Error: \(error.localizedDescription)"
        }
    }

    func fetchPane(id: String) async -> String {
        do {
            let req = try makeRequest(path: "/api/pane/\(id)")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return "Unable to load pane (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))"
            }
            let decoded = try JSONDecoder().decode(PaneResponse.self, from: data)
            return decoded.output.isEmpty ? "(empty pane)" : decoded.output
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    func nudge(id: String, action: String) async {
        do {
            let payload = NudgePayload(action: action)
            let req = try makeRequest(path: "/api/nudge/\(id)", method: "POST", body: try JSONEncoder().encode(payload))
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            lastDeliveryMessage = code == 200 ? "Nudged (\(action))" : "Nudge failed (HTTP \(code))"
            await fetchStatus()
        } catch {
            lastDeliveryMessage = "Nudge error: \(error.localizedDescription)"
        }
    }

    func spawn(cli: String) async {
        do {
            let body = try JSONEncoder().encode(["cli": cli])
            let req = try makeRequest(path: "/api/spawn", method: "POST", body: body)
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            lastDeliveryMessage = code == 200 ? "Spawned \(cli)" : "Spawn failed (HTTP \(code))"
            await fetchStatus()
        } catch {
            lastDeliveryMessage = "Spawn error: \(error.localizedDescription)"
        }
    }
}
