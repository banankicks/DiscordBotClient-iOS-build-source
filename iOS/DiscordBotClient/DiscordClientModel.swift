import Foundation
import SwiftUI

@MainActor
final class DiscordClientModel: ObservableObject {
    @Published var bots: [BotIdentity] = []
    @Published var selectedBotID: String?
    @Published var guilds: [Guild] = []
    @Published var directMessages: [Channel] = []
    @Published var selectedGuildID: String?
    @Published var selectedChannel: Channel?
    @Published var messages: [Message] = []
    @Published var status = "Add a bot token to get started"
    @Published var error: String?
    @Published var isConnecting = false

    private var token: String?
    private var socket: URLSessionWebSocketTask?
    private var socketSession: URLSession?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var sequence: Int?
    private var sessionID: String?
    private var resumeGatewayURL: String?
    private var reconnectTask: Task<Void, Never>?

    var selectedBot: BotIdentity? { bots.first { $0.id == selectedBotID } }
    var visibleChannels: [Channel] {
        guilds.first { $0.id == selectedGuildID }?.channels.filter(\.isTextChannel) ?? []
    }

    func restoreProfiles() {
        guard let data = UserDefaults.standard.data(forKey: "botProfiles"),
              let saved = try? JSONDecoder().decode([BotIdentity].self, from: data) else { return }
        bots = saved
        if let first = saved.first, let secret = KeychainStore.load(first.id) { Task { await connect(token: secret) } }
    }

    func connect(token rawToken: String) async {
        let clean = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "(?i)^Bot\\s+", with: "", options: .regularExpression)
        guard !clean.isEmpty else { error = "Enter a bot token."; return }
        isConnecting = true
        error = nil
        do {
            let me: BotAccount = try await request("/users/@me", token: clean)
            guard me.bot == true else { throw ClientError.message("This token does not belong to a bot account.") }
            let identity = BotIdentity(id: me.id, username: me.username, avatar: me.avatar)
            try KeychainStore.save(clean, for: identity.id)
            if !bots.contains(where: { $0.id == identity.id }) { bots.append(identity) }
            selectedBotID = identity.id
            token = clean
            persistProfiles()
            await openGateway()
        } catch { self.error = error.localizedDescription; status = "Disconnected" }
        isConnecting = false
    }

    func switchBot(_ bot: BotIdentity) async {
        disconnect()
        guard let secret = KeychainStore.load(bot.id) else { error = "Saved token is missing."; return }
        selectedBotID = bot.id
        guilds = []; directMessages = []; selectedGuildID = nil; selectedChannel = nil; messages = []
        await connect(token: secret)
    }

    func removeBot(_ bot: BotIdentity) {
        KeychainStore.delete(bot.id)
        bots.removeAll { $0.id == bot.id }
        persistProfiles()
        if selectedBotID == bot.id { disconnect(); selectedBotID = nil; guilds = []; directMessages = []; messages = [] }
    }

    func selectGuild(_ guild: Guild) { selectedGuildID = guild.id; selectedChannel = nil; messages = [] }

    func selectChannel(_ channel: Channel) {
        selectedChannel = channel
        Task { await loadMessages(channel) }
    }

    func loadMessages(_ channel: Channel) async {
        do {
            let loaded: [Message] = try await request("/channels/\(channel.id)/messages?limit=50")
            messages = loaded.sorted { $0.timestamp < $1.timestamp }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func send(_ content: String, attachment: Data? = nil, filename: String = "image.jpg") async {
        guard let channel = selectedChannel, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil else { return }
        do {
            let message: Message
            if let attachment { message = try await upload(channelID: channel.id, text: content, data: attachment, filename: filename) }
            else { message = try await request("/channels/\(channel.id)/messages", method: "POST", body: ["content": content]) }
            append(message)
        } catch { self.error = error.localizedDescription }
    }

    func edit(_ message: Message, content: String) async {
        do {
            let changed: Message = try await request("/channels/\(message.channel_id)/messages/\(message.id)", method: "PATCH", body: ["content": content])
            replace(changed)
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ message: Message) async {
        do {
            try await perform("/channels/\(message.channel_id)/messages/\(message.id)", method: "DELETE")
            messages.removeAll { $0.id == message.id }
        } catch { self.error = error.localizedDescription }
    }

    private func openGateway() async {
        do {
            let gateway: GatewayDiscovery = try await request("/gateway/bot")
            let baseURL = resumeGatewayURL ?? gateway.url
            guard let url = URL(string: baseURL + "?v=10&encoding=json") else { throw ClientError.message("Discord returned an invalid Gateway URL.") }
            let session = URLSession(configuration: .default)
            socketSession = session
            socket = session.webSocketTask(with: url)
            socket?.resume()
            status = "Connecting to Discord Gateway…"
            receiveTask = Task { await receiveGateway() }
        } catch { self.error = error.localizedDescription; status = "Disconnected" }
    }

    private func receiveGateway() async {
        guard let socket else { return }
        do {
            while !Task.isCancelled {
                let frame = try await socket.receive()
                let data: Data
                switch frame { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                let envelope = try JSONDecoder().decode(GatewayEnvelope.self, from: data)
                if let sequence = envelope.s { self.sequence = sequence }
                switch envelope.op {
                case 10:
                    if let interval = envelope.d?.heartbeat_interval { startHeartbeat(milliseconds: interval) }
                    try await identify()
                case 1: try await sendHeartbeat()
                case 7: status = "Reconnecting to Discord…"; disconnectSocket(); await openGateway(); return
                case 9:
                    sessionID = nil; resumeGatewayURL = nil; sequence = nil
                    status = "Reconnecting to Discord…"; disconnectSocket(); await openGateway(); return
                case 0: handleDispatch(envelope)
                default: break
                }
            }
        } catch {
            if !Task.isCancelled { status = "Gateway disconnected; retrying…"; scheduleReconnect() }
        }
    }

    private func identify() async throws {
        guard let token else { return }
        let application: BotApplication = (try? await request("/applications/@me?with_counts=true")) ?? BotApplication(flags: 0)
        var intents = 1 << 0 | 1 << 9 | 1 << 12 // GUILDS, GUILD_MESSAGES, DIRECT_MESSAGES
        // The portal flags identify which privileged intents have been approved.
        if application.flags & ((1 << 18) | (1 << 19)) != 0 { intents |= 1 << 15 }
        let data: [String: Any]
        let opcode: Int
        if let sessionID {
            opcode = 6
            data = ["token": token, "session_id": sessionID, "seq": sequence as Any? ?? NSNull()]
        } else {
            opcode = 2
            data = ["token": token, "intents": intents,
                    "properties": ["os": "ios", "browser": "DiscordBotClient", "device": "iPhone"]]
        }
        let payload: [String: Any] = ["op": opcode, "d": data]
        try await sendJSON(payload)
        status = "Identifying bot…"
    }

    private func startHeartbeat(milliseconds: Double) {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            let interval = UInt64(max(1, milliseconds) * 1_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                try? await sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() async throws { try await sendJSON(["op": 1, "d": sequence as Any? ?? NSNull()]) }
    private func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket?.send(.data(data))
    }

    private func handleDispatch(_ event: GatewayEnvelope) {
        guard let payload = event.d else { return }
        switch event.t {
        case "READY":
            sessionID = payload.session_id
            resumeGatewayURL = payload.resume_gateway_url
            status = "Connected as \(payload.user?.username ?? selectedBot?.username ?? "bot")"
        case "RESUMED": status = "Connected as \(selectedBot?.username ?? "bot")"
        case "GUILD_CREATE":
            guard let guild = payload.guildValue() else { return }
            if let index = guilds.firstIndex(where: { $0.id == guild.id }) { guilds[index] = guild } else { guilds.append(guild) }
            guilds.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "MESSAGE_CREATE":
            if payload.guild_id == nil, let channelID = payload.channel_id,
               !directMessages.contains(where: { $0.id == channelID }) {
                directMessages.append(Channel(id: channelID, type: 1, name: payload.author?.username, parent_id: nil, topic: nil))
            }
            if let message = payload.messageValue(), message.channel_id == selectedChannel?.id { append(message) }
        case "MESSAGE_UPDATE":
            if let message = payload.messageValue(), message.channel_id == selectedChannel?.id { append(message) }
            else if let message = payload.message, message.channel_id == selectedChannel?.id { replace(message) }
        case "MESSAGE_DELETE": if let id = payload.id, payload.channel_id == selectedChannel?.id { messages.removeAll { $0.id == id } }
        case "CHANNEL_CREATE":
            guard let id = payload.id, let name = payload.name else { return }
            let channel = Channel(id: id, type: payload.type ?? 0, name: name, parent_id: payload.parent_id, topic: payload.topic)
            if let guildID = payload.guild_id, let index = guilds.firstIndex(where: { $0.id == guildID }) {
                if !guilds[index].channels.contains(where: { $0.id == id }) { guilds[index].channels.append(channel) }
            } else if !directMessages.contains(where: { $0.id == id }) { directMessages.append(channel) }
        default: break
        }
    }

    private func append(_ message: Message) {
        guard !messages.contains(where: { $0.id == message.id }) else { replace(message); return }
        messages.append(message); messages.sort { $0.timestamp < $1.timestamp }
    }
    private func replace(_ message: Message) {
        if let i = messages.firstIndex(where: { $0.id == message.id }) { messages[i] = message } else { append(message) }
    }

    private func upload(channelID: String, text: String, data: Data, filename: String) async throws -> Message {
        guard let token, let url = URL(string: "https://discord.com/api/v10/channels/\(channelID)/messages") else { throw ClientError.message("Missing login.") }
        let boundary = UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(try JSONSerialization.data(withJSONObject: ["content": text]))
        body.append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"\(filename.replacingOccurrences(of: "\"", with: ""))\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data); body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("DiscordBotClient iOS", forHTTPHeaderField: "User-Agent")
        let (responseData, response) = try await URLSession.shared.data(for: request)
        try check(response, data: responseData)
        return try JSONDecoder().decode(Message.self, from: responseData)
    }

    private func request<T: Decodable>(_ path: String, token providedToken: String? = nil,
                                       method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let data = try await perform(path, token: providedToken, method: method, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private func perform(_ path: String, token providedToken: String? = nil, method: String = "GET",
                         body: [String: Any]? = nil) async throws -> Data {
        guard let auth = providedToken ?? token,
              let url = URL(string: "https://discord.com/api/v10" + path) else { throw ClientError.message("Not logged in.") }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("Bot \(auth)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DiscordBotClient iOS", forHTTPHeaderField: "User-Agent")
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        return data
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.message("Invalid server response.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429, let retry = try? JSONDecoder().decode(RateLimit.self, from: data) {
                throw ClientError.message("Rate limited by Discord. Retry after \(Int(ceil(retry.retry_after))) seconds.")
            }
            let api = try? JSONDecoder().decode(APIError.self, from: data)
            throw ClientError.message(api?.message ?? "Discord API error (\(http.statusCode)).")
        }
    }

    func disconnect() { reconnectTask?.cancel(); reconnectTask = nil; disconnectSocket(); token = nil; sessionID = nil; resumeGatewayURL = nil; sequence = nil; status = "Disconnected" }
    private func disconnectSocket() {
        heartbeatTask?.cancel(); receiveTask?.cancel(); socket?.cancel(with: .goingAway, reason: nil)
        socket = nil; socketSession?.invalidateAndCancel(); socketSession = nil
    }
    private func scheduleReconnect() {
        guard reconnectTask == nil, token != nil else { return }
        reconnectTask = Task {
            var delay: UInt64 = 1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await openGateway()
                if socket != nil { break }
                delay = min(delay * 2, 30)
            }
            reconnectTask = nil
        }
    }
    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(bots) { UserDefaults.standard.set(data, forKey: "botProfiles") }
    }
}

private struct BotAccount: Decodable { let id: String; let username: String; let avatar: String?; let bot: Bool? }
private struct GatewayDiscovery: Decodable { let url: String }
private struct BotApplication: Decodable { let flags: Int }
private struct RateLimit: Decodable { let retry_after: Double }
private struct APIError: Decodable { let message: String }
private enum ClientError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}
