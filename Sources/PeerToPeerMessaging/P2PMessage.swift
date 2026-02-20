//
//  P2PMessage.swift
//  PeerToPeerMessaging
//
//  Generic message protocol and registry for peer-to-peer communication

import Foundation

/// Base protocol for all P2P messages.
/// Uses a string-based type identifier so apps can register their own message types.
public protocol P2PMessageProtocol: Codable, Sendable {
    /// Unique string identifier for this message type (e.g., "com.myapp.selectCar")
    static var messageTypeID: String { get }
}

/// Envelope wrapping a message with its type identifier for routing
public struct MessageEnvelope: Codable, Sendable {
    public let typeID: String
    public let payload: Data

    public init(typeID: String, payload: Data) {
        self.typeID = typeID
        self.payload = payload
    }
}

/// Registry for encoding and decoding P2P messages.
/// Apps register their own message types; the registry handles routing on decode.
@MainActor
public final class MessageRegistry: @unchecked Sendable {

    public enum RegistryError: Error, Equatable {
        case unknownMessageType(String)
    }

    private var decoders: [String: @Sendable (Data) throws -> any P2PMessageProtocol] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {}

    /// Register a message type for encoding/decoding
    public func register<T: P2PMessageProtocol>(_ type: T.Type) {
        decoders[T.messageTypeID] = { data in
            try JSONDecoder().decode(T.self, from: data)
        }
    }

    /// Encode a message into Data (envelope with type ID + payload)
    public func encode<T: P2PMessageProtocol>(_ message: T) throws -> Data {
        let payload = try encoder.encode(message)
        let envelope = MessageEnvelope(typeID: T.messageTypeID, payload: payload)
        return try encoder.encode(envelope)
    }

    /// Decode Data into the appropriate registered message type
    public func decode(_ data: Data) throws -> any P2PMessageProtocol {
        let envelope = try decoder.decode(MessageEnvelope.self, from: data)

        guard let decoderFn = decoders[envelope.typeID] else {
            throw RegistryError.unknownMessageType(envelope.typeID)
        }

        return try decoderFn(envelope.payload)
    }
}
