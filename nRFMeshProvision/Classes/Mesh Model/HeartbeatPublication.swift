/*
* Copyright (c) 2019, Nordic Semiconductor
* All rights reserved.
*
* Redistribution and use in source and binary forms, with or without modification,
* are permitted provided that the following conditions are met:
*
* 1. Redistributions of source code must retain the above copyright notice, this
*    list of conditions and the following disclaimer.
*
* 2. Redistributions in binary form must reproduce the above copyright notice, this
*    list of conditions and the following disclaimer in the documentation and/or
*    other materials provided with the distribution.
*
* 3. Neither the name of the copyright holder nor the names of its contributors may
*    be used to endorse or promote products derived from this software without
*    specific prior written permission.
*
* THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
* ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
* WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
* IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
* INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
* NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
* PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
* WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
* ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
* POSSIBILITY OF SUCH DAMAGE.
*/

import Foundation

public class HeartbeatPublication: Codable {
    
    internal class PeriodicHeartbeatState {
        /// The current publication count.
        ///
        /// This is set by the Config Heartbeat Publication Set message and decremented
        /// each time a Heartbeat message is sent, until it reaches 0, which means that
        /// periodic Heartbeat messages are disabled.
        ///
        /// Possible values are:
        /// - 0 - Periodic Heartbeats are disabled.
        /// - 1 - 0xFFFE - Number of remaining Heartbeat messages to be sent.
        /// - 0xFFFF - Periodic Heartbeat messages are published indefinitely.
        private var count: UInt16
        
        /// Number of Heartbeat messages remaining to be sent, represented as 2^(n-1) seconds.
        internal var countLog: UInt8 {
            switch count {
            case 0x00:
                // Periodic Heartbeats are disabled.
                return 0x00
            case 0xFFFF:
                // Periodic Heartbeat messages are published indefinitely.
                return 0xFF
            default:
                // The Heartbeat Publication Count Log value between 0x01 and 0x11 shall
                // represent that smallest integer n where 2^(n-1) is greater than or equal
                // to the Heartbeat Publication Count value.
                
                // For example, if the Heartbeat Publication Count value is 0x0579, then
                // the Heartbeat Publication Count Log value would be 0x0C.
                return UInt8(log2(Double(count) * 2 - 1)) + 1
            }
        }
        
        init?(_ countLog: UInt8) {
            switch countLog {
            case 0x00:
                // Periodic Heartbeat messages are not published.
                return nil
            case let exponent where exponent >= 1 && exponent <= 0x10:
                count = UInt16(pow(2.0, Double(exponent - 1)))
            case 0x11:
                // Maximum possible value.
                count = 0xFFFE
            case 0xFF:
                // Periodic Heartbeat messages are published indefinitely.
                count = 0xFFFF
            default:
                // Invalid value.
                return nil
            }
        }
        
        /// Returns whether periodic Heartbeat message should be sent, or not.
        /// - returns: True, if Heartmeat control message should be sent;
        ///            false otherwise.
        func shouldSendPeriodicHeartbeatMessage() -> Bool {
            guard count > 0 else {
                return false
            }
            guard count < 0xFFFF else {
                return true
            }
            count = count - 1
            return count == 0
        }
    }
    /// The periodic heartbeat state contains variables used for handling sending
    /// periodic Heartbeat mesasges from the local Node.
    internal var state: PeriodicHeartbeatState?
    
    /// The destination address for the Heartbeat messages.
    /// 
    /// It can be either a Group or Unicast Address.
    public let address: Address
    /// The Heartbeat Publication Period Log state is an 8-bit value that controls
    /// the period between the publication of two consecutive periodical Heartbeat
    /// transport control messages. The value is represented as 2^(n-1) seconds.
    ///
    /// Period Log equal to 0 means periodic Heartbeat publications are disabled.
    /// Value 0xFF means 0xFFFF seconds.
    internal let periodLog: UInt8
    /// The cadence of periodical Heartbeat messages in seconds.
    public var period: UInt16 {
        return Self.periodLog2Period(periodLog)
    }
    /// The TTL (Time to Live) value for the Heartbeat messages.
    public let ttl: UInt8
    /// The index property contains an integer that represents a Network Key Index,
    /// indicating which network key to use for the Heartbeat publication.
    ///
    /// The Network Key Index corresponds to the index value of one of the Network Key
    /// entries in Node `networkKeys` array.
    public let networkKeyIndex: KeyIndex
    /// An array of features that trigger sending Heartbeat messages when changed.
    public let features: [NodeFeature]
    
    internal init(twoToThePower countLog: UInt8, heartbeatsTo address: Address,
                  everyTwoToThePower periodLog: UInt8, secondsWithTtl ttl: UInt8,
                  using networkKey: NetworkKey, on features: [NodeFeature]) {
        self.state = PeriodicHeartbeatState(countLog)
        self.address = address
        self.periodLog = periodLog
        self.ttl = ttl
        self.networkKeyIndex = networkKey.index
        self.features = features
    }
    
    // MARK: - Codable
    
    private enum CodingKeys: String, CodingKey {
        case address
        case period
        case ttl
        case networkKeyIndex = "index"
        case features
    }
    
    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let addressAsString = try container.decode(String.self, forKey: .address)
        guard let address = Address(hex: addressAsString) else {
            throw DecodingError.dataCorruptedError(forKey: .address, in: container,
                                                   debugDescription: "Address must be 4-character hexadecimal string.")
        }
        guard address.isUnicast || address.isGroup else {
            throw DecodingError.dataCorruptedError(forKey: .address, in: container,
                                                   debugDescription: "\(addressAsString) is not a unicast or group address.")
        }
        self.address = address
        let period = try container.decode(UInt16.self, forKey: .period)
        guard let periodLog = Self.period2PeriodLog(period) else {
            throw DecodingError.dataCorruptedError(forKey: .period, in: container,
                                                   debugDescription: "Period must be power of 2 or 0xFFFF.")
        }
        self.periodLog = periodLog
        let ttl = try container.decode(UInt8.self, forKey: .ttl)
        guard ttl <= 127 else {
            throw DecodingError.dataCorruptedError(forKey: .ttl, in: container,
                                                   debugDescription: "TTL must be in range 0-127.")
        }
        self.ttl = ttl
        self.networkKeyIndex = try container.decode(KeyIndex.self, forKey: .networkKeyIndex)
        self.features = try container.decode([NodeFeature].self, forKey: .features)
        
        // On reset or import periodic Heartbeat messages are stopped.
        self.state = nil
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(address.hex, forKey: .address)
        try container.encode(period, forKey: .period)
        try container.encode(ttl, forKey: .ttl)
        try container.encode(networkKeyIndex, forKey: .networkKeyIndex)
        try container.encode(features, forKey: .features)
    }
}

private extension HeartbeatPublication {
    
    /// Converts Publication Period to Publication Period Log.
    /// - Parameter value: The value.
    /// - Returns: The logaritmic value.
    static func period2PeriodLog(_ value: UInt16) -> UInt8? {
        switch value {
        case 0x0000:
            // Periodic Heartbeat messages are not published.
            return 0x00
        case 0xFFFF:
            // Maximum value.
            return 0x11
        default:
            let exponent = UInt8(log2(Double(value) * 2 - 1)) + 1
            guard pow(2.0, Double(exponent - 1)) == Double(value) else {
                // Ensure power of 2.
                return nil
            }
            return exponent
        }
    }
    
    /// Converts Publication Period Log to Publicaton Period.
    /// - Parameter periodLog: The logaritmic value in range 0x00...0x11.
    /// - Returns: The value.
    static func periodLog2Period(_ periodLog: UInt8) -> UInt16 {
        switch periodLog {
        case 0x00:
            // Periodic Heartbeat messages are not published.
            return 0x0000
        case let exponent where exponent >= 0x01 && exponent <= 0x10:
            // Period = 2^(n-1) seconds.
            return UInt16(pow(2.0, Double(exponent - 1)))
        case 0x11:
            // Maximum value.
            return 0xFFFF
        default:
            fatalError("PeriodLog out or range: \(periodLog) (required: 0x00-0x11)")
        }
    }
    
}
