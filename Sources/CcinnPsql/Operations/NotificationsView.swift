import CcinnPsqlKit
import Observation
import PostgresKit
import PostgresWire
import SwiftUI

/// LISTEN/NOTIFY panel: a dedicated listener connection that shows notifications as they arrive.
@MainActor
@Observable
final class NotificationsModel {
    struct Received: Identifiable {
        let id = UUID()
        let date: Date
        let message: NotificationMessage
    }

    unowned let workspace: WorkspaceModel
    let database: String
    var channels: [String] = []
    var received: [Received] = []
    var channelInput = ""
    var notifyChannel = ""
    var notifyPayload = ""
    var error: String?
    var isConnecting = false
    private var listener: PostgresListener?
    private var streamTask: Task<Void, Never>?
    static let maxReceived = 2_000

    init(workspace: WorkspaceModel, database: String) {
        self.workspace = workspace
        self.database = database
    }

    private func ensureListener() async throws -> PostgresListener {
        if let listener { return listener }
        isConnecting = true
        defer { isConnecting = false }
        let opened = try await PostgresListener.open(client: workspace.client, database: database)
        listener = opened
        streamTask = Task { [weak self] in
            for await note in opened.notifications {
                guard let self else { return }
                self.received.insert(Received(date: Date(), message: note), at: 0)
                if self.received.count > Self.maxReceived { self.received.removeLast(self.received.count - Self.maxReceived) }
            }
            self?.listener = nil
            self?.channels = []
        }
        return opened
    }

    func listen() {
        let name = channelInput.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !channels.contains(name) else { return }
        Task {
            do {
                try await ensureListener().listen(name)
                channels.append(name)
                channelInput = ""
                error = nil
                if notifyChannel.isEmpty { notifyChannel = name }
            } catch {
                self.error = describe(error)
            }
        }
    }

    func unlisten(_ name: String) {
        Task {
            do {
                try await listener?.unlisten(name)
                channels.removeAll { $0 == name }
            } catch {
                self.error = describe(error)
            }
        }
    }

    func send() {
        let channel = notifyChannel.trimmingCharacters(in: .whitespaces)
        guard !channel.isEmpty else { return }
        let payload = notifyPayload
        Task {
            do {
                try await ensureListener().notify(channel, payload: payload)
                error = nil
            } catch {
                self.error = describe(error)
            }
        }
    }

    func close() {
        streamTask?.cancel()
        listener?.close()
        listener = nil
    }
}

struct NotificationsView: View {
    @Bindable var model: NotificationsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Channel to LISTEN on", text: $model.channelInput).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .onSubmit { model.listen() }
                Button("Listen") { model.listen() }.disabled(model.channelInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.isConnecting { ProgressView().controlSize(.small) }
                ForEach(model.channels, id: \.self) { channel in
                    HStack(spacing: 4) {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                        Text(channel)
                        Button { model.unlisten(channel) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
                Spacer()
            }
            HStack(spacing: 8) {
                TextField("Channel", text: $model.notifyChannel).textFieldStyle(.roundedBorder).frame(width: 180)
                TextField("Payload", text: $model.notifyPayload).textFieldStyle(.roundedBorder)
                    .onSubmit { model.send() }
                Button("NOTIFY") { model.send() }.disabled(model.notifyChannel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = model.error { ErrorBanner(message: error) { model.error = nil } }
            Table(model.received) {
                TableColumn("Time") { Text($0.date, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(90)
                TableColumn("Channel") { Text($0.message.channel).fontWeight(.medium) }.width(160)
                TableColumn("Sender PID") { Text(String($0.message.processID)).monospacedDigit() }.width(90)
                TableColumn("Payload") { Text($0.message.payload).font(Theme.monospacedSmall).textSelection(.enabled) }
            }
            .overlay {
                if model.received.isEmpty {
                    ContentUnavailableView("No Notifications Yet", systemImage: "bell",
                                           description: Text("Listen on a channel; NOTIFY from any session in \(model.database) appears here immediately."))
                }
            }
        }
        .padding(16)
    }
}
