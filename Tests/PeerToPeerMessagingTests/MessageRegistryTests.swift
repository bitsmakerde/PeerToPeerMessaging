//
//  MessageRegistryTests.swift
//  PeerToPeerMessagingTests
//
//  Tests for the generic message registry system

import XCTest
@testable import PeerToPeerMessaging

final class MessageRegistryTests: XCTestCase {

    // MARK: - Test Message Types

    struct TestMessageA: P2PMessageProtocol {
        static let messageTypeID = "test.messageA"
        let value: String
    }

    struct TestMessageB: P2PMessageProtocol {
        static let messageTypeID = "test.messageB"
        let count: Int
    }

    struct EmptyMessage: P2PMessageProtocol {
        static let messageTypeID = "test.empty"
    }

    // MARK: - Encode/Decode Round-Trip

    @MainActor
    func test_encodeAndDecode_roundTrip() throws {
        let sut = MessageRegistry()
        sut.register(TestMessageA.self)

        let original = TestMessageA(value: "hello")
        let data = try sut.encode(original)
        let decoded = try sut.decode(data)

        let result = try XCTUnwrap(decoded as? TestMessageA)
        XCTAssertEqual(result.value, "hello")
    }

    @MainActor
    func test_decode_unknownType_throwsError() throws {
        let sut = MessageRegistry()
        // Only register TestMessageB, NOT TestMessageA
        sut.register(TestMessageB.self)

        let encoder = JSONEncoder()
        let payload = try encoder.encode(TestMessageA(value: "test"))
        let envelope = MessageEnvelope(typeID: TestMessageA.messageTypeID, payload: payload)
        let data = try encoder.encode(envelope)

        XCTAssertThrowsError(try sut.decode(data)) { error in
            guard case MessageRegistry.RegistryError.unknownMessageType(let typeID) = error else {
                XCTFail("Expected unknownMessageType error, got \(error)")
                return
            }
            XCTAssertEqual(typeID, "test.messageA")
        }
    }

    @MainActor
    func test_multipleTypes_eachDecodesCorrectly() throws {
        let sut = MessageRegistry()
        sut.register(TestMessageA.self)
        sut.register(TestMessageB.self)

        let dataA = try sut.encode(TestMessageA(value: "a"))
        let dataB = try sut.encode(TestMessageB(count: 42))

        let decodedA = try XCTUnwrap(sut.decode(dataA) as? TestMessageA)
        let decodedB = try XCTUnwrap(sut.decode(dataB) as? TestMessageB)

        XCTAssertEqual(decodedA.value, "a")
        XCTAssertEqual(decodedB.count, 42)
    }

    @MainActor
    func test_emptyPayloadMessage_encodesSuccessfully() throws {
        let sut = MessageRegistry()
        sut.register(EmptyMessage.self)

        let data = try sut.encode(EmptyMessage())
        let decoded = try sut.decode(data)

        XCTAssertTrue(decoded is EmptyMessage)
    }

    // MARK: - MessageEnvelope

    func test_messageEnvelope_jsonRoundTrip() throws {
        let payload = Data("test-payload".utf8)
        let envelope = MessageEnvelope(typeID: "test.type", payload: payload)

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(MessageEnvelope.self, from: data)

        XCTAssertEqual(decoded.typeID, "test.type")
        XCTAssertEqual(decoded.payload, payload)
    }

    // MARK: - ConnectionManager

    @MainActor
    func test_connectionManager_initialState_isDisconnected() {
        let sut = LocalConnectionManager(configuration: .init(serviceType: "_test._tcp"))
        XCTAssertEqual(sut.state, .disconnected)
    }

    @MainActor
    func test_connectionManager_disconnect_setsStateToDisconnected() {
        let sut = LocalConnectionManager(configuration: .init(serviceType: "_test._tcp"))
        sut.disconnect()
        XCTAssertEqual(sut.state, .disconnected)
    }

    @MainActor
    func test_connectionManager_initialPeers_isEmpty() {
        let sut = LocalConnectionManager(configuration: .init(serviceType: "_test._tcp"))
        XCTAssertTrue(sut.availablePeers.isEmpty)
    }

    // MARK: - Configuration

    func test_configuration_customServiceType() {
        let config = LocalConnectionManager.Configuration(
            serviceType: "_myapp._tcp",
            loggerSubsystem: "com.myapp",
            loggerCategory: "Network"
        )
        XCTAssertEqual(config.serviceType, "_myapp._tcp")
        XCTAssertEqual(config.loggerSubsystem, "com.myapp")
        XCTAssertEqual(config.loggerCategory, "Network")
    }

    func test_configuration_defaults() {
        let config = LocalConnectionManager.Configuration(serviceType: "_myapp._tcp")
        XCTAssertEqual(config.serviceType, "_myapp._tcp")
        XCTAssertEqual(config.loggerSubsystem, "com.peer-to-peer")
        XCTAssertEqual(config.loggerCategory, "LocalConnection")
    }

    // MARK: - Registry Edge Cases

    @MainActor
    func test_registerSameTypeTwice_doesNotCrash() throws {
        let sut = MessageRegistry()
        sut.register(TestMessageA.self)
        sut.register(TestMessageA.self) // Should not crash

        let data = try sut.encode(TestMessageA(value: "test"))
        let decoded = try XCTUnwrap(sut.decode(data) as? TestMessageA)
        XCTAssertEqual(decoded.value, "test")
    }

    @MainActor
    func test_decode_invalidData_throwsError() {
        let sut = MessageRegistry()
        sut.register(TestMessageA.self)

        let invalidData = Data("not valid json".utf8)

        XCTAssertThrowsError(try sut.decode(invalidData))
    }
}
