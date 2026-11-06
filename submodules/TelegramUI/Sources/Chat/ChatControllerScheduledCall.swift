import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChatPresentationInterfaceState
import PresentationDataUtils
import ScheduledCallModel
import ScheduledCallScreen

/// Calls the account is accepting just now: a second tap on Accept before the reply shows up does not send another one.
private var scheduledCallAccepting = Set<ScheduledCallStore.Key>()

extension ChatControllerImpl: ScheduledCallSendingController {
    /// A scheduled call or its acceptance goes out as plain text, with no link preview.
    private func scheduledCallMessage(text: String, entities: [MessageTextEntity], replyTo: EngineMessage.Id?) -> EnqueueMessage {
        let attributes: [EngineMessage.Attribute] = [
            TextEntitiesMessageAttribute(entities: entities),
            OutgoingContentInfoMessageAttribute(flags: [.disableLinkPreviews])
        ]
        return .message(text: text, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: self.chatLocation.threadId, replyToMessageId: replyTo.flatMap { EngineMessageReplySubject(messageId: $0, quote: nil, innerSubject: nil) }, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
    }

    /// Whether a scheduled call or an acceptance can be sent to this chat now; if not, says why.
    private func scheduledCallCanSend() -> Bool {
        let state = self.presentationInterfaceState
        let strings = self.presentationData.strings
        let name = state.renderedPeer?.chatMainPeer.flatMap { EnginePeer($0).compactDisplayTitle } ?? ""
        if state.peerIsBlocked {
            self.present(textAlertController(context: self.context, updatedPresentationData: self.updatedPresentationData, title: nil, text: strings.ScheduledCall_Blocked(name).string, actions: [TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})]), in: .window(.root))
            return false
        }
        if state.isPremiumRequiredForMessaging || !canSendMessagesToChat(state) {
            self.present(textAlertController(context: self.context, updatedPresentationData: self.updatedPresentationData, title: nil, text: strings.ScheduledCall_CantSend(name).string, actions: [TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})]), in: .window(.root))
            return false
        }
        return true
    }

    /// Sends a call scheduled in the profile of the one called, once this chat is on screen and knows its peer; its
    /// card opens with an animation.
    public func sendScheduledCall(_ call: ScheduledCall) {
        guard self.chatLocation.peerId == call.calleeId, call.callerId == self.context.account.peerId else {
            return
        }
        let (text, entities) = call.messageText(strings: self.presentationData.strings)
        let message = self.scheduledCallMessage(text: text, entities: entities, replyTo: nil)
        let send: () -> Void = { [weak self] in
            guard let self, self.scheduledCallCanSend() else {
                return
            }
            self.presentPaidMessageAlertIfNeeded(completion: { [weak self] postpone in
                guard let self else {
                    return
                }
                ScheduledCallRevealQueue.shared.add(call.id)
                self.sendMessages(self.transformEnqueueMessages([message], silentPosting: false), postpone: postpone)
            })
        }
        // The chat is ready and knows its peer (the paid messages alert and the checks need it), then a moment for the
        // chat to settle on screen.
        let _ = (self.ready.get()
        |> filter { $0 }
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] _ in
            self?.scheduledCallWhenPeerIsKnown(attempt: 0, {
                Queue.mainQueue().after(0.3, send)
            }, failed: { [weak self] in
                guard let self else {
                    return
                }
                self.present(textAlertController(context: self.context, updatedPresentationData: self.updatedPresentationData, title: nil, text: self.presentationData.strings.ScheduledCall_NotSent, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
            })
        })
    }

    /// Runs `action` once the chat knows its peer, or `failed` if it does not within five seconds.
    private func scheduledCallWhenPeerIsKnown(attempt: Int, _ action: @escaping () -> Void, failed: @escaping () -> Void) {
        if self.presentationInterfaceState.renderedPeer != nil {
            action()
        } else if attempt < 50 {
            Queue.mainQueue().after(0.1, { [weak self] in
                self?.scheduledCallWhenPeerIsKnown(attempt: attempt + 1, action, failed: failed)
            })
        } else {
            failed()
        }
    }

    /// The one called says yes: a reply to the call. The card is marked while the reply is being sent and for good once
    /// it is delivered (see the bubble of the reply).
    func acceptScheduledCall(message: EngineRawMessage) {
        let accountPeerId = self.context.account.peerId
        guard let call = ScheduledCall.parse(message: message, accountPeerId: accountPeerId), call.calleeId == accountPeerId else {
            return
        }
        let key = ScheduledCallStore.Key(chatId: message.id.peerId, call: call)
        guard !ScheduledCallStore.shared.currentIsAccepted(key), !scheduledCallAccepting.contains(key), self.scheduledCallCanSend() else {
            return
        }
        let (text, entities) = ScheduledCallAcceptance.messageText(call: call, strings: self.presentationData.strings)
        let reply = self.scheduledCallMessage(text: text, entities: entities, replyTo: message.id)
        // A second tap while the paid messages alert (if any) is deciding does not send a second reply.
        scheduledCallAccepting.insert(key)
        Queue.mainQueue().after(5.0, {
            scheduledCallAccepting.remove(key)
        })
        self.presentPaidMessageAlertIfNeeded(completion: { [weak self] postpone in
            guard let self else {
                return
            }
            self.sendMessages(self.transformEnqueueMessages([reply], silentPosting: false), postpone: postpone)
        })
    }

    /// The time has come: a call to the other one.
    func startScheduledCall(message: EngineRawMessage) {
        let accountPeerId = self.context.account.peerId
        guard let call = ScheduledCall.parse(message: message, accountPeerId: accountPeerId) else {
            return
        }
        let otherId = call.callerId == accountPeerId ? call.calleeId : call.callerId
        guard otherId != accountPeerId, call.isCallable(now: Int32(Date().timeIntervalSince1970)) else {
            return
        }
        self.controllerInteraction?.callPeer(otherId, false)
    }
}
