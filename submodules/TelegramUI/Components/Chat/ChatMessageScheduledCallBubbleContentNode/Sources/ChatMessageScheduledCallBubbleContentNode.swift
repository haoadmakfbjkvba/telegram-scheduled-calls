import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import LocalizedPeerData
import LottieSettings
import Markdown
import WallpaperBackgroundNode
import ChatMessageBubbleContentNode
import ChatMessageItemCommon
import ChatControllerInteraction
import ScheduledCall
import ScheduledCallModel

/// A scheduled call, or its acceptance, shown in the middle of the chat like a service message: a line saying who
/// scheduled or accepted it and, for the call, its card.
public final class ChatMessageScheduledCallBubbleContentNode: ChatMessageBubbleContentNode {
    private let labelNode: TextNode
    private let labelBackgroundNode: NavigationBackgroundNode
    private var labelBackgroundContent: WallpaperBubbleBackgroundNode?
    private let labelContainer: ASDisplayNode
    private var cardView: ScheduledCallCardView?

    private var acceptanceDisposable: Disposable?
    private var acceptanceMessageDisposable: Disposable?
    private var subscribedKey: ScheduledCallStore.Key?
    private var currentIsAccepted = false
    private var refreshTimer: SwiftSignalKit.Timer?
    private var absoluteRect: (CGRect, CGSize)?

    /// The call this node shows, if it shows one.
    public private(set) var callId: Int64?

    required public init(lottieSettings: LottieRenderingSettings) {
        self.labelContainer = ASDisplayNode()
        self.labelBackgroundNode = NavigationBackgroundNode(color: .clear)
        self.labelBackgroundNode.clipsToBounds = true
        self.labelNode = TextNode()
        self.labelNode.isUserInteractionEnabled = false
        self.labelNode.displaysAsynchronously = false

        super.init(lottieSettings: lottieSettings)

        self.labelContainer.addSubnode(self.labelBackgroundNode)
        self.labelContainer.addSubnode(self.labelNode)
        self.addSubnode(self.labelContainer)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.acceptanceDisposable?.dispose()
        self.acceptanceMessageDisposable?.dispose()
        self.refreshTimer?.invalidate()
    }

    override public var disablesClipping: Bool {
        return true
    }

    override public var visibility: ListViewItemNodeVisibility {
        didSet {
            if (oldValue != .none) != (self.visibility != .none) {
                self.cardView?.updateVisibility(self.visibility != .none)
            }
        }
    }

    private static func participant(item: ChatMessageBubbleContentItem, peerId: EnginePeer.Id) -> ScheduledCallCardView.Participant {
        var peer = item.message.peers[peerId].flatMap(EnginePeer.init)
        if peer == nil, item.message.author?.id == peerId {
            peer = item.message.author.flatMap(EnginePeer.init)
        }
        if peer == nil, peerId == item.context.account.peerId {
            peer = item.associatedData.accountPeer
        }
        let name = peer.map { $0.compactDisplayTitle } ?? ""
        return ScheduledCallCardView.Participant(peer: peer, id: peerId, name: name)
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, unboundSize: CGSize?, maxWidth: CGFloat, layout: (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        let makeLabelLayout = TextNode.asyncLayout(self.labelNode)
        let previousCallId = self.callId

        return { [weak self] item, _, _, _, _, _ in
            let contentProperties = ChatMessageBubbleContentProperties(
                hidesSimpleAuthorHeader: true,
                headerSpacing: 0.0,
                hidesBackground: .always,
                forceFullCorners: false,
                forceAlignment: .center,
                hidesHeaders: true
            )

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { [weak self] constrainedSize, _ in
                let strings = item.presentationData.strings
                let theme = item.presentationData.theme.theme
                let accountPeerId = item.context.account.peerId
                let message = item.message
                let call = ScheduledCall.parse(message: message, accountPeerId: accountPeerId)
                let verifiedAcceptance = call == nil ? message.verifiedScheduledCallAcceptance(accountPeerId: accountPeerId) : nil
                let now = Int32(Date().timeIntervalSince1970)

                // The line: who scheduled the call, or who accepted it.
                let authorName = escapedPlaintextForMarkdown(message.author.flatMap { EnginePeer($0).compactDisplayTitle } ?? "")
                let isOutgoing = message.author?.id == accountPeerId
                var text = ""
                if call != nil {
                    text = isOutgoing ? strings.ScheduledCall_YouScheduled : strings.ScheduledCall_PeerScheduled("**\(authorName)**").string
                } else if verifiedAcceptance != nil {
                    text = isOutgoing ? strings.ScheduledCall_YouAcceptedService : strings.ScheduledCall_PeerAcceptedService("**\(authorName)**").string
                }
                let textColor = serviceMessageColorComponents(theme: theme, wallpaper: item.presentationData.theme.wallpaper).primaryText
                let fontSize = floor(item.presentationData.fontSize.baseDisplaySize * 13.0 / 17.0)
                let attributedText = parseMarkdownIntoAttributedString(text, attributes: MarkdownAttributes(
                    body: MarkdownAttributeSet(font: Font.regular(fontSize), textColor: textColor),
                    bold: MarkdownAttributeSet(font: Font.semibold(fontSize), textColor: textColor),
                    link: MarkdownAttributeSet(font: Font.regular(fontSize), textColor: textColor),
                    linkAttribute: { _ in
                        return nil
                    }
                ), textAlignment: .center)
                let maxLabelWidth = min(constrainedSize.width - 40.0, 300.0)
                let (labelLayout, labelApply) = makeLabelLayout(TextNodeLayoutArguments(attributedString: attributedText, backgroundColor: nil, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: maxLabelWidth, height: .greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets()))
                let labelInsets = UIEdgeInsets(top: 3.0, left: 9.0, bottom: 3.0, right: 9.0)
                let labelBackgroundSize = CGSize(width: labelLayout.size.width + labelInsets.left + labelInsets.right, height: labelLayout.size.height + labelInsets.top + labelInsets.bottom)

                // The card, accepted or not.
                var cardModel: ScheduledCallCardView.Model?
                var cardSize = CGSize()
                var key: ScheduledCallStore.Key?
                if let call {
                    let callKey = ScheduledCallStore.Key(chatId: message.id.peerId, call: call)
                    key = callKey
                    let model = ScheduledCallCardView.Model(
                        call: call,
                        caller: ChatMessageScheduledCallBubbleContentNode.participant(item: item, peerId: call.callerId),
                        callee: ChatMessageScheduledCallBubbleContentNode.participant(item: item, peerId: call.calleeId),
                        isAccepted: ScheduledCallStore.shared.currentIsAccepted(callKey),
                        viewerId: accountPeerId,
                        now: now,
                        strings: strings,
                        dateTimeFormat: item.presentationData.dateTimeFormat,
                        maxWidth: constrainedSize.width - 24.0
                    )
                    cardModel = model
                    cardSize = ScheduledCallCardView.size(model: model)
                }
                let spacing: CGFloat = 8.0
                let contentHeight = labelBackgroundSize.height + (cardModel != nil ? spacing + cardSize.height : 0.0)
                let contentWidth = max(labelBackgroundSize.width, cardSize.width)

                return (contentWidth, { [weak self] boundingWidth in
                    return (CGSize(width: boundingWidth, height: contentHeight), { [weak self] animation, _, _ in
                        guard let self else {
                            return
                        }
                        self.item = item
                        let isSameCall = previousCallId != nil && previousCallId == call?.id
                        self.callId = call?.id

                        let _ = labelApply()
                        let labelBackgroundFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((boundingWidth - labelBackgroundSize.width) * 0.5), y: 0.0), size: labelBackgroundSize)
                        self.labelContainer.frame = labelBackgroundFrame
                        self.labelNode.frame = CGRect(origin: CGPoint(x: labelInsets.left, y: labelInsets.top), size: labelLayout.size)
                        let labelBounds = CGRect(origin: CGPoint(), size: labelBackgroundSize)
                        let cornerRadius = labelLayout.numberOfLines > 1 ? 10.0 : labelBackgroundSize.height * 0.5
                        self.labelBackgroundNode.frame = labelBounds
                        self.labelBackgroundNode.cornerRadius = cornerRadius
                        self.labelBackgroundNode.updateColor(color: selectDateFillStaticColor(theme: theme, wallpaper: item.presentationData.theme.wallpaper), enableBlur: item.controllerInteraction.enableFullTranslucency && dateFillNeedsBlur(theme: theme, wallpaper: item.presentationData.theme.wallpaper), transition: .immediate)
                        self.labelBackgroundNode.update(size: labelBounds.size, cornerRadius: cornerRadius, transition: .immediate)
                        if item.controllerInteraction.presentationContext.backgroundNode?.hasExtraBubbleBackground() == true {
                            if self.labelBackgroundContent == nil, let backgroundContent = item.controllerInteraction.presentationContext.backgroundNode?.makeBubbleBackground(for: .free) {
                                backgroundContent.clipsToBounds = true
                                self.labelBackgroundContent = backgroundContent
                                self.labelContainer.insertSubnode(backgroundContent, at: 0)
                            }
                            self.labelBackgroundNode.isHidden = true
                            self.labelBackgroundContent?.frame = labelBounds
                            self.labelBackgroundContent?.cornerRadius = cornerRadius
                        } else {
                            self.labelBackgroundNode.isHidden = false
                            self.labelBackgroundContent?.removeFromSupernode()
                            self.labelBackgroundContent = nil
                        }

                        // An acceptance marks its call, for every card of it: for good once it is delivered, while it
                        // is being sent until the sending fails.
                        if let verifiedAcceptance {
                            let acceptedKey = ScheduledCallStore.Key(chatId: verifiedAcceptance.callMessage.id.peerId, call: verifiedAcceptance.call)
                            if message.id.namespace == Namespaces.Message.Cloud {
                                ScheduledCallStore.shared.registerAcceptance(acceptedKey, messageId: message.id)
                            } else {
                                ScheduledCallStore.shared.setSending(acceptedKey, messageId: message.id, !message.flags.contains(.Failed))
                            }
                        }

                        if let call, let cardModel, let key {
                            let cardView: ScheduledCallCardView
                            var isNewCard = false
                            if let current = self.cardView {
                                cardView = current
                            } else {
                                cardView = ScheduledCallCardView()
                                self.cardView = cardView
                                self.view.addSubview(cardView)
                                isNewCard = true
                            }
                            cardView.action = { [weak self] action in
                                guard let self, let item = self.item else {
                                    return
                                }
                                switch action {
                                case .accept:
                                    item.controllerInteraction.acceptScheduledCall?(item.message)
                                case .call:
                                    item.controllerInteraction.startScheduledCall?(item.message)
                                }
                            }
                            cardView.updateVisibility(self.visibility != .none)
                            let _ = cardView.update(model: cardModel, context: item.context, theme: theme, animated: isSameCall && animation.isAnimated)
                            let cardFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((boundingWidth - cardSize.width) * 0.5), y: labelBackgroundFrame.maxY + spacing), size: cardSize)
                            if isSameCall, case let .System(duration, _) = animation {
                                ContainedViewLayoutTransition.animated(duration: duration, curve: .spring).updateFrame(view: cardView, frame: cardFrame)
                            } else {
                                cardView.frame = cardFrame
                            }
                            // A call just scheduled here opens with the card coming out of its clock.
                            if (isNewCard || !isSameCall) && ScheduledCallRevealQueue.shared.take(call.id) {
                                self.labelContainer.alpha = 0.0
                                cardView.alpha = 0.0
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: { [weak self, weak cardView] in
                                    guard let self else {
                                        return
                                    }
                                    guard let cardView, cardView === self.cardView else {
                                        self.labelContainer.alpha = 1.0
                                        return
                                    }
                                    cardView.alpha = 1.0
                                    cardView.animateReveal()
                                    self.animateLabelIn(delay: 0.3)
                                })
                            }
                            self.currentIsAccepted = cardModel.isAccepted
                            self.subscribeAcceptance(key, context: item.context)
                            self.scheduleRefresh(call: call, now: cardModel.now)
                        } else {
                            self.cardView?.removeFromSuperview()
                            self.cardView = nil
                            self.acceptanceDisposable?.dispose()
                            self.acceptanceDisposable = nil
                            self.acceptanceMessageDisposable?.dispose()
                            self.acceptanceMessageDisposable = nil
                            self.subscribedKey = nil
                            self.labelContainer.alpha = 1.0
                            self.refreshTimer?.invalidate()
                            self.refreshTimer = nil
                        }

                        if let (rect, size) = self.absoluteRect {
                            self.updateAbsoluteRect(rect, within: size)
                        }
                    })
                })
            })
        }
    }

    private func animateLabelIn(delay: Double) {
        self.labelContainer.alpha = 1.0
        if UIAccessibility.isReduceMotionEnabled {
            self.labelContainer.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25, delay: delay)
            return
        }
        let label = self.labelContainer.layer
        label.animateAlpha(from: 0.0, to: 1.0, duration: 0.25, delay: delay)
        label.animateSpring(from: 0.6 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: delay, damping: 66.0)
        label.animateSpring(from: NSValue(cgPoint: CGPoint(x: 0.0, y: 12.0)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.6, delay: delay, damping: 76.0, additive: true)
        scheduledCallAnimateBlurIn(label, radius: 8.0, duration: 0.3, delay: delay)
        scheduledCallAnimateSheen(over: self.labelContainer.view, cornerRadius: self.labelContainer.bounds.height * 0.5, delay: delay + 0.3, duration: 0.8, alpha: 0.55)
    }

    /// When the call is accepted (here or anywhere) or no longer is, the message is laid out again. The replies that
    /// accept it are watched: a delivered one that is deleted or edited into something else, or one being sent that is
    /// deleted, no longer counts.
    private func subscribeAcceptance(_ key: ScheduledCallStore.Key, context: AccountContext) {
        guard self.subscribedKey != key else {
            return
        }
        self.subscribedKey = key
        self.acceptanceDisposable?.dispose()
        self.acceptanceMessageDisposable?.dispose()
        self.acceptanceMessageDisposable = nil
        var watched: ScheduledCallStore.State?
        self.acceptanceDisposable = (ScheduledCallStore.shared.acceptance(key)
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self, self.subscribedKey == key else {
                return
            }
            if watched != state {
                watched = state
                self.watchAcceptanceReplies(key: key, state: state, context: context)
            }
            if let item = self.item, state.isAccepted != self.currentIsAccepted {
                item.controllerInteraction.requestMessageUpdate(item.message.id, false, nil)
            }
        })
    }

    private func watchAcceptanceReplies(key: ScheduledCallStore.Key, state: ScheduledCallStore.State, context: AccountContext) {
        self.acceptanceMessageDisposable?.dispose()
        self.acceptanceMessageDisposable = nil
        let ids = Array(state.delivered.union(state.sending))
        guard !ids.isEmpty else {
            return
        }
        let delivered = state.delivered
        // A reply counts as gone only once it has been seen here and then disappears: one that is simply not loaded on
        // this device (a gap in the history) keeps its acceptance.
        var seen = Set<EngineMessage.Id>()
        self.acceptanceMessageDisposable = (context.engine.data.subscribe(EngineDataMap(ids.map(TelegramEngine.EngineData.Item.Messages.Message.init(id:))))
        |> deliverOnMainQueue).start(next: { messages in
            for id in ids {
                let message = messages[id] ?? nil
                if message != nil {
                    seen.insert(id)
                }
                if delivered.contains(id) {
                    if let message {
                        // Still accepting this very call? (An edited reply may no longer.)
                        let stillAccepts = ScheduledCallAcceptance.parse(message: message._asMessage()).flatMap { acceptance in
                            acceptance.callId == key.callId && acceptance.timestamp == key.timestamp && acceptance.durationMinutes == key.durationMinutes && acceptance.callMessageId.peerId == key.chatId
                        } ?? false
                        if !stillAccepts {
                            ScheduledCallStore.shared.removeAcceptance(key, messageId: id)
                        }
                    } else if seen.contains(id) {
                        ScheduledCallStore.shared.removeAcceptance(key, messageId: id)
                    }
                } else if let message, message.flags.contains(.Failed) {
                    // Its sending failed.
                    ScheduledCallStore.shared.setSending(key, messageId: id, false)
                } else if message == nil {
                    // Gone while being sent: deleted, or delivered under another id (then it is registered as that one
                    // by its own bubble in a moment; giving up this id does not take the acceptance away).
                    Queue.mainQueue().after(1.0, {
                        ScheduledCallStore.shared.setSending(key, messageId: id, false)
                    })
                }
            }
        })
    }

    /// The card changes when the call can be started and when it is over: it is laid out again then.
    private func scheduleRefresh(call: ScheduledCall, now: Int32) {
        self.refreshTimer?.invalidate()
        self.refreshTimer = nil
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let nowDate = Date(timeIntervalSince1970: Double(now))
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: nowDate)).flatMap { Int32($0.timeIntervalSince1970) } ?? Int32.max
        let boundaries = [call.timestamp - 10 * 60, call.endTimestamp, midnight].filter { $0 > now }.sorted()
        guard let next = boundaries.first, next - now < 24 * 3600 + 3600 else {
            return
        }
        let timer = SwiftSignalKit.Timer(timeout: Double(next - now) + 1.0, repeat: false, completion: { [weak self] in
            guard let self, let item = self.item else {
                return
            }
            item.controllerInteraction.requestMessageUpdate(item.message.id, false, nil)
        }, queue: Queue.mainQueue())
        self.refreshTimer = timer
        timer.start()
    }

    override public func updateAbsoluteRect(_ rect: CGRect, within containerSize: CGSize) {
        self.absoluteRect = (rect, containerSize)
    }

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        if let cardView = self.cardView {
            let cardPoint = cardView.convert(point, from: self.view)
            if cardView.isInteractive(at: cardPoint) {
                return ChatMessageBubbleContentTapAction(content: .ignore)
            }
        }
        return ChatMessageBubbleContentTapAction(content: .none)
    }
}
