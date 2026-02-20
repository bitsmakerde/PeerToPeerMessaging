# PeerToPeerMessaging

Local network peer-to-peer messaging framework for iOS and visionOS communication.

## Overview

This package enables direct communication between iOS and visionOS devices over the local network using Bonjour service discovery and Network framework connections.

## Features

- **Automatic Discovery**: iOS devices can browse for available visionOS devices
- **Secure Local Connection**: Uses Network framework for reliable TCP connections
- **Type-Safe Messages**: Codable message types for car configuration commands
- **Bidirectional Communication**: Send commands and receive acknowledgments

## Architecture

### Components

1. **LocalConnectionManager**: Core connection management
   - iOS: Browse for peers and initiate connections
   - visionOS: Listen for incoming connections

2. **P2PMessage Protocol**: Base for all message types
   - SelectCarMessage: Load a specific car model
   - ChangeCarColorMessage: Update car body color
   - ChangeInteriorColorMessage: Update interior color
   - ChangeInteriorSeatColorMessage: Update seat color
   - OpenDoorsMessage: Open/close doors
   - ToggleLightsMessage: Toggle lights on/off
   - AcknowledgmentMessage: Confirm message receipt

3. **P2PMessageCoder**: Message encoding/decoding utilities

## Usage

### iOS (Advisor App)

```swift
import PeerToPeerMessaging

let connectionManager = LocalConnectionManager()

// Start browsing for visionOS devices
connectionManager.startBrowsing()

// Connect to a discovered peer
connectionManager.connect(to: peer)

// Send a message
let message = SelectCarMessage(carModelName: "A6_glb")
let data = try P2PMessageCoder.encode(message)
connectionManager.send(data)
```

### visionOS (Customer App)

```swift
import PeerToPeerMessaging

let connectionManager = LocalConnectionManager()

// Setup message handler
connectionManager.onMessageReceived = { data in
    let message = try P2PMessageCoder.decode(data)
    // Handle message
}

// Start listening
connectionManager.startListening(deviceName: "Audi Vision Pro")
```

## Configuration

### Info.plist Requirements

Both iOS and visionOS apps need:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app needs access to the local network to connect with devices.</string>
<key>NSBonjourServices</key>
<array>
    <string>_audiconfigurator._tcp</string>
</array>
```

## Implementation Details

### Service Type

The Bonjour service type is: `_audiconfigurator._tcp`

### Message Protocol

Messages are sent with a length prefix:
1. 4 bytes: Message length (UInt32)
2. N bytes: JSON-encoded message

### Connection Flow

1. visionOS starts listening with Bonjour advertisement
2. iOS browses for services
3. iOS connects to selected visionOS device
4. Both sides can send/receive messages
5. Messages are acknowledged automatically

## Based on Apple Sample Code

This implementation is based on Apple's sample:
[Connecting iPadOS and visionOS Apps Over the Local Network](https://developer.apple.com/documentation/visionos/connecting-ipados-and-visionos-apps-over-the-local-network)
# PeerToPeerMessaging
