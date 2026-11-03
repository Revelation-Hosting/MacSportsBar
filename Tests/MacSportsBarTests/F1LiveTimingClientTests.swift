import XCTest
import Network
import CryptoKit
@testable import MacSportsBar

/// The F1 live-timing *connection*, against a real WebSocket on loopback — still hermetic (nothing
/// leaves the machine), but it exercises `URLSessionWebSocketTask` itself, whose behaviour is the
/// whole point: its `receive()` ignores the request timeout, so only our watchdog bounds it.
final class F1LiveTimingClientTests: XCTestCase {

    func testSnapshotGivesUpWhenTheSocketGoesSilent() async throws {
        // Regression: a Mac that slept mid-read left `receive()` waiting on a dead socket forever,
        // which stalled the poll loop for every league — the menu bar sat on a race's lap 1 for
        // three days. A server that upgrades and then never speaks reproduces that exactly.
        let server = try SilentWebSocketServer()
        let port = try await server.start()
        defer { server.stop() }

        let client = F1LiveTimingClient(timeout: 1)
        let request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/signalrcore")!)

        // An expectation, not a plain `await`: without the watchdog the read never returns, and
        // this should fail the test rather than hang the suite.
        let gaveUp = expectation(description: "the read is abandoned at the deadline")
        Task {
            do {
                _ = try await client.readSnapshot(request, session: .shared)
                XCTFail("a silent socket can't produce a snapshot")
            } catch {
                gaveUp.fulfill()
            }
        }
        await fulfillment(of: [gaveUp], timeout: 5)
    }
}

/// A loopback WebSocket server that completes the upgrade handshake and then never sends a byte —
/// what the client sees when the connection dies silently underneath it.
private final class SilentWebSocketServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SilentWebSocketServer")
    /// Accepted connections, held so they stay open (and silent) for the length of the test.
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Start listening and return the port the system picked.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        let ready = AsyncStream<Result<UInt16, Error>> { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: continuation.yield(.success(listener.port?.rawValue ?? 0))
                case .failed(let error): continuation.yield(.failure(error))
                default: return
                }
                continuation.finish()
            }
        }
        listener.start(queue: queue)
        for await result in ready { return try result.get() }
        throw NWError.posix(.ECANCELED)
    }

    func stop() {
        queue.sync { connections.forEach { $0.cancel() } }
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
            guard let data, let key = Self.webSocketKey(in: data) else { return }
            let accept = Data(Insecure.SHA1.hash(
                data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                + "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .idempotent)
            // …and then silence: no further receive, no send, the socket just stays open.
        }
    }

    private static func webSocketKey(in request: Data) -> String? {
        String(decoding: request, as: UTF8.self)
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("sec-websocket-key:") }
            .map { $0.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) }
    }
}
