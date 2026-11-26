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
    @Published var useSupabase: Bool {
        didSet { UserDefaults.standard.set(useSupabase, forKey: "ailink_use_supabase") }
    }
    @Published var supabaseURL: String {
        didSet { UserDefaults.standard.set(supabaseURL, forKey: "ailink_supabase_url") }
    }
    @Published var supabaseKey: String {
        didSet { UserDefaults.standard.set(supabaseKey, forKey: "ailink_supabase_key") }
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
        self.useSupabase = UserDefaults.standard.object(forKey: "ailink_use_supabase") as? Bool ?? false
        self.supabaseURL = UserDefaults.standard.string(forKey: "ailink_supabase_url") ?? ""
        self.supabaseKey = UserDefaults.standard.string(forKey: "ailink_supabase_key") ?? ""
        self.customNames = UserDefaults.standard.dictionary(forKey: "ailink_custom_names") as? [String: String] ?? [:]
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
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private func makeSupabaseRequest(path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        let base = supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = method
        let key = supabaseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private func sendSupabaseCommand(targetId: String, action: String, payload: [String: String]) async {
        let machine = status?.machine ?? ""
        var fullPayload = payload
        fullPayload["key"] = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyObj: [String: Any] = [
            "machine": machine,
            "target_id": targetId,
            "action": action,
            "payload": fullPayload,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: bodyObj)
            let req = try makeSupabaseRequest(path: "/rest/v1/ai_link_commands", method: "POST", body: data)
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            lastDeliveryMessage = (200...299).contains(code) ? "Queued \(action) via Supabase" : "Supabase HTTP \(code)"
        } catch {
            lastDeliveryMessage = "Supabase error: \(error.localizedDescription)"
        }
    }

    func fetchStatus() async {
        if useSupabase {
            guard !supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !supabaseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                isConnected = false
                lastError = "Set Supabase URL and Key in Settings"
                return
            }
            do {
                let req = try makeSupabaseRequest(path: "/rest/v1/ai_link_sessions?select=*&order=updated_at.desc")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    isConnected = false
                    lastError = "Supabase HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                    return
                }
                let rows = try JSONDecoder().decode([SupabaseSessionRow].self, from: data)
                let peers = rows.map { r in
                    PeerInfo(
                        id: r.id, name: r.name, cli: r.cli, cwd: r.cwd ?? "",
                        remote: false, machine: r.machine, pane: r.pane ?? "",
                        isHost: false, seen: Date().timeIntervalSince1970 * 1000,
                        watchdog: WatchdogStatus(state: r.watchdog_state ?? "ok", reason: r.watchdog_reason ?? "", since: nil, snippet: String((r.pane_output ?? "").suffix(200)))
                    )
                }
                status = StatusResponse(machine: rows.first?.machine ?? "Supabase", mid: "supabase", httpPort: 443, peers: peers, tasks: [], updatedAt: Date().timeIntervalSince1970 * 1000)
                isConnected = true
                lastError = nil
            } catch {
                isConnected = false
                lastError = error.localizedDescription
            }
            return
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isConnected = false
            lastError = "Set your LAN key in Settings"
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
        if useSupabase {
            await sendSupabaseCommand(targetId: target, action: "prompt", payload: ["text": trimmed, "kind": kind])
            return
        }
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
        if useSupabase {
            do {
                let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
                let req = try makeSupabaseRequest(path: "/rest/v1/ai_link_sessions?id=eq.\(encoded)&select=*")
                let (data, _) = try await URLSession.shared.data(for: req)
                let rows = try JSONDecoder().decode([SupabaseSessionRow].self, from: data)
                return rows.first?.pane_output ?? "(no output yet)"
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        }
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
        if useSupabase {
            await sendSupabaseCommand(targetId: id, action: "nudge", payload: ["action": action])
            return
        }
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
        if useSupabase {
            await sendSupabaseCommand(targetId: "all", action: "spawn", payload: ["cli": cli])
            return
        }
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
