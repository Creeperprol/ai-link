import SwiftUI

struct ContentView: View {
    @StateObject private var client = AILinkClient()
    @State private var selectedTarget: String = "all"
    @State private var promptKind: String = "raw"
    @State private var promptText: String = ""
    @State private var showSettings = false
    @State private var inspectedPeer: PeerInfo?
    @State private var renamingPeer: PeerInfo?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusHeader
                Divider()
                peerList
                Divider()
                promptComposer
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 480)
            #endif
            .navigationTitle("AI Remote")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("New Claude") { Task { await client.spawn(cli: "claude") } }
                        Button("New Codex") { Task { await client.spawn(cli: "codex") } }
                        Button("New agy") { Task { await client.spawn(cli: "agy") } }
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet(client: client)
            }
            .sheet(item: $inspectedPeer) { peer in
                PaneViewerSheet(client: client, peer: peer)
            }
            .alert("Rename Chat", isPresented: Binding(
                get: { renamingPeer != nil },
                set: { if !$0 { renamingPeer = nil } }
            )) {
                TextField("Chat name", text: $renameText)
                Button("Save") {
                    if let p = renamingPeer {
                        client.setCustomName(renameText, for: p.id)
                    }
                    renamingPeer = nil
                }
                Button("Cancel", role: .cancel) { renamingPeer = nil }
            }
            .onAppear { client.startPolling() }
            .onDisappear { client.stopPolling() }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(client.isConnected ? Color.green : Color.red)
                .frame(width: 9, height: 9)
                .shadow(color: (client.isConnected ? Color.green : Color.red).opacity(0.6), radius: 3)
            if let status = client.status {
                Text("\(status.machine) · \(status.peers.count) session\(status.peers.count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.medium))
            } else {
                Text(client.lastError ?? "Disconnected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await client.fetchStatus() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var peerList: some View {
        let peers = client.status?.peers ?? []
        return Group {
            if peers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(client.isConnected ? "No active sessions" : "Not connected")
                        .font(.headline)
                    Text(client.isConnected
                         ? "Start AI sessions in tmux, or open a new one with the + button."
                         : "Open Settings to set the server and key, and make sure lan.mjs is running.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    if !client.isConnected {
                        Button("Open Settings") { showSettings = true }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(peers) { peer in
                            PeerRow(
                                peer: peer,
                                displayName: client.displayName(for: peer),
                                isTarget: selectedTarget == peer.id,
                                onSelect: { selectedTarget = peer.id },
                                onInspect: { inspectedPeer = peer },
                                onRename: {
                                    renameText = client.displayName(for: peer)
                                    renamingPeer = peer
                                },
                                onNudge: { action in
                                    Task { await client.nudge(id: peer.id, action: action) }
                                }
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var promptComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("To", selection: $selectedTarget) {
                    Text("All Peers").tag("all")
                    ForEach(client.status?.peers ?? []) { peer in
                        Text("\(client.displayName(for: peer)) (\(peer.cli)\(peer.pane.isEmpty ? "" : " \(peer.pane)"))").tag(peer.id)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Picker("Mode", selection: $promptKind) {
                    Text("Raw").tag("raw")
                    Text("Message").tag("msg")
                    Text("Task").tag("task")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                Spacer(minLength: 0)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Send prompt to terminal...", text: $promptText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !client.isConnected)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘↩)")
            }

            if let msg = client.lastDeliveryMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.bar)
    }

    private func send() {
        let text = promptText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, client.isConnected else { return }
        promptText = ""
        Task { await client.sendPrompt(to: selectedTarget, text: text, kind: promptKind) }
    }
}

private struct PeerRow: View {
    let peer: PeerInfo
    let displayName: String
    let isTarget: Bool
    let onSelect: () -> Void
    let onInspect: () -> Void
    let onRename: () -> Void
    let onNudge: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(cliColor).frame(width: 8, height: 8)
                Text(displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(peer.cli)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(cliColor.opacity(0.18))
                    .foregroundStyle(cliColor)
                    .clipShape(Capsule())
                if !peer.pane.isEmpty {
                    Text(peer.pane)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if peer.remote {
                    Label(peer.machine, systemImage: "network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                watchdogBadge
                if isTarget {
                    Label("Target", systemImage: "scope")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text(peer.cwd.isEmpty ? "~" : peer.cwd)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            if let snippet = peer.watchdog?.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let wd = peer.watchdog, wd.state != "ok", !wd.reason.isEmpty {
                Text(wd.reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button(action: onSelect) { Label("Target", systemImage: "scope") }
                Button(action: onRename) { Label("Rename", systemImage: "pencil") }
                if !peer.remote && !peer.pane.isEmpty {
                    Button(action: onInspect) { Label("Terminal", systemImage: "terminal") }
                    Menu {
                        Button("Send Enter") { onNudge("enter") }
                        Button("Send Yes (y + Enter)") { onNudge("yes") }
                        Button("Send Esc") { onNudge("esc") }
                        Button("Send Ctrl-C", role: .destructive) { onNudge("ctrl-c") }
                    } label: {
                        Label("Nudge", systemImage: "hand.tap")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isTarget ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.15), lineWidth: isTarget ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: onSelect)
    }

    private var cliColor: Color {
        switch peer.cli.lowercased() {
        case "claude": return .orange
        case "codex": return .green
        case "agy": return .cyan
        default: return .accentColor
        }
    }

    @ViewBuilder
    private var watchdogBadge: some View {
        let state = peer.watchdog?.state ?? "ok"
        if state != "ok" {
            Text(state.uppercased())
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(state == "rate_limited" ? Color.red.opacity(0.2) : Color.orange.opacity(0.2))
                .foregroundStyle(state == "rate_limited" ? Color.red : Color.orange)
                .clipShape(Capsule())
        }
    }
}

private struct SettingsSheet: View {
    @ObservedObject var client: AILinkClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection Mode") {
                    Picker("Mode", selection: $client.useSupabase) {
                        Text("LAN").tag(false)
                        Text("Supabase").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                if client.useSupabase {
                    Section("Supabase") {
                        TextField("Supabase URL (https://xxx.supabase.co)", text: $client.supabaseURL)
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        SecureField("Supabase Anon Key", text: $client.supabaseKey)
                            .autocorrectionDisabled()
                    }
                } else {
                    Section("LAN Server") {
                        TextField("Server URL (e.g. http://192.168.1.10:47812)", text: $client.serverURL)
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }
                }

                Section("Auth") {
                    SecureField("LAN Key (~/.ai-link/lan.key)", text: $client.apiKey)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Connection")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task { await client.fetchStatus() }
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 220)
        #endif
    }
}

private struct PaneViewerSheet: View {
    @ObservedObject var client: AILinkClient
    let peer: PeerInfo
    @State private var output = "Loading..."
    @State private var inputText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(output)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.92))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                                .textSelection(.enabled)
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                    }
                    .background(Color.black)
                    .onChange(of: output) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }

                Divider()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("Enter") {
                            Task {
                                await client.nudge(id: peer.id, action: "enter")
                                output = await client.fetchPane(id: peer.id)
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("Yes (y)") {
                            Task {
                                await client.nudge(id: peer.id, action: "yes")
                                output = await client.fetchPane(id: peer.id)
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("↑") {
                            Task {
                                await client.nudge(id: peer.id, action: "up")
                                output = await client.fetchPane(id: peer.id)
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("↓") {
                            Task {
                                await client.nudge(id: peer.id, action: "down")
                                output = await client.fetchPane(id: peer.id)
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("Esc") {
                            Task {
                                await client.nudge(id: peer.id, action: "esc")
                                output = await client.fetchPane(id: peer.id)
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("Ctrl-C", role: .destructive) {
                            Task {
                                await client.nudge(id: peer.id, action: "ctrl-c")
                                output = await client.fetchPane(id: peer.id)
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("Refresh") {
                            Task { output = await client.fetchPane(id: peer.id) }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Menu("Model") {
                            Button("Open /model Picker") {
                                sendModelCommand("/model")
                            }
                            Section("Claude") {
                                Button("Sonnet") { sendModelCommand("/model sonnet") }
                                Button("Opus") { sendModelCommand("/model opus") }
                                Button("Haiku") { sendModelCommand("/model haiku") }
                            }
                            Section("Codex") {
                                Button("GPT-5") { sendModelCommand("/model gpt-5") }
                                Button("o3") { sendModelCommand("/model o3") }
                                Button("o4-mini") { sendModelCommand("/model o4-mini") }
                            }
                            Section("agy") {
                                Button("Auto") { sendModelCommand("/model auto") }
                                Button("Gemini Pro") { sendModelCommand("/model pro") }
                                Button("Gemini Flash") { sendModelCommand("/model flash") }
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Type command or message...", text: $inputText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()

                    Button("Send") {
                        let text = inputText
                        inputText = ""
                        Task {
                            await client.sendPrompt(to: peer.id, text: text, kind: "raw")
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            output = await client.fetchPane(id: peer.id)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(10)
            }
            .navigationTitle("\(client.displayName(for: peer)) (\(peer.pane))")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                while !Task.isCancelled {
                    output = await client.fetchPane(id: peer.id)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 420)
        #endif
    }

    private func sendModelCommand(_ cmd: String) {
        Task {
            await client.sendPrompt(to: peer.id, text: cmd, kind: "raw")
            try? await Task.sleep(nanoseconds: 300_000_000)
            output = await client.fetchPane(id: peer.id)
        }
    }
}
