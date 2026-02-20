//
//  LocalConnectionManager.swift
//  PeerToPeerMessaging
//
//  Based on Apple's sample code for connecting iPadOS and visionOS apps

import Foundation
import Network
import os

/// Manages peer-to-peer connections over the local network using Bonjour
@MainActor
@Observable
public final class LocalConnectionManager {

    /// Configuration for the connection manager
    public struct Configuration: Sendable {
        public var serviceType: String
        public var loggerSubsystem: String
        public var loggerCategory: String

        public init(
            serviceType: String,
            loggerSubsystem: String = "com.peer-to-peer",
            loggerCategory: String = "LocalConnection"
        ) {
            self.serviceType = serviceType
            self.loggerSubsystem = loggerSubsystem
            self.loggerCategory = loggerCategory
        }
    }

    private let logger: Logger
    private let configuration: Configuration

    /// The service type for Bonjour discovery
    private var serviceType: String { configuration.serviceType }

    /// Network browser for discovering peers
    private var browser: NWBrowser?

    /// Active connection to a peer
    private var connection: NWConnection?

    /// Listener for incoming connections (visionOS side)
    private var listener: NWListener?

    /// Connection state
    public enum ConnectionState: Sendable {
        case disconnected
        case searching
        case connecting
        case connected
    }

    public private(set) var state: ConnectionState = .disconnected

    /// Available peers discovered
    public private(set) var availablePeers: [NWBrowser.Result] = []

    /// Callback for received messages
    public var onMessageReceived: ((Data) async -> Void)?

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.logger = Logger(
            subsystem: configuration.loggerSubsystem,
            category: configuration.loggerCategory
        )
    }

    // MARK: - iOS: Start browsing for visionOS devices

    /// Start browsing for available visionOS peers (called from iOS)
    public func startBrowsing() {
        logger.info("Starting to browse for peers")

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] newState in
            self?.logger.info("Browser state: \(String(describing: newState))")

            Task { @MainActor [weak self] in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.state = .searching
                case .failed(let error):
                    self.logger.error("Browser failed: \(error.localizedDescription)")
                    self.state = .disconnected
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.availablePeers = Array(results)
                self.logger.info("Found \(results.count) peers")
            }
        }

        browser.start(queue: .main)
    }

    /// Connect to a discovered peer (called from iOS)
    public func connect(to result: NWBrowser.Result) {
        logger.info("🔵 Connecting to peer")

        guard case .service(let name, let type, let domain, _) = result.endpoint else {
            logger.error("🔴 Invalid endpoint")
            return
        }

        logger.info("🔵 Service details - name: \(name), type: \(type), domain: \(domain)")

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        logger.info("🔵 Setting up connection")
        setupConnection(connection)
        connection.start(queue: .main)

        state = .connecting
    }

    // MARK: - visionOS: Start listening for connections

    /// Start listening for incoming connections (called from visionOS)
    public func startListening(deviceName: String = "VisionPro") {
        logger.info("🟢 Starting to listen for connections with name: \(deviceName)")

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        // Allow local network connections
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters)

            // Set up Bonjour service advertisement
            listener.service = NWListener.Service(name: deviceName, type: serviceType, domain: nil, txtRecord: nil)

            self.listener = listener

            listener.stateUpdateHandler = { [weak self] newState in
                self?.logger.info("🟢 Listener state: \(String(describing: newState))")

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch newState {
                    case .ready:
                        self.logger.info("🟢 Listener ready")
                        self.state = .searching
                    case .failed(let error):
                        self.logger.error("🔴 Listener failed: \(error.localizedDescription)")
                        self.state = .disconnected
                    case .cancelled:
                        self.logger.info("🟡 Listener cancelled")
                        self.state = .disconnected
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] newConnection in
                guard let self else { return }
                self.logger.info("🟢 Received new connection")

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Accept only one connection at a time
                    if self.connection == nil {
                        self.logger.info("🟢 Accepting new connection")
                        self.connection = newConnection
                        self.setupConnection(newConnection)
                        newConnection.start(queue: .main)
                        self.state = .connected
                    } else {
                        self.logger.warning("🟡 Rejecting connection - already connected")
                        newConnection.cancel()
                    }
                }
            }

            listener.start(queue: .main)
            logger.info("🟢 Listener started successfully")

        } catch {
            logger.error("🔴 Failed to create listener: \(error.localizedDescription)")
        }
    }

    // MARK: - Connection Management

    private func setupConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] newState in
            self?.logger.info("Connection state: \(String(describing: newState))")

            Task { @MainActor [weak self] in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.state = .connected
                    self.receiveMessage()
                case .failed(let error):
                    self.logger.error("Connection failed: \(error.localizedDescription)")
                    self.state = .disconnected
                    self.connection = nil
                case .cancelled:
                    self.state = .disconnected
                    self.connection = nil
                default:
                    break
                }
            }
        }
    }

    private func receiveMessage() {
        // Receive message length (4 bytes)
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, let data, error == nil else {
                if let error {
                    self?.logger.error("Receive error: \(error.localizedDescription)")
                }
                return
            }

            let length = data.withUnsafeBytes { $0.load(as: UInt32.self) }

            // Receive actual message
            self.connection?.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] messageData, _, _, error in
                guard let self, let messageData, error == nil else {
                    if let error {
                        self?.logger.error("Receive message error: \(error.localizedDescription)")
                    }
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.onMessageReceived?(messageData)

                    // Continue receiving
                    if !isComplete {
                        self.receiveMessage()
                    }
                }
            }
        }
    }

    /// Send a message to the connected peer
    public func send(_ data: Data) {
        guard let connection, connection.state == .ready else {
            logger.warning("Cannot send: connection not ready")
            return
        }

        // Send length prefix
        var length = UInt32(data.count)
        let lengthData = Data(bytes: &length, count: 4)

        connection.send(content: lengthData, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.logger.error("Send length error: \(error.localizedDescription)")
                return
            }

            // Send actual data
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.logger.error("Send data error: \(error.localizedDescription)")
                } else {
                    self?.logger.info("Message sent successfully")
                }
            })
        })
    }

    /// Disconnect from current peer
    public func disconnect() {
        logger.info("🔴 Disconnecting from peer")

        // Cancel connection gracefully
        connection?.forceCancel()
        connection = nil

        Task { @MainActor in
            self.state = .disconnected
        }
    }

    /// Stop browsing or listening
    public func stop() {
        logger.info("🔴 Stopping connection manager")

        // Stop browser
        browser?.cancel()
        browser = nil

        // Stop listener (only on visionOS)
        if listener != nil {
            logger.info("🔴 Stopping listener")
            listener?.cancel()
            listener = nil
        }

        // Disconnect any active connection
        disconnect()
    }

    /// Restart browsing (useful for reconnection)
    public func restartBrowsing() {
        logger.info("🔄 Restarting browsing")
        stop()

        // Small delay to ensure cleanup
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            await MainActor.run {
                self.startBrowsing()
            }
        }
    }

    /// Reset connection state (useful when stuck in connecting/preparing state)
    public func resetConnectionState() {
        logger.info("🔄 Resetting connection state")

        // Force cancel any existing connection
        connection?.forceCancel()
        connection = nil

        // Cancel browser if active
        browser?.cancel()
        browser = nil

        // Reset state
        Task { @MainActor in
            self.state = .disconnected
            self.availablePeers.removeAll()
        }
    }
}
