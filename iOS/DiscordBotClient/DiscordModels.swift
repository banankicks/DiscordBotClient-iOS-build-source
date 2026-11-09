import Foundation

struct BotIdentity: Codable, Identifiable, Hashable {
    let id: String
    let username: String
    let avatar: String?
    var displayName: String { username }
}

struct Guild: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String?
    var channels: [Channel] = []

    enum CodingKeys: String, CodingKey { case id, name, icon, channels }
    init(id: String, name: String, icon: String?, channels: [Channel] = []) {
        self.id = id; self.name = name; self.icon = icon; self.channels = channels
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        icon = try values.decodeIfPresent(String.self, forKey: .icon)
        channels = try values.decodeIfPresent([Channel].self, forKey: .channels) ?? []
    }
}

struct Channel: Codable, Identifiable, Hashable {
    let id: String
    let type: Int
    let name: String?
    let parent_id: String?
    let topic: String?
    var displayName: String { name ?? "Direct Message" }
    var isTextChannel: Bool { [0, 5, 10, 11, 12].contains(type) }
}

struct Message: Codable, Identifiable, Hashable {
    let id: String
    let channel_id: String
    let content: String
    let timestamp: String
    let author: Author
    let embeds: [Embed]?
    let attachments: [Attachment]?
    let edited_timestamp: String?

    struct Author: Codable, Hashable {
        let id: String
        let username: String
        let avatar: String?
        let bot: Bool?
    }
    struct Embed: Codable, Hashable {
        let title: String?
        let description: String?
        let url: String?
        let color: Int?
        let image: Media?
        let thumbnail: Media?
        struct Media: Codable, Hashable { let url: String? }
    }
    struct Attachment: Codable, Hashable {
        let id: String
        let filename: String
        let url: String
        let content_type: String?
        let size: Int?
    }
}

struct GatewayEnvelope: Decodable {
    let op: Int
    let d: GatewayPayload?
    let s: Int?
    let t: String?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        op = try values.decode(Int.self, forKey: .op)
        d = try? values.decodeIfPresent(GatewayPayload.self, forKey: .d)
        s = try values.decodeIfPresent(Int.self, forKey: .s)
        t = try values.decodeIfPresent(String.self, forKey: .t)
    }

    private enum CodingKeys: String, CodingKey { case op, d, s, t }
}

struct GatewayPayload: Decodable {
    let heartbeat_interval: Double?
    let session_id: String?
    let resume_gateway_url: String?
    let user: BotIdentity?
    let guilds: [Guild]?
    let channels: [Channel]?
    let guild_id: String?
    let channel_id: String?
    let id: String?
    let name: String?
    let icon: String?
    let type: Int?
    let parent_id: String?
    let topic: String?
    let content: String?
    let timestamp: String?
    let author: Message.Author?
    let embeds: [Message.Embed]?
    let attachments: [Message.Attachment]?
    let edited_timestamp: String?
    let message: Message?
}

extension GatewayPayload {
    func messageValue() -> Message? {
        guard let id, let channel_id, let content, let timestamp, let author else { return nil }
        return Message(id: id, channel_id: channel_id, content: content, timestamp: timestamp,
                       author: author, embeds: embeds, attachments: attachments, edited_timestamp: edited_timestamp)
    }

    func guildValue() -> Guild? {
        guard let id, let name else { return nil }
        return Guild(id: id, name: name, icon: icon, channels: channels ?? [])
    }
}
