import Foundation
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting

/// A call planned with someone in a private chat: when, and for how long.
///
/// It is an ordinary text message, so it reads well in any Telegram app:
///
///     📞 Call scheduled for Thursday, November 7 at 10:00 (GMT+3) · 30 min
///
/// The date carries a link (`tg://scheduled-call?from=<caller>&to=<callee>&call=<id>&at=<unix time>&min=<minutes>&tz=<minutes
/// from GMT>&t=<checksum of the text>`) that lets this app show the message as a call card in everyone's own time. The one
/// called accepts it with a reply that carries the same link with `accepted=1`. The checksum ties the link to the text it
/// was written with: a message whose text says anything else stays an ordinary message, so nothing is hidden behind a card.
public struct ScheduledCall: Equatable {
    public static let durations: [Int32] = [15, 30, 45, 60]
    static let linkPrefix = "tg://scheduled-call?"

    public let id: Int64
    public let callerId: EnginePeer.Id
    public let calleeId: EnginePeer.Id
    /// When, in seconds since 1970 (UTC).
    public let timestamp: Int32
    public let durationMinutes: Int32
    /// The caller's offset from GMT when it was scheduled, in seconds.
    public let callerUtcOffset: Int32

    public init(id: Int64, callerId: EnginePeer.Id, calleeId: EnginePeer.Id, timestamp: Int32, durationMinutes: Int32, callerUtcOffset: Int32) {
        self.id = id
        self.callerId = callerId
        self.calleeId = calleeId
        self.timestamp = timestamp
        self.durationMinutes = durationMinutes
        self.callerUtcOffset = callerUtcOffset
    }

    public var idString: String {
        return String(UInt64(bitPattern: self.id), radix: 36)
    }

    /// When it ends (never past the largest time there is).
    public var endTimestamp: Int32 {
        return Int32(clamping: Int64(self.timestamp) + Int64(self.durationMinutes) * 60)
    }

    /// The call can be started from ten minutes before its time until it is over.
    public func isCallable(now: Int32) -> Bool {
        return Int64(now) >= Int64(self.timestamp) - 10 * 60 && now < self.endTimestamp
    }

    public func isOver(now: Int32) -> Bool {
        return now >= self.endTimestamp
    }

    // MARK: - Message

    /// The day, time and zone of the call as the caller sees it, written out in full (12 or 24 hours as the language has it).
    public static func fullDateString(timestamp: Int32, utcOffset: Int32, strings: PresentationStrings) -> String {
        let formatter = DateFormatter()
        formatter.locale = localeWithStrings(strings)
        formatter.timeZone = TimeZone(secondsFromGMT: Int(utcOffset))
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMdjmm")
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp))) + " (" + ScheduledCall.zoneName(utcOffset: utcOffset) + ")"
    }

    public static func zoneName(utcOffset: Int32) -> String {
        let hours = abs(utcOffset) / 3600
        let minutes = (abs(utcOffset) % 3600) / 60
        let sign = utcOffset < 0 ? "-" : "+"
        if minutes == 0 {
            return "GMT\(sign)\(hours)"
        } else {
            return String(format: "GMT%@%d:%02d", sign, hours, minutes)
        }
    }

    public func messageText(strings: PresentationStrings) -> (text: String, entities: [MessageTextEntity]) {
        let date = ScheduledCall.fullDateString(timestamp: self.timestamp, utcOffset: self.callerUtcOffset, strings: strings)
        let text = strings.ScheduledCall_MessageText(date, strings.ScheduledCall_Minutes("\(self.durationMinutes)").string).string
        return (text, ScheduledCall.dateEntities(text: text, date: date, url: self.link(accepted: false, text: text)))
    }

    static func dateEntities(text: String, date: String, url: String) -> [MessageTextEntity] {
        let range = (text as NSString).range(of: date)
        guard range.location != NSNotFound else {
            return []
        }
        return [MessageTextEntity(range: range.location ..< range.location + range.length, type: .TextUrl(url: url))]
    }

    func link(accepted: Bool, text: String) -> String {
        var components = URLComponents()
        components.scheme = "tg"
        components.host = "scheduled-call"
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "from", value: "\(self.callerId.id._internalGetInt64Value())"),
            URLQueryItem(name: "to", value: "\(self.calleeId.id._internalGetInt64Value())"),
            URLQueryItem(name: "call", value: self.idString),
            URLQueryItem(name: "at", value: "\(self.timestamp)"),
            URLQueryItem(name: "min", value: "\(self.durationMinutes)"),
            URLQueryItem(name: "tz", value: "\(self.callerUtcOffset / 60)"),
            URLQueryItem(name: "t", value: ScheduledCall.checksum(text))
        ]
        if accepted {
            queryItems.append(URLQueryItem(name: "accepted", value: "1"))
        }
        components.queryItems = queryItems
        return components.string ?? ""
    }

    /// FNV-1a of the text, as 8 hex digits. Spaces, line breaks and invisible format characters are left out, so that
    /// the way a server or an app treats them does not matter.
    static func checksum(_ text: String) -> String {
        var hash: UInt32 = 2166136261
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator, .control, .format:
                continue
            default:
                break
            }
            var value = scalar.value
            for _ in 0 ..< 4 {
                hash ^= value & 0xff
                hash = hash &* 16777619
                value >>= 8
            }
        }
        return String(format: "%08x", hash)
    }

    /// The longest text that may be shown as a card: what the app writes, in any language, is well under it.
    static let maxTextLength = 240

    /// The call a message schedules, if it is one: the text the caller's app wrote, sent by the caller in the private
    /// chat of the two, as the account (one of them) sees it. Not forwarded, no media, not from or to a bot.
    public static func parse(message: EngineRawMessage, accountPeerId: EnginePeer.Id) -> ScheduledCall? {
        guard let link = ScheduledCallLink(message: message), !link.isAcceptance, let authorId = message.author?.id else {
            return nil
        }
        let callerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(link.callerValue))
        let calleeId = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(link.calleeValue))
        let chatPeerId = message.id.peerId
        // Sent by the caller; the account is one of the two and the chat is the other one.
        guard authorId == callerId, callerId != calleeId, (callerId == accountPeerId && calleeId == chatPeerId) || (calleeId == accountPeerId && callerId == chatPeerId) else {
            return nil
        }
        return ScheduledCall(id: link.callId, callerId: callerId, calleeId: calleeId, timestamp: link.timestamp, durationMinutes: link.durationMinutes, callerUtcOffset: link.utcOffset)
    }
}

/// The one called saying yes: a reply to the scheduled call.
public struct ScheduledCallAcceptance: Equatable {
    public let callId: Int64
    public let accepterId: EnginePeer.Id
    public let timestamp: Int32
    public let durationMinutes: Int32
    /// The message of the call it answers.
    public let callMessageId: EngineMessage.Id

    public static func messageText(call: ScheduledCall, strings: PresentationStrings) -> (text: String, entities: [MessageTextEntity]) {
        let date = ScheduledCall.fullDateString(timestamp: call.timestamp, utcOffset: call.callerUtcOffset, strings: strings)
        let text = strings.ScheduledCall_AcceptedText(date).string
        return (text, ScheduledCall.dateEntities(text: text, date: date, url: call.link(accepted: true, text: text)))
    }

    public static func parse(message: EngineRawMessage) -> ScheduledCallAcceptance? {
        guard let link = ScheduledCallLink(message: message), link.isAcceptance, let accepterId = message.author?.id else {
            return nil
        }
        guard let reply = message.attributes.first(where: { $0 is ReplyMessageAttribute }) as? ReplyMessageAttribute, reply.messageId.peerId == message.id.peerId else {
            return nil
        }
        return ScheduledCallAcceptance(callId: link.callId, accepterId: accepterId, timestamp: link.timestamp, durationMinutes: link.durationMinutes, callMessageId: reply.messageId)
    }

    /// Whether this accepts `call`, sent in `callMessage`: it answers that very message, for the same time and length,
    /// from the one called.
    public func accepts(_ call: ScheduledCall, callMessage: EngineRawMessage) -> Bool {
        return self.callMessageId == callMessage.id && self.callId == call.id && self.timestamp == call.timestamp && self.durationMinutes == call.durationMinutes && self.accepterId == call.calleeId
    }
}

/// The link of a scheduled call or of its acceptance, read from a message.
private struct ScheduledCallLink {
    /// The largest value a peer id can hold.
    static let maxPeerIdValue: Int64 = 0x00ffffffffffffff

    let callId: Int64
    let callerValue: Int64
    let calleeValue: Int64
    let timestamp: Int32
    let durationMinutes: Int32
    let utcOffset: Int32
    let isAcceptance: Bool

    init?(message: EngineRawMessage) {
        // A message of the chat itself (not a scheduled or quick reply one) in a private chat with a person: text with no
        // media (a link preview aside), not forwarded, not through a bot, not restricted.
        guard message.id.peerId.namespace == Namespaces.Peer.CloudUser, message.id.namespace == Namespaces.Message.Cloud || message.id.namespace == Namespaces.Message.Local, message.forwardInfo == nil, message.media.allSatisfy({ $0 is TelegramMediaWebpage }) else {
            return nil
        }
        if let user = message.peers[message.id.peerId] as? TelegramUser, user.botInfo != nil {
            return nil
        }
        if let author = message.author as? TelegramUser, author.botInfo != nil {
            return nil
        }
        for attribute in message.attributes {
            if attribute is InlineBotMessageAttribute || attribute is RestrictedContentMessageAttribute {
                return nil
            }
        }
        guard let entities = message.textEntitiesAttribute?.entities else {
            return nil
        }
        let length = (message.text as NSString).length
        var found: ScheduledCallLink?
        for entity in entities {
            guard case let .TextUrl(url) = entity.type, url.hasPrefix(ScheduledCall.linkPrefix), let components = URLComponents(string: url) else {
                continue
            }
            // One call per message.
            if found != nil {
                return nil
            }
            var values: [String: String] = [:]
            for item in components.queryItems ?? [] {
                values[item.name] = item.value ?? ""
            }
            // The text must be the one the link was written with; the people real ids; the time no earlier than a day
            // before the message and no later than 400 days after it; the zone a real one.
            let messageTime = Int64(message.timestamp)
            guard entity.range.upperBound <= length, values["t"] == ScheduledCall.checksum(message.text), let callString = values["call"], let callValue = UInt64(callString, radix: 36), let caller = values["from"].flatMap(Int64.init), (1 ... ScheduledCallLink.maxPeerIdValue).contains(caller), let callee = values["to"].flatMap(Int64.init), (1 ... ScheduledCallLink.maxPeerIdValue).contains(callee), let timestamp = values["at"].flatMap(Int32.init), (messageTime - 86400 ... messageTime + 400 * 86400).contains(Int64(timestamp)), let minutes = values["min"].flatMap(Int32.init), minutes >= 5, minutes <= 240, let offset = values["tz"].flatMap(Int32.init), (-14 * 60 ... 14 * 60).contains(offset) else {
                return nil
            }
            // Nothing else may hide behind the card: a single short line that names the call's zone (and, for the call
            // itself, its length), as the text the app writes does.
            let isAcceptance = values["accepted"] == "1"
            let zone = ScheduledCall.zoneName(utcOffset: offset * 60)
            guard length <= ScheduledCall.maxTextLength, !message.text.contains(where: { $0.isNewline }), message.text.contains(zone), isAcceptance || message.text.contains("\(minutes)") else {
                return nil
            }
            found = ScheduledCallLink(callId: Int64(bitPattern: callValue), callerValue: caller, calleeValue: callee, timestamp: timestamp, durationMinutes: minutes, utcOffset: offset * 60, isAcceptance: isAcceptance)
        }
        guard let found else {
            return nil
        }
        self = found
    }

    private init(callId: Int64, callerValue: Int64, calleeValue: Int64, timestamp: Int32, durationMinutes: Int32, utcOffset: Int32, isAcceptance: Bool) {
        self.callId = callId
        self.callerValue = callerValue
        self.calleeValue = calleeValue
        self.timestamp = timestamp
        self.durationMinutes = durationMinutes
        self.utcOffset = utcOffset
        self.isAcceptance = isAcceptance
    }
}

public extension EngineRawMessage {
    /// Whether the message is a scheduled call or the acceptance of one, as the account sees it: shown in the middle like
    /// a service message. Anything that only looks like one stays an ordinary message.
    func isScheduledCallMessage(accountPeerId: EnginePeer.Id) -> Bool {
        guard self.id.peerId.namespace == Namespaces.Peer.CloudUser, let entities = self.textEntitiesAttribute?.entities, entities.contains(where: { entity in
            if case let .TextUrl(url) = entity.type {
                return url.hasPrefix(ScheduledCall.linkPrefix)
            }
            return false
        }) else {
            return false
        }
        if ScheduledCall.parse(message: self, accountPeerId: accountPeerId) != nil {
            return true
        }
        return self.verifiedScheduledCallAcceptance(accountPeerId: accountPeerId) != nil
    }

    /// The acceptance this message reports and the call it accepts, if it really accepts that call.
    func verifiedScheduledCallAcceptance(accountPeerId: EnginePeer.Id) -> (acceptance: ScheduledCallAcceptance, call: ScheduledCall, callMessage: EngineRawMessage)? {
        guard let acceptance = ScheduledCallAcceptance.parse(message: self), let callMessage = self.associatedMessages[acceptance.callMessageId], let call = ScheduledCall.parse(message: callMessage, accountPeerId: accountPeerId), acceptance.accepts(call, callMessage: callMessage) else {
            return nil
        }
        return (acceptance, call, callMessage)
    }
}

/// Calls whose cards open with an animation the first time they are shown: the ones just scheduled on this device.
public final class ScheduledCallRevealQueue {
    public static let shared = ScheduledCallRevealQueue()

    private var ids = Set<Int64>()

    public func add(_ callId: Int64) {
        self.ids.insert(callId)
    }

    /// Whether the card of `callId` should open with an animation now (only once).
    public func take(_ callId: Int64) -> Bool {
        return self.ids.remove(callId) != nil
    }
}
