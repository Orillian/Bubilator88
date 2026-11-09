import Foundation
import Logging
import Network

nonisolated private let serverLog = Logger(label: "App.AutomationServer")

/// The MCP Streamable HTTP transport for the AI tools: `POST /mcp` with one
/// JSON-RPC message, answered with one JSON reply.
///
/// Listens on 127.0.0.1 only. Every request must carry the bearer token, and a
/// request from a web page (an `Origin` other than this server, or a `Host`
/// that is not loopback, as after DNS rebinding) is refused. Server-sent
/// events are not offered: GET is answered 405, which the transport allows.
///
/// Connections, parsing and the handler all run on one serial queue, so tool
/// calls run one at a time in arrival order.
nonisolated final class AutomationHTTPServer: @unchecked Sendable {
  private let port: UInt16
  private let token: String
  /// Runs the tool calls; touched only on `queue`.
  private let handle: (Data) -> Data?
  private let queue = DispatchQueue(label: "com.bubio.bubilator88.automation")
  private var listener: NWListener?
  /// Open connections, closed by `stop()`; touched only on `queue`.
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var stopped = false

  /// Called on the main queue when the server cannot listen.
  var onFailure: (@MainActor @Sendable (String) -> Void)?

  private static let maxHeaderBytes = 16 * 1024
  private static let maxBodyBytes = 1024 * 1024

  init(port: UInt16, token: String, handle: @escaping (Data) -> Data?) {
    self.port = port
    self.token = token
    self.handle = handle
  }

  func start() {
    queue.async { [self] in
      guard !stopped else { return }
      let parameters = NWParameters.tcp
      parameters.acceptLocalOnly = true
      parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
      let listener: NWListener
      do {
        listener = try NWListener(using: parameters)
      } catch {
        report("Cannot listen on port \(port): \(error.localizedDescription)")
        return
      }
      listener.stateUpdateHandler = { [weak self] state in
        guard let self, case .failed(let error) = state else { return }
        report("Cannot listen on port \(port): \(error.localizedDescription)")
        self.listener?.cancel()
        self.listener = nil
      }
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else { return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
          switch state {
          case .failed, .cancelled: self?.connections[id] = nil
          default: break
          }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
      }
      listener.start(queue: queue)
      self.listener = listener
      serverLog.info("Listening on 127.0.0.1:\(port)")
    }
  }

  /// Close the listener and every open connection. `then` runs on the
  /// server's queue once the port is free, so a server started from it can
  /// take the same port.
  func stop(then: (() -> Void)? = nil) {
    queue.async { [self] in
      stopped = true
      for connection in connections.values { connection.cancel() }
      connections.removeAll()
      guard let listener else {
        then?()
        return
      }
      self.listener = nil
      listener.stateUpdateHandler = { state in
        if case .cancelled = state { then?() }
      }
      listener.cancel()
    }
  }

  private func report(_ message: String) {
    serverLog.error("\(message)")
    let onFailure = onFailure
    DispatchQueue.main.async { onFailure?(message) }
  }

  // MARK: - HTTP

  private struct Request {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
  }

  /// Read more of the connection into `buffer` and serve what it holds.
  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      var buffer = buffer
      if let data { buffer.append(data) }
      self?.serve(on: connection, buffer: buffer, ended: isComplete || error != nil)
    }
  }

  /// Answer the requests in `buffer` one at a time, then read for more
  /// unless the client has finished sending.
  private func serve(on connection: NWConnection, buffer: Data, ended: Bool) {
    var buffer = buffer
    switch parse(&buffer) {
    case .request(let request):
      respond(to: request, on: connection) { [weak self] in
        self?.serve(on: connection, buffer: buffer, ended: ended)
      }
    case .incomplete where !ended:
      receive(on: connection, buffer: buffer)
    case .incomplete:
      connection.cancel()
    case .invalid(let status):
      send(status: status, body: nil, on: connection, close: true)
    }
  }

  private enum ParseResult {
    case request(Request)
    case incomplete
    case invalid(Int)
  }

  /// Take one request off the front of `buffer`.
  private func parse(_ buffer: inout Data) -> ParseResult {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerEnd = buffer.range(of: separator) else {
      return buffer.count > Self.maxHeaderBytes ? .invalid(431) : .incomplete
    }
    guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
      return .invalid(400)
    }
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count == 3 else { return .invalid(400) }
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { return .invalid(400) }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    if headers["transfer-encoding"] != nil { return .invalid(501) }
    let length = Int(headers["content-length"] ?? "0") ?? -1
    guard length >= 0 else { return .invalid(400) }
    guard length <= Self.maxBodyBytes else { return .invalid(413) }
    let bodyStart = headerEnd.upperBound
    guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
    let body = Data(buffer[bodyStart..<bodyStart + length])
    buffer = Data(buffer[(bodyStart + length)...])
    let target = String(requestLine[1])
    let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    return .request(Request(method: String(requestLine[0]), path: path, headers: headers, body: body))
  }

  private func respond(to request: Request, on connection: NWConnection, then next: @escaping () -> Void) {
    if let status = refusal(of: request) {
      send(status: status, body: nil, on: connection, close: true)
      return
    }
    guard request.path == "/mcp" else {
      send(status: 404, body: nil, on: connection, close: false, then: next)
      return
    }
    guard request.method == "POST" else {
      send(status: 405, body: nil, on: connection, close: false, extraHeaders: ["Allow: POST"], then: next)
      return
    }
    if let reply = handle(request.body) {
      send(status: 200, body: reply, on: connection, close: false, then: next)
    } else {
      send(status: 202, body: nil, on: connection, close: false, then: next)
    }
  }

  /// The status that refuses `request`, or nil to serve it.
  private func refusal(of request: Request) -> Int? {
    // A browser always sends Host as the name it resolved; after DNS
    // rebinding that is the attacker's name, not a loopback one.
    let host = request.headers["host"].map(Self.hostName) ?? ""
    guard ["127.0.0.1", "localhost", "[::1]"].contains(host) else { return 403 }
    if let origin = request.headers["origin"],
       let url = URL(string: origin), !["127.0.0.1", "localhost"].contains(url.host ?? "") {
      return 403
    }
    guard let authorization = request.headers["authorization"],
          Self.constantTimeEqual(authorization, "Bearer " + token) else { return 401 }
    return nil
  }

  private static func hostName(_ host: String) -> String {
    if host.hasPrefix("[") { return String(host.prefix { $0 != "]" }) + "]" }
    return String(host.prefix { $0 != ":" }).lowercased()
  }

  private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  private func send(status: Int, body: Data?, on connection: NWConnection, close: Bool,
                    extraHeaders: [String] = [], then next: (() -> Void)? = nil) {
    let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                  404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large",
                  431: "Request Header Fields Too Large", 501: "Not Implemented"][status] ?? "Error"
    var head = ["HTTP/1.1 \(status) \(reason)", "Content-Length: \(body?.count ?? 0)"]
    if body != nil { head.append("Content-Type: application/json") }
    if status == 401 { head.append("WWW-Authenticate: Bearer") }
    head += extraHeaders
    head.append(close ? "Connection: close" : "Connection: keep-alive")
    var data = Data((head.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    if let body { data.append(body) }
    connection.send(content: data, completion: .contentProcessed { _ in
      if close {
        connection.cancel()
      } else {
        next?()
      }
    })
  }
}
