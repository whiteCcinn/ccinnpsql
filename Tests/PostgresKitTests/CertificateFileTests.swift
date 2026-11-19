import Darwin
import Foundation
import Testing
@testable import PostgresKit

/// The CA file named in a profile (possibly an imported one) is read only when it is a bounded regular file.
@Suite("CA certificate file")
struct CertificateFileTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnpsql-ca-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aDeviceIsRefusedWithoutReadingIt() {
        let started = ContinuousClock.now
        #expect(TLSSetup.readCertificateFile(atPath: "/dev/zero") == nil)
        #expect(throws: PostgresError.self) { try TLSSetup.loadCertificates(path: "/dev/zero") }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aPipeIsRefusedWithoutBlocking() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("ca.pem").path
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(TLSSetup.readCertificateFile(atPath: fifo) == nil, "no writer ever opens it; a blocking open would hang here")
    }

    @Test func aDirectoryOrAnOversizedFileIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(TLSSetup.readCertificateFile(atPath: directory.path) == nil)
        let large = directory.appendingPathComponent("large.pem")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(TLSSetup.maximumCertificateFileBytes) + 1)
        try handle.close()
        #expect(TLSSetup.readCertificateFile(atPath: large.path) == nil)
        #expect(TLSSetup.readCertificateFile(atPath: directory.appendingPathComponent("missing.pem").path) == nil)
    }

    @Test func aBundleIsStillReadThroughASymbolicLink() throws {
        let bundle = "/etc/ssl/cert.pem" // /etc is a link to /private/etc on macOS
        guard FileManager.default.fileExists(atPath: bundle) else { return }
        #expect(try TLSSetup.loadCertificates(path: bundle).count > 10)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let small = directory.appendingPathComponent("ca.pem")
        try Data("-----BEGIN CERTIFICATE-----\nnot base64\n-----END CERTIFICATE-----\n".utf8).write(to: small)
        #expect(TLSSetup.readCertificateFile(atPath: small.path)?.isEmpty == false)
        #expect(throws: PostgresError.self) { try TLSSetup.loadCertificates(path: small.path) }
    }
}
