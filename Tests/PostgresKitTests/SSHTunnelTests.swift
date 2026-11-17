import Foundation
import Testing
@testable import PostgresKit

@Suite("SSH tunnel arguments")
struct SSHTunnelTests {
    private let remote = Endpoint(host: "db.internal", port: 5432)

    private func arguments(_ authentication: SSHTunnelConfiguration.Authentication) throws -> [String] {
        let configuration = SSHTunnelConfiguration(host: "bastion.example", username: "ops", authentication: authentication,
                                                   privateKeyPath: authentication == .privateKey ? "~/.ssh/id_ed25519" : nil)
        return try SSHTunnel.arguments(for: configuration, localPort: 54321, remote: remote)
    }

    /// The tunnel's ssh neither becomes nor joins a shared master:
    /// - with only `ControlMaster=no`, ssh still connects as a client to a master the user's `~/.ssh/config` set up
    ///   (`ControlMaster auto` + `ControlPath`); that master then owns the forwarded port, which keeps forwarding after
    ///   the tunnel is closed, and the profile's authentication is never used;
    /// - without `ControlMaster=no`, `ControlMaster auto` makes the tunnel the master, and closing its window cuts the
    ///   user's sessions multiplexed over it.
    /// `ControlPath=none` applies to this ssh only: the user's own sessions keep their master.
    @Test(arguments: SSHTunnelConfiguration.Authentication.allCases)
    func aTunnelNeverUsesOrBecomesASharedMaster(authentication: SSHTunnelConfiguration.Authentication) throws {
        let arguments = try arguments(authentication)
        let options = zip(arguments, arguments.dropFirst()).filter { $0.0 == "-o" }.map(\.1)
        let control = options.filter { $0.lowercased().hasPrefix("control") }
        #expect(control.filter { $0.lowercased().hasPrefix("controlmaster") } == ["ControlMaster=no"])
        #expect(control.filter { $0.lowercased().hasPrefix("controlpath") } == ["ControlPath=none"])
        #expect(!control.contains { $0.lowercased().hasPrefix("controlpersist") })
        // No other way to name a control socket or become a master: `-S path`, `-M`.
        #expect(!arguments.contains("-S"))
        #expect(!arguments.contains("-M"))
        // Options come before the destination, which is last.
        #expect(arguments.last == "ops@bastion.example")
        let lastOption = try #require(arguments.lastIndex(of: "-o"))
        #expect(lastOption < arguments.count - 2)
    }

    @Test func theForwardTargetsTheServer() throws {
        let arguments = try arguments(.agent)
        let forward = try #require(arguments.firstIndex(of: "-L"))
        #expect(arguments[forward + 1] == "127.0.0.1:54321:db.internal:5432")
        #expect(arguments.contains("ExitOnForwardFailure=yes"))
    }
}
