import ActivityKit
import Foundation

/// Shared attributes for Rlink Live Activity (Dynamic Island + Lock Screen)
struct RlinkActivityAttributes: ActivityAttributes {
    /// Static context — doesn't change during the activity
    public struct ContentState: Codable, Hashable {
        var connectedPeers: Int
        var lastSender: String
        var lastMessage: String
        var timestamp: Date
        var signalLevel: Int // 0=none, 1=weak, 2=medium, 3=strong
        /// 0 — сеть BLE (устройства рядом), 1 — отправка крупного медиа через relay
        var uiMode: Int
        /// 0...1 при uiMode == 1
        var mediaProgress: Double
        var mediaLabel: String
    }

    /// Fixed data set at activity start
    var sessionId: String
}
