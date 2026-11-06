import Foundation
import SwiftSignalKit
import TelegramCore

/// Which scheduled calls have been accepted, as learned from the replies this app has shown. Kept on the device, so a
/// card keeps its mark when the chat is opened again before the reply is loaded.
///
/// A call is known by its chat, its caller, its id, its time and its length: a copy posted by someone else or in
/// another chat, or the same call moved to another time, is another call. An acceptance counts once its reply has been
/// delivered (it is kept with the id of that reply, and is let go when the reply is deleted or edited into something
/// else); while the reply is still being sent the call counts as accepted only until the sending fails or the reply is
/// deleted.
public final class ScheduledCallStore {
    public struct Key: Hashable {
        public let chatId: EnginePeer.Id
        public let callerId: EnginePeer.Id
        public let callId: Int64
        public let timestamp: Int32
        public let durationMinutes: Int32

        public init(chatId: EnginePeer.Id, call: ScheduledCall) {
            self.chatId = chatId
            self.callerId = call.callerId
            self.callId = call.id
            self.timestamp = call.timestamp
            self.durationMinutes = call.durationMinutes
        }

        private init(chatId: EnginePeer.Id, callerId: EnginePeer.Id, callId: Int64, timestamp: Int32, durationMinutes: Int32) {
            self.chatId = chatId
            self.callerId = callerId
            self.callId = callId
            self.timestamp = timestamp
            self.durationMinutes = durationMinutes
        }

        fileprivate var stringValue: String {
            return "\(self.chatId.toInt64())_\(self.callerId.toInt64())_\(self.callId)_\(self.timestamp)_\(self.durationMinutes)"
        }

        fileprivate init?(stringParts parts: [Substring]) {
            guard parts.count >= 5, let chat = Int64(parts[0]), let caller = Int64(parts[1]), let call = Int64(parts[2]), let timestamp = Int32(parts[3]), let duration = Int32(parts[4]) else {
                return nil
            }
            self.init(chatId: EnginePeer.Id(chat), callerId: EnginePeer.Id(caller), callId: call, timestamp: timestamp, durationMinutes: duration)
        }
    }

    private struct Acceptance {
        let key: Key
        let messageId: EngineMessage.Id

        var stringValue: String {
            return self.key.stringValue + "_\(self.messageId.peerId.toInt64())_\(self.messageId.namespace)_\(self.messageId.id)"
        }

        init(key: Key, messageId: EngineMessage.Id) {
            self.key = key
            self.messageId = messageId
        }

        init?(stringValue: String) {
            let parts = stringValue.split(separator: "_")
            guard parts.count == 8, let key = Key(stringParts: Array(parts[0 ..< 5])), let peer = Int64(parts[5]), let namespace = Int32(parts[6]), let id = Int32(parts[7]) else {
                return nil
            }
            self.init(key: key, messageId: EngineMessage.Id(peerId: EnginePeer.Id(peer), namespace: namespace, id: id))
        }
    }

    public static let shared = ScheduledCallStore()

    private static let defaultsKey = "ScheduledCallAcceptances"
    private static let maxAcceptances = 300

    private let queue = Queue()
    private var accepted: [Acceptance] = []
    private var sending: [Key: Set<EngineMessage.Id>] = [:]
    private let updates = ValuePipe<Key>()

    private init() {
        if let stored = UserDefaults.standard.stringArray(forKey: ScheduledCallStore.defaultsKey) {
            self.accepted = stored.compactMap(Acceptance.init(stringValue:))
        }
    }

    private func save() {
        UserDefaults.standard.set(self.accepted.map { $0.stringValue }, forKey: ScheduledCallStore.defaultsKey)
    }

    /// The reply `messageId`, delivered, accepts the call. Safe from any thread.
    public func registerAcceptance(_ key: Key, messageId: EngineMessage.Id) {
        self.queue.async {
            // Delivered: whatever was still being sent for it has become this.
            let hadSending = self.sending.removeValue(forKey: key) != nil
            if self.accepted.contains(where: { $0.key == key && $0.messageId == messageId }) {
                if hadSending {
                    self.updates.putNext(key)
                }
                return
            }
            self.accepted.append(Acceptance(key: key, messageId: messageId))
            if self.accepted.count > ScheduledCallStore.maxAcceptances {
                self.accepted.removeFirst(self.accepted.count - ScheduledCallStore.maxAcceptances)
            }
            self.save()
            self.updates.putNext(key)
        }
    }

    /// The reply `messageId` that accepts the call is being sent (true), or is not any more: its sending failed or it
    /// is gone (false). Safe from any thread.
    public func setSending(_ key: Key, messageId: EngineMessage.Id, _ isSending: Bool) {
        self.queue.async {
            var ids = self.sending[key] ?? Set()
            let changed = isSending ? ids.insert(messageId).inserted : ids.remove(messageId) != nil
            self.sending[key] = ids.isEmpty ? nil : ids
            if changed {
                self.updates.putNext(key)
            }
        }
    }

    /// The reply `messageId` is gone, or no longer accepts the call. Safe from any thread.
    public func removeAcceptance(_ key: Key, messageId: EngineMessage.Id) {
        self.queue.async {
            let count = self.accepted.count
            self.accepted.removeAll(where: { $0.key == key && $0.messageId == messageId })
            if self.accepted.count != count {
                self.save()
                self.updates.putNext(key)
            }
        }
    }

    public struct State: Equatable {
        /// Accepted: by a delivered reply, or by one being sent.
        public var isAccepted: Bool {
            return !self.delivered.isEmpty || !self.sending.isEmpty
        }
        /// The delivered replies that accept the call.
        public let delivered: Set<EngineMessage.Id>
        /// The replies that accept it and are still being sent.
        public let sending: Set<EngineMessage.Id>
    }

    private func state(_ key: Key) -> State {
        return State(delivered: Set(self.accepted.filter { $0.key == key }.map { $0.messageId }), sending: self.sending[key] ?? Set())
    }

    /// Whether the call is accepted, and by which replies, now and whenever it changes.
    public func acceptance(_ key: Key) -> Signal<State, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                subscriber.putNext(self.state(key))
                disposable.set((self.updates.signal()
                |> filter { $0 == key }
                |> deliverOn(self.queue)).start(next: { _ in
                    subscriber.putNext(self.state(key))
                }))
            }
            return disposable
        }
        |> distinctUntilChanged
    }

    public func currentIsAccepted(_ key: Key) -> Bool {
        var result = false
        self.queue.sync {
            result = self.state(key).isAccepted
        }
        return result
    }
}
