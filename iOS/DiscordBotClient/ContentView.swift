import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @EnvironmentObject private var model: DiscordClientModel
    @State private var showLogin = false
    @State private var showChannels = false
    @State private var showSettings = false
    @State private var showFilePicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var composeText = ""
    @State private var editingMessage: Message?
    @State private var editText = ""

    var body: some View {
        Group {
            if model.selectedBot == nil {
                welcome
            } else {
                chat
            }
        }
        .task { model.restoreProfiles() }
        .tint(Color(red: 0.40, green: 0.46, blue: 0.98))
        .sheet(isPresented: $showLogin) { TokenLoginView() }
        .sheet(isPresented: $showChannels) { channelDrawer }
        .sheet(isPresented: $showSettings) { settingsView }
        .sheet(item: $editingMessage) { message in
            editSheet(message)
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { model.error = "Could not read that file."; return }
            Task { await model.send(composeText, attachment: data, filename: url.lastPathComponent); composeText = "" }
        }
        .onChange(of: selectedPhoto) { _, photo in
            guard let photo else { return }
            Task {
                if let data = try? await photo.loadTransferable(type: Data.self) {
                    await model.send(composeText, attachment: data, filename: "photo.jpg")
                    composeText = ""
                }
                selectedPhoto = nil
            }
        }
        .alert("Discord Bot Client", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var welcome: some View {
        ZStack {
            Color(red: 0.08, green: 0.09, blue: 0.12).ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 54)).foregroundStyle(.indigo)
                Text("Discord Bot Client").font(.largeTitle.bold())
                Text("Connect a bot token to open its servers and channels.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button { showLogin = true } label: {
                    Label("Add bot", systemImage: "plus")
                        .font(.headline).frame(maxWidth: .infinity).padding()
                        .background(.indigo, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
            }.padding(32).frame(maxWidth: 420)
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            header
            if !model.guilds.isEmpty { serverRail }
            Divider().overlay(.white.opacity(0.06))
            if let channel = model.selectedChannel {
                messageList
                composer(channel: channel)
            } else {
                ContentUnavailableView("Choose a channel", systemImage: "number", description: Text("Choose a server, then select one of its text channels."))
                    .frame(maxHeight: .infinity)
            }
        }
        .background(Color(red: 0.08, green: 0.09, blue: 0.12).ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(model.bots) { bot in
                    Button { Task { await model.switchBot(bot) } } label: {
                        Label(bot.username, systemImage: bot.id == model.selectedBotID ? "checkmark.circle.fill" : "circle")
                    }
                }
                Divider()
                Button { showLogin = true } label: { Label("Add bot profile", systemImage: "plus") }
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            } label: {
                HStack(spacing: 8) {
                    botAvatar(model.selectedBot, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.selectedBot?.username ?? "Bot").font(.subheadline.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(model.status.hasPrefix("Connected") ? .green : .orange).frame(width: 6, height: 6)
                            Text(model.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Spacer(minLength: 2)
            Button { showChannels = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "number")
                    Text(model.selectedChannel?.displayName ?? "Channels").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }.font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 9)
                    .background(.white.opacity(0.07), in: Capsule())
            }.buttonStyle(.plain).disabled(model.guilds.isEmpty && model.directMessages.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var serverRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.guilds) { guild in
                    Button {
                        model.selectGuild(guild)
                        showChannels = true
                    } label: {
                        HStack(spacing: 8) {
                            guildIcon(guild, size: 34)
                            Text(guild.name).font(.caption.weight(.medium)).lineLimit(1)
                        }.padding(.horizontal, 10).padding(.vertical, 7)
                            .background(model.selectedGuildID == guild.id ? .indigo.opacity(0.28) : .white.opacity(0.05), in: Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { message in
                        MessageRow(message: message, isOwn: message.author.id == model.selectedBotID)
                            .id(message.id)
                            .contextMenu {
                                if message.author.id == model.selectedBotID {
                                    Button("Edit", systemImage: "pencil") { editText = message.content; editingMessage = message }
                                    Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.delete(message) } }
                                }
                                Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content }
                            }
                    }
                }.padding(.horizontal, 14).padding(.vertical, 16)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.count) { _, _ in
                if let id = model.messages.last?.id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .overlay {
                if model.messages.isEmpty {
                    ContentUnavailableView("No messages yet", systemImage: "bubble.left", description: Text("Messages will appear here."))
                }
            }
        }
    }

    private func composer(channel: Channel) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            Menu {
                PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("Choose photo", systemImage: "photo") }
                Button { showFilePicker = true } label: { Label("Choose file", systemImage: "paperclip") }
            } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 26)).foregroundStyle(.secondary).padding(.bottom, 7)
            }
            TextField("Message #\(channel.displayName)", text: $composeText, axis: .vertical)
                .lineLimit(1...5).padding(.horizontal, 14).padding(.vertical, 10)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                .submitLabel(.send).onSubmit(sendMessage)
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 29)).foregroundStyle(composeText.isEmpty ? .secondary : .indigo)
            }.disabled(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.bottom, 4)
        }.padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(red: 0.10, green: 0.11, blue: 0.15))
    }

    private func sendMessage() {
        let text = composeText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        composeText = ""
        Task { await model.send(text) }
    }

    private var channelDrawer: some View {
        NavigationStack {
            List {
                Section("Servers") {
                    ForEach(model.guilds) { guild in
                        Button {
                            model.selectGuild(guild)
                        } label: {
                            HStack(spacing: 10) {
                                guildIcon(guild, size: 32)
                                Text(guild.name).foregroundStyle(.primary)
                                Spacer()
                                if model.selectedGuildID == guild.id { Image(systemName: "checkmark").foregroundStyle(.indigo) }
                            }
                        }
                    }
                }
                if !model.directMessages.isEmpty {
                    Section("Direct messages") {
                        ForEach(model.directMessages) { channel in
                            Button {
                                model.selectChannel(channel)
                                showChannels = false
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "bubble.left.fill").foregroundStyle(.secondary)
                                    Text(channel.displayName).foregroundStyle(.primary)
                                    Spacer()
                                    if channel.id == model.selectedChannel?.id { Image(systemName: "checkmark").foregroundStyle(.indigo) }
                                }
                            }
                        }
                    }
                }
                if let guild = model.guilds.first(where: { $0.id == model.selectedGuildID }) {
                    Section(guild.name) {
                        ForEach(guild.channels.filter(\.isTextChannel)) { channel in
                            Button {
                                model.selectChannel(channel)
                                showChannels = false
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: channel.type == 5 ? "megaphone" : "number").foregroundStyle(.secondary)
                                    VStack(alignment: .leading) {
                                        Text(channel.displayName).foregroundStyle(.primary)
                                        if let topic = channel.topic, !topic.isEmpty { Text(topic).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer()
                                    if channel.id == model.selectedChannel?.id { Image(systemName: "checkmark").foregroundStyle(.indigo) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Servers & channels").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showChannels = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private var settingsView: some View {
        NavigationStack {
            List {
                Section("Bot profiles") {
                    ForEach(model.bots) { bot in
                        HStack { botAvatar(bot, size: 36); Text(bot.username); Spacer(); if bot.id == model.selectedBotID { Text("Active").font(.caption).foregroundStyle(.secondary) } }
                            .swipeActions {
                                Button("Remove", role: .destructive) { model.removeBot(bot) }
                            }
                    }
                    Button { showSettings = false; showLogin = true } label: { Label("Add bot profile", systemImage: "plus") }
                }
                Section("Connection") {
                    LabeledContent("Status", value: model.status)
                    Button("Disconnect", role: .destructive) { model.disconnect() }
                }
                Section {
                    Text("Tokens are stored in the iOS Keychain. Gateway events and REST actions follow the bot’s enabled intents and Discord permissions.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showSettings = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func editSheet(_ message: Message) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit message").font(.headline)
                TextEditor(text: $editText).scrollContentBackground(.hidden).padding(8)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)).frame(minHeight: 140)
                Spacer()
            }.padding()
                .navigationTitle("Edit message").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { editingMessage = nil } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") {
                            let text = editText; editingMessage = nil
                            Task { await model.edit(message, content: text) }
                        }.disabled(editText.isEmpty)
                    }
                }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    @ViewBuilder private func botAvatar(_ bot: BotIdentity?, size: CGFloat) -> some View {
        if let bot, let avatar = bot.avatar, let url = URL(string: "https://cdn.discordapp.com/avatars/\(bot.id)/\(avatar).png?size=96") {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { avatarFallback(bot.username) }
                .frame(width: size, height: size).clipShape(Circle())
        } else { avatarFallback(bot?.username ?? "Bot").frame(width: size, height: size) }
    }

    private func avatarFallback(_ name: String) -> some View {
        Text(String(name.prefix(1)).uppercased()).font(.headline).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.indigo.opacity(0.7), in: Circle())
    }

    @ViewBuilder private func guildIcon(_ guild: Guild, size: CGFloat) -> some View {
        if let icon = guild.icon, let url = URL(string: "https://cdn.discordapp.com/icons/\(guild.id)/\(icon).png?size=96") {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { guildFallback(guild.name) }
                .frame(width: size, height: size).clipShape(Circle())
        } else { guildFallback(guild.name).frame(width: size, height: size) }
    }
    private func guildFallback(_ name: String) -> some View {
        Text(String(name.prefix(1)).uppercased()).font(.caption.weight(.bold)).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.10), in: Circle())
    }
}

private struct TokenLoginView: View {
    @EnvironmentObject private var model: DiscordClientModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "key.fill").font(.largeTitle).foregroundStyle(.indigo)
                Text("Connect a bot").font(.title2.bold())
                Text("Use a bot token from the Discord Developer Portal. It will be saved in this device’s Keychain.")
                    .font(.subheadline).foregroundStyle(.secondary)
                SecureField("Bot token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(14).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                if let error = model.error {
                    Text(error).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await model.connect(token: token); if model.error == nil { dismiss() } }
                } label: {
                    HStack { if model.isConnecting { ProgressView().tint(.white) }; Text(model.isConnecting ? "Connecting…" : "Connect") }
                        .font(.headline).frame(maxWidth: .infinity).padding()
                        .background(.indigo, in: RoundedRectangle(cornerRadius: 13))
                }.disabled(token.isEmpty || model.isConnecting).buttonStyle(.plain)
                Spacer()
            }.padding(24)
                .navigationTitle("Bot profile").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

private struct MessageRow: View {
    let message: Message
    let isOwn: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(message.author.username).font(.subheadline.weight(.semibold))
                    if message.author.bot == true { Text("BOT").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 2).background(.indigo, in: RoundedRectangle(cornerRadius: 3)) }
                    Text(Self.timestamp(message.timestamp)).font(.caption2).foregroundStyle(.secondary)
                    if message.edited_timestamp != nil { Text("(edited)").font(.caption2).foregroundStyle(.secondary) }
                }
                if !message.content.isEmpty {
                    Text(LocalizedStringKey(message.content)).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array((message.embeds ?? []).enumerated()), id: \.offset) { _, embed in EmbedCard(embed: embed) }
                ForEach(message.attachments ?? [], id: \.id) { attachment in AttachmentPreview(attachment: attachment) }
            }
            Spacer(minLength: 8)
        }
        .padding(10).background(isOwn ? .indigo.opacity(0.09) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
    }

    private var avatar: some View {
        Group {
            if let avatar = message.author.avatar,
               let url = URL(string: "https://cdn.discordapp.com/avatars/\(message.author.id)/\(avatar).png?size=80") {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Circle().fill(.indigo.opacity(0.4)) }
            } else {
                Text(String(message.author.username.prefix(1)).uppercased()).font(.caption.bold()).frame(maxWidth: .infinity, maxHeight: .infinity).background(.indigo.opacity(0.45))
            }
        }.frame(width: 34, height: 34).clipShape(Circle())
    }
    private static func timestamp(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct EmbedCard: View {
    let embed: Message.Embed
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = embed.title { Text(title).font(.subheadline.bold()) }
            if let description = embed.description { Text(LocalizedStringKey(description)).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let urlString = embed.image?.url ?? embed.thumbnail?.url, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in image.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 9)) }
                    placeholder: { ProgressView() }.frame(maxHeight: 250)
            }
            if let urlString = embed.url, let url = URL(string: urlString) { Link(url.host ?? "Open link", destination: url).font(.caption) }
        }.padding(10).frame(maxWidth: 440, alignment: .leading)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Color.indigo).frame(width: 3).padding(.vertical, 2) }
    }
}

private struct AttachmentPreview: View {
    let attachment: Message.Attachment
    var body: some View {
        if attachment.content_type?.hasPrefix("image/") == true, let url = URL(string: attachment.url) {
            AsyncImage(url: url) { image in image.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 9)) }
                placeholder: { ProgressView() }.frame(maxWidth: 380, maxHeight: 280)
        } else if let url = URL(string: attachment.url) {
            Link(destination: url) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill").font(.title2).foregroundStyle(.indigo)
                    VStack(alignment: .leading) { Text(attachment.filename).lineLimit(1); if let size = attachment.size { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) } }
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }.padding(11).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain)
        }
    }
}
