import Foundation

struct WatchdogStatus: Codable, Equatable {
    let state: String
    let reason: String
    let since: Double?
    let snippet: String?
}

struct PeerInfo: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let cli: String
    let cwd: String
    let remote: Bool
    let machine: String
    let pane: String
    let isHost: Bool
    let seen: Double
    let watchdog: WatchdogStatus?
}

struct TaskInfo: Codable, Identifiable, Equatable {
    let id: String
    let to: String?
    let status: String?
    let text: String?
    let at: Double?
}

struct StatusResponse: Codable {
    let machine: String
    let mid: String
    let httpPort: Int
    let peers: [PeerInfo]
    let tasks: [TaskInfo]
    let updatedAt: Double
}

struct PaneResponse: Codable {
    let id: String
    let name: String
    let pane: String
    let output: String
}

struct PromptPayload: Codable {
    let to: String
    let text: String
    let kind: String
    let fromName: String
}

struct PromptDelivery: Codable {
    let id: String
    let name: String
    let via: String
}

struct PromptResponse: Codable {
    let ok: Bool
    let delivered: [PromptDelivery]
}

struct NudgePayload: Codable {
    let action: String
}
