import Foundation

/// Hands the connection to open (profile, password in use, …) to a window this process opens. A `WindowRequest` only
/// carries ids, because SwiftUI may persist and restore it, so the payload stays here, in memory, until the new window
/// takes it, exactly once.
///
/// A request without a payload was not created by this process: it is a window macOS restored after a relaunch. Such a
/// window shows the connection screen and never connects by itself.
@MainActor
public final class WindowHandoff<Payload> {
    private var pending: [UUID: Payload] = [:]

    public init() {}

    /// Creates a request for a new window and keeps `payload` until that window takes it.
    public func request(profileID: UUID, payload: Payload) -> WindowRequest {
        let request = WindowRequest(profileID: profileID)
        pending[request.nonce] = payload
        return request
    }

    /// The payload handed to `request`, at most once. `nil` for no request (a plain new window) and for a request this
    /// process did not create (a restored window): both take the same path.
    public func take(_ request: WindowRequest?) -> Payload? {
        guard let request else { return nil }
        return pending.removeValue(forKey: request.nonce)
    }

    /// Payloads not taken yet.
    public var pendingCount: Int { pending.count }
}
