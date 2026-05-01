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

    /// Name of the currently connected peer (set on connect, cleared on disconnect)
    public private(set) var connectedPeerName: String?

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
        connectedPeerName = name

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
                    self.connectedPeerName = nil
                case .cancelled:
                    self.state = .disconnected
                    self.connection = nil
                    self.connectedPeerName = nil
                default:
                    break
                }
            }
        }
    }

    private func receiveMessage() {
        // Receive message length (4 bytes)
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                if let error {
                    self?.logger.error("Receive error: \(error.localizedDescription)")
                }
                return
            }

            let length = data.withUnsafeBytes { $0.load(as: UInt32.self) }

            // Sanity-check to avoid waiting forever on a corrupt length value
            guard length > 0, length < 10_000_000 else {
                self.logger.error("Invalid message length \(length) — skipping and reconnecting receive loop")
                self.receiveMessage()
                return
            }

            // Receive actual message — use inner isComplete, not the header's
            self.connection?.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] messageData, _, isComplete, error in
                guard let self, let messageData, error == nil else {
                    if let error {
                        self?.logger.error("Receive message error: \(error.localizedDescription)")
                    }
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.onMessageReceived?(messageData)

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

        // Prepend length and payload into a single packet so they are always
        // sent atomically. Two separate sends could interleave with another
        // concurrent send and corrupt the length-framing on the receiver.
        var length = UInt32(data.count)
        var packet = Data(bytes: &length, count: 4)
        packet.append(data)

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.logger.error("Send error: \(error.localizedDescription)")
            }
        })
    }

    /// Disconnect from current peer
    public func disconnect() {
        logger.info("🔴 Disconnecting from peer")

        connection?.forceCancel()
        connection = nil
        connectedPeerName = nil

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
