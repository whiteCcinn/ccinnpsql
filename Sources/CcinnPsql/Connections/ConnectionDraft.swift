import CcinnPsqlKit
import Foundation
import Observation
import PostgresKit

/// Editable copy of a connection profile plus its secrets, with "Test connection".
@MainActor
@Observable
final class ConnectionDraft {
    enum TestState: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String)
    }

    let profileID: UUID?
    var name: String
    var color: ProfileColor
    var isFavorite: Bool
    var host: String
    var port: Int
    var username: String
    var password: String
    var database: String
    var sslMode: SSLMode
    var sslNegotiation: SSLNegotiation
    var rootCertificatePath: String
    var poolingMode: PoolingMode
    var allowCleartextPassword: Bool
    var confirmMutations: Bool
    var connectTimeout: Double
    var mcpAccess: MCPAccess
    var sshEnabled: Bool
    var ssh: SSHTunnelConfiguration
    var sshSecret: String
    var testState: TestState = .idle

    private let original: ConnectionProfile?
    private var testTask: Task<Void, Never>?

    init(profile: ConnectionProfile?, store: ProfileStore) {
        original = profile
        profileID = profile?.id
        let base = profile ?? ConnectionProfile(color: .blue)
        name = base.name
        color = base.color
        isFavorite = base.isFavorite
        host = base.host
        port = base.port
        username = base.username
        password = profile.flatMap(store.password(for:)) ?? ""
        database = base.database
        sslMode = base.sslMode
        sslNegotiation = base.sslNegotiation
        rootCertificatePath = base.rootCertificatePath ?? ""
        poolingMode = base.poolingMode
        allowCleartextPassword = base.allowCleartextPassword
        confirmMutations = base.confirmMutations
        connectTimeout = base.connectTimeout
        mcpAccess = base.mcpAccess
        sshEnabled = base.ssh != nil
        ssh = base.ssh ?? SSHTunnelConfiguration(host: "", username: NSUserName(), authentication: .agent)
        sshSecret = profile.flatMap(store.sshSecret(for:)) ?? ""
    }

    func makeProfile() -> ConnectionProfile {
        var profile = original ?? ConnectionProfile()
        profile.name = name.trimmingCharacters(in: .whitespaces)
        profile.color = color
        profile.isFavorite = isFavorite
        profile.host = host.trimmingCharacters(in: .whitespaces)
        profile.port = port
        profile.username = username.trimmingCharacters(in: .whitespaces)
        profile.database = database.trimmingCharacters(in: .whitespaces)
        profile.sslMode = sslMode
        profile.sslNegotiation = sslNegotiation
        profile.rootCertificatePath = rootCertificatePath.nilIfEmpty
        profile.poolingMode = poolingMode
        profile.allowCleartextPassword = allowCleartextPassword
        profile.confirmMutations = confirmMutations
        profile.connectTimeout = connectTimeout.isFinite ? min(max(connectTimeout, 1), 120) : 10
        profile.mcpAccess = mcpAccess
        profile.ssh = sshEnabled ? ssh : nil
        return profile
    }

    var validationErrors: [String] { makeProfile().validationErrors }
    var isValid: Bool { validationErrors.isEmpty }

    func test() {
        testTask?.cancel()
        let profile = makeProfile()
        let password = password
        let sshSecret = sshEnabled && ssh.authentication != .agent ? sshSecret : nil
        testState = .running("Connecting to \(profile.endpoint)…")
        let report: @Sendable (String) -> Void = { status in
            Task { @MainActor in
                if case .running = self.testState { self.testState = .running(status) }
            }
        }
        testTask = Task {
            do {
                let client = try await ConnectionOpener.open(profile: profile, password: password, sshSecret: sshSecret, progress: report)
                let info = client.serverInfo
                let databases = info.isPgBouncerConsole ? 0 : ((try? await client.databases().count) ?? 0)
                await client.close()
                guard !Task.isCancelled else { return }
                var message = "Connected to \(info.productSummary)"
                message += info.tlsDescription.map { " · \($0)" } ?? " · unencrypted"
                if info.pooler != .none { message += " · \(info.pooler.displayName)" }
                if databases > 0 { message += " · \(databases) databases" }
                message += " · \(info.currentUser)"
                testState = .succeeded(message)
            } catch {
                guard !Task.isCancelled else { return }
                testState = .failed(describe(error))
            }
        }
    }

    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testState = .idle
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
