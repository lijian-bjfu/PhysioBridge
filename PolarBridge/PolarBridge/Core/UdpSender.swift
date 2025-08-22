import Foundation
import Network

final class UdpSender {

    private var connection: NWConnection
    private var host: NWEndpoint.Host
    private var port: NWEndpoint.Port

    init(host: String, port: UInt16) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.udp
        self.connection = NWConnection(host: self.host, port: self.port, using: params)
        self.connection.start(queue: .global(qos: .utility))
    }

    /// 运行时更新目标地址（若未变化则不重建连接）
    func update(host: String, port: UInt16) {
        let newHost = NWEndpoint.Host(host)
        guard let newPort = NWEndpoint.Port(rawValue: port) else { return }
        if newHost == self.host && newPort == self.port { return }
        // 先取消旧连接
        self.connection.cancel()
        // 建立新连接
        self.host = newHost
        self.port = newPort
        let params = NWParameters.udp
        self.connection = NWConnection(host: self.host, port: self.port, using: params)
        self.connection.start(queue: .global(qos: .utility))
    }

    func send(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}



