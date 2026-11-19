import Foundation
import os
import Security
import PostgresKit

public enum ProfileColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray
    public var id: String { rawValue }
}

/// Whether AI clients may use a connection through the built-in MCP server.
public enum MCPAccess: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled
    case readOnly
    case readWrite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disabled: "Off"
        case .readOnly: "Read-only"
        case .readWrite: "Read & write"
        }
    }
}

/// A saved connection. Never contains secrets: passwords live in a `SecretStore` (the Keychain).
public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var color: ProfileColor
    public var isFavorite: Bool
    public var host: String
    public var port: Int
    public var username: String
    /// Database to connect to (`postgres` when empty).
    public var database: String
    public var sslMode: SSLMode
    public var sslNegotiation: SSLNegotiation
    /// PEM file with trusted roots for verify-ca / verify-full.
    public var rootCertificatePath: String?
    public var ssh: SSHTunnelConfiguration?
    public var allowCleartextPassword: Bool
    /// How session state is treated behind poolers (auto-detected unless overridden).
    public var poolingMode: PoolingMode
    /// Ask before running statements that change data or schema.
    public var confirmMutations: Bool
    public var connectTimeout: Double
    /// AI access through the MCP server (off unless the user opts in).
    public var mcpAccess: MCPAccess
    /// Allow read-only AI access even when the role can run server programs or touch server files (a superuser, or a member
    /// of pg_execute_server_program / pg_read_server_files / pg_write_server_files), which no read-only check can prevent.
    /// Off unless the user opts in for this connection.
    public var mcpAllowPrivilegedRole: Bool
    public var createdAt: Date
    public var lastConnectedAt: Date?
    /// Set on every save; backups use it to tell which side of a conflict is newer.
    public var updatedAt: Date?
    /// Whether an AI may write knowledge (notes, relationships, glossary) for this connection's schemas. Knowledge is
    /// local to this Mac and never changes the server, so it is allowed on read-only AI access too.
    public var mcpKnowledgeWrites: Bool = true

    public init(id: UUID = UUID(), name: String = "", host: String = "127.0.0.1", port: Int = 5432, username: String = "postgres",
                database: String = "postgres", sslMode: SSLMode = .prefer, sslNegotiation: SSLNegotiation = .postgres,
                rootCertificatePath: String? = nil, color: ProfileColor = .none, isFavorite: Bool = false, ssh: SSHTunnelConfiguration? = nil,
                allowCleartextPassword: Bool = false, poolingMode: PoolingMode = .auto, confirmMutations: Bool = false,
                connectTimeout: Double = 10, mcpAccess: MCPAccess = .disabled, mcpAllowPrivilegedRole: Bool = false, createdAt: Date = Date(),
                lastConnectedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.database = database
        self.sslMode = sslMode
        self.sslNegotiation = sslNegotiation
        self.rootCertificatePath = rootCertificatePath
        self.color = color
        self.isFavorite = isFavorite
        self.ssh = ssh
        self.allowCleartextPassword = allowCleartextPassword
        self.poolingMode = poolingMode
        self.confirmMutations = confirmMutations
        self.connectTimeout = connectTimeout
        self.mcpAccess = mcpAccess
        self.mcpAllowPrivilegedRole = mcpAllowPrivilegedRole
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    /// Tolerant decoding: fields added in later versions fall back to their defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = (try? container.decodeIfPresent(ProfileColor.self, forKey: .color)) ?? .none
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 5432
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? "postgres"
        database = try container.decodeIfPresent(String.self, forKey: .database) ?? "postgres"
        sslMode = (try? container.decodeIfPresent(SSLMode.self, forKey: .sslMode)) ?? .prefer
        sslNegotiation = (try? container.decodeIfPresent(SSLNegotiation.self, forKey: .sslNegotiation)) ?? .postgres
        rootCertificatePath = try container.decodeIfPresent(String.self, forKey: .rootCertificatePath)
        ssh = try container.decodeIfPresent(SSHTunnelConfiguration.self, forKey: .ssh)
        allowCleartextPassword = try container.decodeIfPresent(Bool.self, forKey: .allowCleartextPassword) ?? false
        poolingMode = (try? container.decodeIfPresent(PoolingMode.self, forKey: .poolingMode)) ?? .auto
        confirmMutations = try container.decodeIfPresent(Bool.self, forKey: .confirmMutations) ?? false
        connectTimeout = try container.decodeIfPresent(Double.self, forKey: .connectTimeout) ?? 10
        mcpAccess = (try? container.decodeIfPresent(MCPAccess.self, forKey: .mcpAccess)) ?? .disabled
        mcpAllowPrivilegedRole = (try? container.decodeIfPresent(Bool.self, forKey: .mcpAllowPrivilegedRole)) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        updatedAt = try? container.decodeIfPresent(Date.self, forKey: .updatedAt)
        mcpKnowledgeWrites = (try? container.decodeIfPresent(Bool.self, forKey: .mcpKnowledgeWrites)) ?? true
    }

    public static func recents(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        profiles.filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }

    public var endpoint: Endpoint { Endpoint(host: host.trimmingCharacters(in: .whitespaces), port: port) }

    public var effectiveDatabase: String { database.nilIfBlank ?? "postgres" }

    public var hostSummary: String {
        let base = "\(username)@\(endpoint)/\(effectiveDatabase)"
        if let ssh { return "\(base) via \(ssh.host)" }
        return base
    }

    public var displayName: String { name.isEmpty ? endpoint.description : name }

    public func configuration(password: String) -> ConnectionConfiguration {
        let timeout = connectTimeout.isFinite ? min(max(1, connectTimeout), 300) : 10
        return ConnectionConfiguration(endpoint: endpoint, username: username.trimmingCharacters(in: .whitespaces), password: password,
                                       database: effectiveDatabase, connectTimeout: timeout, sslMode: sslMode, sslNegotiation: sslNegotiation,
                                       rootCertificatePath: rootCertificatePath?.nilIfBlank, tlsServerName: endpoint.host,
                                       allowCleartextPassword: allowCleartextPassword)
    }

    /// Problems that prevent connecting, for inline form validation.
    public var validationErrors: [String] {
        var errors: [String] = []
        if host.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter the server host") }
        if !(1...65_535).contains(port) { errors.append("Port must be between 1 and 65535") }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter a user name") }
        if sslMode.verifiesChain, let path = rootCertificatePath?.nilIfBlank,
           !FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath) {
            errors.append("The CA certificate file does not exist")
        }
        if sslNegotiation == .direct, sslMode == .disable || sslMode == .prefer {
            errors.append("Direct TLS needs SSL mode Require or stricter")
        }
        if let ssh {
            if ssh.host.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter the SSH host") }
            if ssh.authentication == .privateKey, (ssh.privateKeyPath ?? "").isEmpty { errors.append("Choose an SSH private key") }
        }
        return errors
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Secrets

public struct SecretKey: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case password
        case sshSecret
    }

    public let profileID: UUID
    public let kind: Kind

    public init(profileID: UUID, kind: Kind) {
        self.profileID = profileID
        self.kind = kind
    }

    var account: String { "\(profileID.uuidString).\(kind.rawValue)" }
}

public protocol SecretStore: Sendable {
    func secret(for key: SecretKey) throws -> String?
    /// Stores `value`, or deletes the secret when `value` is nil or empty.
    func setSecret(_ value: String?, for key: SecretKey) throws
}

public struct SecretStoreError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// macOS Keychain (generic passwords, this-device-only, available after first unlock).
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "io.github.whiteccinn.ccinnpsql.connections") {
        self.service = service
    }

    public func secret(for key: SecretKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecretStoreError(message: "Keychain read failed (\(status))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError(message: "Keychain delete failed (\(status))")
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "CcinnPsql connection secret"
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw SecretStoreError(message: "Keychain write failed (\(status))") }
        } else if update != errSecSuccess {
            throw SecretStoreError(message: "Keychain update failed (\(update))")
        }
    }
}

public final class InMemorySecretStore: SecretStore {
    private let storage = OSAllocatedUnfairLock<[SecretKey: String]>(initialState: [:])

    public init() {}

    public func secret(for key: SecretKey) throws -> String? { storage.withLock { $0[key] } }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        storage.withLock { $0[key] = value?.isEmpty == false ? value : nil }
    }
}

// MARK: - Repository

/// Persists profiles as JSON (atomic writes) and their secrets in a `SecretStore`.
public final class ProfileRepository: Sendable {
    public let directory: URL
    private let secrets: any SecretStore

    /// `CCINNPSQL_PROFILE_DIR` overrides the location (used by tests and for portable setups).
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CCINNPSQL_PROFILE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CcinnPsql", isDirectory: true)
    }

    public init(directory: URL = ProfileRepository.defaultDirectory, secrets: any SecretStore = KeychainSecretStore()) {
        self.directory = directory
        self.secrets = secrets
    }

    private var fileURL: URL { directory.appendingPathComponent("connections.json") }

    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(profiles).write(to: fileURL, options: [.atomic])
    }

    public func storeSecrets(for profile: ConnectionProfile, password: String?, sshSecret: String?) throws {
        try secrets.setSecret(password, for: SecretKey(profileID: profile.id, kind: .password))
        try secrets.setSecret(sshSecret, for: SecretKey(profileID: profile.id, kind: .sshSecret))
    }

    public func password(for profile: ConnectionProfile) -> String? {
        try? secrets.secret(for: SecretKey(profileID: profile.id, kind: .password))
    }

    public func sshSecret(for profile: ConnectionProfile) -> String? {
        try? secrets.secret(for: SecretKey(profileID: profile.id, kind: .sshSecret))
    }

    public func delete(_ profile: ConnectionProfile) throws {
        try deleteSecrets(of: profile.id)
    }

    /// Removes a profile's password and SSH secret from the Keychain.
    public func deleteSecrets(of profileID: UUID) throws {
        try secrets.setSecret(nil, for: SecretKey(profileID: profileID, kind: .password))
        try secrets.setSecret(nil, for: SecretKey(profileID: profileID, kind: .sshSecret))
    }
}
