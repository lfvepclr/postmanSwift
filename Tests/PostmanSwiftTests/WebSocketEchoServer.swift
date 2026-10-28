import Foundation
import Network
import CryptoKit

/// Minimal RFC 6455 echo server used only by the test target.
final class WebSocketEchoServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "postmanswift.ws.echo")
    private var connections: [ObjectIdentifier: EchoConnection] = [:]
    let port: UInt16

    init(port: UInt16? = nil) throws {
        let chosen = port ?? UInt16.random(in: 20000...42000)
        self.port = chosen
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: chosen) else {
            throw NSError(domain: "WebSocketEchoServer", code: 1)
        }
        listener = try NWListener(using: parameters, on: endpointPort)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("WebSocketEchoServer failed: \(error)")
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        for connection in connections.values {
            connection.connection.cancel()
        }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let echo = EchoConnection(connection: connection)
        connections[ObjectIdentifier(connection)] = echo
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: ObjectIdentifier(connection))
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(echo)
    }

    private func receive(_ echo: EchoConnection) {
        echo.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                echo.buffer.append(contentsOf: data)
                self.process(echo)
            }
            if error == nil && !isComplete {
                self.receive(echo)
            }
        }
    }

    private func process(_ echo: EchoConnection) {
        if !echo.handshakeDone {
            guard let headerEnd = Self.findHeaderEnd(echo.buffer) else { return }
            let headerBytes = Array(echo.buffer[..<headerEnd])
            echo.buffer.removeFirst(headerEnd)
            let header = String(decoding: headerBytes, as: UTF8.self)
            guard let key = Self.headerValue("sec-websocket-key", in: header) else {
                echo.connection.cancel()
                return
            }
            let accept = Self.acceptKey(key)
            let response = """
            HTTP/1.1 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Accept: \(accept)\r
            \r

            """
            echo.connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            echo.handshakeDone = true
        }

        while true {
            guard let frame = Self.parseFrame(echo.buffer) else { return }
            echo.buffer.removeFirst(frame.consumed)
            switch frame.opcode {
            case 0x1, 0x2:
                echo.sendFrame(opcode: frame.opcode, payload: frame.payload)
            case 0x8:
                echo.sendFrame(opcode: 0x8, payload: frame.payload)
                echo.connection.cancel()
                return
            case 0x9:
                echo.sendFrame(opcode: 0xA, payload: frame.payload)
            default:
                break
            }
        }
    }

    private static func findHeaderEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) {
            if bytes[index] == 13, bytes[index + 1] == 10, bytes[index + 2] == 13, bytes[index + 3] == 10 {
                return index + 4
            }
        }
        return nil
    }

    private static func headerValue(_ name: String, in header: String) -> String? {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func acceptKey(_ key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }

    private struct Frame {
        var opcode: UInt8
        var payload: Data
        var consumed: Int
    }

    private static func parseFrame(_ bytes: [UInt8]) -> Frame? {
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            var value: UInt64 = 0
            for index in 2..<10 { value = (value << 8) | UInt64(bytes[index]) }
            length = Int(value)
            offset = 10
        }
        let maskLength = masked ? 4 : 0
        guard bytes.count >= offset + maskLength + length else { return nil }
        var payload = Array(bytes[(offset + maskLength)..<(offset + maskLength + length)])
        if masked {
            let mask = Array(bytes[offset..<(offset + 4)])
            for index in payload.indices {
                payload[index] ^= mask[index % 4]
            }
        }
        return Frame(opcode: opcode, payload: Data(payload), consumed: offset + maskLength + length)
    }
}

private final class EchoConnection {
    let connection: NWConnection
    var buffer: [UInt8] = []
    var handshakeDone = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func sendFrame(opcode: UInt8, payload: Data) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 65535 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            var length = UInt64(payload.count)
            var bytes: [UInt8] = []
            for _ in 0..<8 {
                bytes.insert(UInt8(length & 0xFF), at: 0)
                length >>= 8
            }
            frame.append(contentsOf: bytes)
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }
}
