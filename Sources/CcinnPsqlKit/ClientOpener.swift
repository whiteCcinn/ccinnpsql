import Foundation
import PostgresKit

/// Opens a `PostgresClient` for a saved profile, through its SSH tunnel when configured. Shared by the app and the
/// MCP server.
public enum ClientOpener {
    public static func open(profile: ConnectionProfile, password: String, sshSecret: String?, poolSize: Int = 4,
                            progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> PostgresClient {
        let configuration = profile.configuration(password: password)
        var tunnel: SSHTunnel?
        if let ssh = profile.ssh {
            progress("Opening SSH tunnel through \(ssh.host)…")
            tunnel = try await SSHTunnel.open(configuration: ssh, secret: sshSecret, remote: configuration.endpoint)
        }
        progress("Connecting to \(profile.endpoint) as \(profile.username)…")
        do {
            return try await PostgresClient.connect(configuration, poolSize: poolSize, poolingMode: profile.poolingMode, tunnel: tunnel)
        } catch {
            tunnel?.close()
            throw error
        }
    }
}
