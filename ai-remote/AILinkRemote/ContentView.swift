import SwiftUI

struct ContentView: View {
    @StateObject private var client = AILinkClient()
    @State private var selectedTarget: String = "all"
    @State private var promptKind: String = "raw"
    @State private var promptText: String = ""
    @FocusState private var promptFocused: Bool
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
            .onOpenURL { client.pair(from: $0) }
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
                         : "Open Settings to set the server URL and key, and make sure cloud-agent.mjs is running on your Mac.")
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
                    .focused($promptFocused)

                #if os(iOS)
                if promptFocused {
                    Button {
                        promptFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Circle())
                    .accessibilityLabel("Hide keyboard")
                }
                #endif

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

            if !peer.cwd.isEmpty {
                Text(peer.cwd)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

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
                if !peer.remote && !peer.pane.isEmpty {
                    Button(action: onInspect) {
                        Label("Terminal", systemImage: "terminal")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Spacer(minLength: 0)
                }
                Button(action: onSelect) { Image(systemName: "scope").frame(minWidth: 22) }
                    .help("Send prompts here")
                Button(action: onRename) { Image(systemName: "pencil").frame(minWidth: 22) }
                    .help("Rename")
                if !peer.remote && !peer.pane.isEmpty {
                    Menu {
                        Button("Send Enter") { onNudge("enter") }
                        Button("Send Yes (y + Enter)") { onNudge("yes") }
                        Button("Send Esc") { onNudge("esc") }
                        Button("Send Ctrl-C", role: .destructive) { onNudge("ctrl-c") }
                    } label: {
                        Image(systemName: "hand.tap").frame(minWidth: 22)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.callout.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.regular)
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
                Section("Server") {
                    TextField("Server URL (https://… or http://192.168.1.10:47812)", text: $client.serverURL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    SecureField("Access key", text: $client.apiKey)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("Away from home: use your Cloudflare relay URL and the key in ~/.ai-link/cloud.json on your Mac. On the same Wi-Fi: http://<mac-ip>:47812 and ~/.ai-link/lan.key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }
}

private struct PaneViewerSheet: View {
    @ObservedObject var client: AILinkClient
    let peer: PeerInfo
    @State private var output = "Loading..."
    @State private var lines: [AttributedString] = []
    /// Keep the view pinned to the newest output; turned off when the person scrolls up to read.
    @State private var follow = true
    /// "chat" = the whole conversation (sent by the Mac in pieces), "terminal" = the live screen.
    @State private var mode = "chat"
    @State private var chatPieces: [Int: String] = [:]
    @State private var chatTotal = 0
    @State private var loadingEarlier = false
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $mode) {
                    Text("Chat").tag("chat")
                    Text("Terminal").tag("terminal")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .onChange(of: mode) { _, _ in
                    follow = true
                    output = mode == "chat" && !chatPieces.isEmpty ? joinedChat() : "Loading..."
                    Task { await refreshCurrent() }
                }

                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if mode == "chat", let first = chatPieces.keys.min(), first > 0 {
                                Button {
                                    Task { await loadEarlier() }
                                } label: {
                                    Label(loadingEarlier ? "Loading…" : "Earlier messages (\(first) more)", systemImage: "arrow.up.circle")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .disabled(loadingEarlier)
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 8)
                            }
                            ForEach(lines.indices, id: \.self) { i in
                                Text(lines[i])
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                        .padding(10)
                        .textSelection(.enabled)
                    }
                    .background(Color.black)
                    #if os(iOS)
                    .scrollDismissesKeyboard(.interactively)
                    #endif
                    // Any drag means the person is reading back: stop jumping to the bottom.
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in follow = false })
                    .overlay(alignment: .bottomTrailing) {
                        if !follow {
                            Button {
                                follow = true
                                proxy.scrollTo("bottom", anchor: .bottom)
                            } label: {
                                Label("Latest", systemImage: "arrow.down.to.line")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(10)
                        }
                    }
                    .onAppear { lines = renderLines(output) }
                    .onChange(of: output) { _, newValue in
                        lines = renderLines(newValue)
                        if follow {
                            DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }
                }

                Divider()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("Enter") {
                            Task {
                                await client.nudge(id: peer.id, action: "enter")
                                await refreshCurrent()
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("Yes (y)") {
                            Task {
                                await client.nudge(id: peer.id, action: "yes")
                                await refreshCurrent()
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("↑") {
                            Task {
                                await client.nudge(id: peer.id, action: "up")
                                await refreshCurrent()
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("↓") {
                            Task {
                                await client.nudge(id: peer.id, action: "down")
                                await refreshCurrent()
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("Esc") {
                            Task {
                                await client.nudge(id: peer.id, action: "esc")
                                await refreshCurrent()
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("Ctrl-C", role: .destructive) {
                            Task {
                                await client.nudge(id: peer.id, action: "ctrl-c")
                                await refreshCurrent()
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("Refresh") {
                            Task { await refreshCurrent() }
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
                        .focused($inputFocused)

                    #if os(iOS)
                    if inputFocused {
                        Button {
                            inputFocused = false
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Hide keyboard")
                    }
                    #endif

                    Button("Send") {
                        let text = inputText
                        inputText = ""
                        Task {
                            await client.sendPrompt(to: peer.id, text: text, kind: "raw")
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            await refreshCurrent()
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
                    await refreshCurrent()
                    try? await Task.sleep(nanoseconds: mode == "chat" ? 3_000_000_000 : 1_500_000_000)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 420)
        #endif
    }

    /// Fetches what the current view shows: the live screen, or the newest piece of the chat.
    private func refreshCurrent() async {
        if mode == "terminal" {
            output = await client.fetchPane(id: peer.id)
            return
        }
        let raw = await client.fetchPane(id: "\(peer.id)-chat-last")
        guard let piece = parseChat(raw) else {
            if chatPieces.isEmpty { output = raw } // "Waiting for the Mac…" on the first request
            return
        }
        let previousLast = chatTotal - 1
        chatTotal = piece.total
        chatPieces[piece.index] = piece.text
        // The old last piece was still growing when it was fetched: get its final text.
        if piece.index > previousLast, previousLast >= 0, chatPieces[previousLast] != nil {
            Task { _ = await loadPiece(previousLast) }
        }
        if mode == "chat" { output = joinedChat() }
    }

    /// "#chat <index>/<total>\n<text>" from the Mac's cloud agent.
    private func parseChat(_ raw: String) -> (index: Int, total: Int, text: String)? {
        guard raw.hasPrefix("#chat "), let nl = raw.firstIndex(of: "\n") else { return nil }
        let head = raw[raw.index(raw.startIndex, offsetBy: 6)..<nl].split(separator: "/")
        guard head.count == 2, let index = Int(head[0]), let total = Int(head[1]) else { return nil }
        return (index, total, String(raw[raw.index(after: nl)...]))
    }

    private func joinedChat() -> String {
        chatPieces.keys.sorted().compactMap { chatPieces[$0] }.joined(separator: "\n")
    }

    /// Asks for one piece; the first request only tells the Mac to send it, so retry until it arrives.
    private func loadPiece(_ index: Int) async -> Bool {
        for _ in 0..<8 {
            let raw = await client.fetchPane(id: "\(peer.id)-chat-\(index)")
            if let piece = parseChat(raw), piece.index == index {
                chatPieces[index] = piece.text
                if mode == "chat" { output = joinedChat() }
                return true
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        return false
    }

    private func loadEarlier() async {
        guard let first = chatPieces.keys.min(), first > 0 else { return }
        follow = false
        loadingEarlier = true
        _ = await loadPiece(first - 1)
        loadingEarlier = false
    }

    /// Terminal: ANSI colours. Chat: the person's own messages ("❯ ...") tinted so the turns are easy to tell apart.
    private func renderLines(_ text: String) -> [AttributedString] {
        var result = ANSIText.lines(text)
        guard mode == "chat" else { return result }
        var inUser = false
        for i in result.indices {
            let line = String(result[i].characters)
            if line.hasPrefix("❯ ") { inUser = true } else if line.hasPrefix("⏺ ") { inUser = false }
            if inUser { result[i].foregroundColor = Color(red: 0.45, green: 0.80, blue: 1.0) }
        }
        return result
    }

    private func sendModelCommand(_ cmd: String) {
        Task {
            await client.sendPrompt(to: peer.id, text: cmd, kind: "raw")
            try? await Task.sleep(nanoseconds: 300_000_000)
            await refreshCurrent()
        }
    }
}
