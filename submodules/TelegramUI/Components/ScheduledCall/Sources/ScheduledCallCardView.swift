import Foundation
import UIKit
import Display
import TelegramCore
import AccountContext
import AvatarNode
import TelegramPresentationData
import TelegramStringFormatting
import TextFormat
import ScheduledCallModel

/// The card of a scheduled call in a chat: a green ticket with a clock at the call's time, the day, the two people, and
/// whether the call is accepted.
public final class ScheduledCallCardView: UIView {
    public struct Participant: Equatable {
        public let peer: EnginePeer?
        public let id: EnginePeer.Id
        public let name: String

        public init(peer: EnginePeer?, id: EnginePeer.Id, name: String) {
            self.peer = peer
            self.id = id
            self.name = name
        }
    }

    public enum Action {
        case accept
        case call
    }

    public struct Model: Equatable {
        public let call: ScheduledCall
        public let caller: Participant
        public let callee: Participant
        public let isAccepted: Bool
        public let viewerId: EnginePeer.Id
        public let now: Int32
        public let strings: PresentationStrings
        public let dateTimeFormat: PresentationDateTimeFormat
        /// The width of the card: `ScheduledCallCardView.width`, or less where there is not room for it.
        public let width: CGFloat

        public init(call: ScheduledCall, caller: Participant, callee: Participant, isAccepted: Bool, viewerId: EnginePeer.Id, now: Int32, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, maxWidth: CGFloat = .greatestFiniteMagnitude) {
            self.width = max(240.0, min(ScheduledCallCardView.width, floor(maxWidth)))
            self.call = call
            self.caller = caller
            self.callee = callee
            self.isAccepted = isAccepted
            self.viewerId = viewerId
            self.now = now
            self.strings = strings
            self.dateTimeFormat = dateTimeFormat
        }

        public static func ==(lhs: Model, rhs: Model) -> Bool {
            return lhs.call == rhs.call && lhs.caller == rhs.caller && lhs.callee == rhs.callee && lhs.isAccepted == rhs.isAccepted && lhs.viewerId == rhs.viewerId && lhs.now == rhs.now && lhs.strings === rhs.strings && lhs.dateTimeFormat == rhs.dateTimeFormat && lhs.width == rhs.width
        }

        var isViewerCallee: Bool {
            return self.viewerId == self.call.calleeId
        }

        var action: Action? {
            if self.call.isCallable(now: self.now) {
                return .call
            }
            if self.isViewerCallee && !self.isAccepted && !self.call.isOver(now: self.now) {
                return .accept
            }
            return nil
        }
    }

    public static let width: CGFloat = 304.0
    private static let inset: CGFloat = 18.0
    private static let cornerRadius: CGFloat = 26.0
    private static let clockSize: CGFloat = 60.0
    private static let avatarSize: CGFloat = 40.0

    static let topColor = ScheduledCallColors.top
    static let middleColor = ScheduledCallColors.middle
    static let bottomColor = ScheduledCallColors.bottom
    static let deepColor = ScheduledCallColors.deep

    private static let eyebrowFont = Font.with(size: 11.0, design: .regular, weight: .bold)
    private static let titleFont = Font.with(size: 22.0, design: .round, weight: .bold)
    private static let subtitleFont = Font.medium(13.0)
    private static let zoneFont = Font.regular(12.0)
    private static let nameFont = Font.medium(12.0)
    private static let statusFont = Font.semibold(14.0)
    private static let buttonFont = Font.semibold(16.0)

    // MARK: - Texts

    private static func dayString(timestamp: Int32, now: Int32, strings: PresentationStrings) -> String {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let date = Date(timeIntervalSince1970: Double(timestamp))
        let today = Date(timeIntervalSince1970: Double(now))
        if calendar.isDate(date, inSameDayAs: today) {
            return strings.ScheduledCall_Today
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), calendar.isDate(date, inSameDayAs: tomorrow) {
            return strings.ScheduledCall_Tomorrow
        }
        let formatter = DateFormatter()
        formatter.locale = localeWithStrings(strings)
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: date)
    }

    static func timeString(timestamp: Int32, utcOffset: Int32? = nil, dateTimeFormat: PresentationDateTimeFormat) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcOffset.flatMap { TimeZone(secondsFromGMT: Int($0)) } ?? TimeZone.current
        let components = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(timestamp)))
        return stringForShortTimestamp(hours: Int32(components.hour ?? 0), minutes: Int32(components.minute ?? 0), dateTimeFormat: dateTimeFormat)
    }

    static func titleText(_ model: Model) -> String {
        return model.strings.ScheduledCall_DayAtTime(dayString(timestamp: model.call.timestamp, now: model.now, strings: model.strings), timeString(timestamp: model.call.timestamp, dateTimeFormat: model.dateTimeFormat)).string
    }

    static func subtitleText(_ model: Model) -> String {
        let formatter = DateFormatter()
        formatter.locale = localeWithStrings(model.strings)
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMMd")
        let date = formatter.string(from: Date(timeIntervalSince1970: Double(model.call.timestamp)))
        return date + "  ·  " + model.strings.ScheduledCall_Minutes("\(model.call.durationMinutes)").string
    }

    /// The caller's own time, for the one called, when their clocks differ.
    static func zoneText(_ model: Model) -> String? {
        guard model.isViewerCallee, Int(model.call.callerUtcOffset) != TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: Double(model.call.timestamp))) else {
            return nil
        }
        let time = timeString(timestamp: model.call.timestamp, utcOffset: model.call.callerUtcOffset, dateTimeFormat: model.dateTimeFormat)
        return model.strings.ScheduledCall_TheirTime(model.caller.name, time + " " + ScheduledCall.zoneName(utcOffset: model.call.callerUtcOffset)).string
    }

    static func statusText(_ model: Model) -> String {
        let strings = model.strings
        if model.call.isOver(now: model.now) {
            return strings.ScheduledCall_StatusOver
        }
        if model.call.isCallable(now: model.now) {
            return strings.ScheduledCall_StatusNow
        }
        if model.isAccepted {
            return model.isViewerCallee ? strings.ScheduledCall_StatusYouAccepted : strings.ScheduledCall_StatusAccepted(model.callee.name).string
        }
        return model.isViewerCallee ? strings.ScheduledCall_StatusInvited(model.caller.name).string : strings.ScheduledCall_StatusWaiting(model.callee.name).string
    }

    // MARK: - Layout

    fileprivate struct Layout {
        var size = CGSize()
        var clockFrame = CGRect()
        var eyebrowFrame = CGRect()
        var titleFrame = CGRect()
        var subtitleFrame = CGRect()
        var zoneFrame: CGRect?
        var separatorY: CGFloat = 0.0
        var callerAvatarFrame = CGRect()
        var calleeAvatarFrame = CGRect()
        var callerNameFrame = CGRect()
        var calleeNameFrame = CGRect()
        var lineFrame = CGRect()
        var phoneFrame = CGRect()
        var statusFrame = CGRect()
        var buttonFrame: CGRect?
    }

    /// Where everything goes. It only measures text, so the chat can size the card on any thread.
    fileprivate static func layout(model: Model) -> Layout {
        var layout = Layout()
        let width = model.width
        let inset = ScheduledCallCardView.inset
        let clockSize = ScheduledCallCardView.clockSize

        layout.clockFrame = CGRect(x: inset, y: inset, width: clockSize, height: clockSize)
        let textX = layout.clockFrame.maxX + 14.0
        let textWidth = width - textX - inset
        layout.eyebrowFrame = CGRect(x: textX, y: inset + 2.0, width: textWidth, height: ceil(eyebrowFont.lineHeight))
        let titleSize = ScheduledCallTextView.measure(text: NSAttributedString(string: titleText(model), attributes: [.font: titleFont]), width: textWidth, maxLines: 2)
        layout.titleFrame = CGRect(origin: CGPoint(x: textX, y: layout.eyebrowFrame.maxY + 2.0), size: titleSize)
        layout.subtitleFrame = CGRect(x: textX, y: layout.titleFrame.maxY + 2.0, width: textWidth, height: ceil(subtitleFont.lineHeight))
        var y = max(layout.clockFrame.maxY, layout.subtitleFrame.maxY)
        if let zone = zoneText(model) {
            let zoneSize = ScheduledCallTextView.measure(text: NSAttributedString(string: zone, attributes: [.font: zoneFont]), width: width - inset * 2.0, maxLines: 2)
            let frame = CGRect(origin: CGPoint(x: inset, y: y + 10.0), size: zoneSize)
            layout.zoneFrame = frame
            y = frame.maxY
        }
        y += 16.0
        layout.separatorY = y
        y += 16.0

        // The two people, joined by the line of the call.
        let avatarSize = ScheduledCallCardView.avatarSize
        let pairInset: CGFloat = 34.0
        layout.callerAvatarFrame = CGRect(x: pairInset, y: y, width: avatarSize, height: avatarSize)
        layout.calleeAvatarFrame = CGRect(x: width - pairInset - avatarSize, y: y, width: avatarSize, height: avatarSize)
        let nameHeight = ceil(nameFont.lineHeight)
        let nameWidth: CGFloat = 96.0
        layout.callerNameFrame = CGRect(x: layout.callerAvatarFrame.midX - nameWidth * 0.5, y: layout.callerAvatarFrame.maxY + 6.0, width: nameWidth, height: nameHeight)
        layout.calleeNameFrame = CGRect(x: layout.calleeAvatarFrame.midX - nameWidth * 0.5, y: layout.calleeAvatarFrame.maxY + 6.0, width: nameWidth, height: nameHeight)
        layout.lineFrame = CGRect(x: layout.callerAvatarFrame.maxX + 10.0, y: layout.callerAvatarFrame.midY - 1.5, width: layout.calleeAvatarFrame.minX - layout.callerAvatarFrame.maxX - 20.0, height: 3.0)
        layout.phoneFrame = CGRect(x: floor(width * 0.5 - 15.0), y: layout.callerAvatarFrame.midY - 15.0, width: 30.0, height: 30.0)
        y = layout.callerNameFrame.maxY + 14.0

        layout.statusFrame = CGRect(x: inset, y: y, width: width - inset * 2.0, height: ceil(statusFont.lineHeight))
        y = layout.statusFrame.maxY

        if model.action != nil {
            y += 14.0
            let frame = CGRect(x: inset, y: y, width: width - inset * 2.0, height: 44.0)
            layout.buttonFrame = frame
            y = frame.maxY
        }
        y += inset
        layout.size = CGSize(width: width, height: ceil(y))
        return layout
    }

    /// The size of the card for `model`. Safe on any thread.
    public static func size(model: Model) -> CGSize {
        return ScheduledCallCardView.layout(model: model).size
    }

    // MARK: - Views

    private let revealView = UIView()
    private let shapeView = UIView()
    private let gradientLayer = CAGradientLayer()
    private let glowLayer = CAGradientLayer()
    private let clockView = ScheduledCallClockView()
    private let eyebrowLabel = UILabel()
    private let titleView = ScheduledCallTextView()
    private let subtitleLabel = UILabel()
    private let zoneLabel = UILabel()
    private let separator = UIView()
    private let callerAvatar = AvatarNode(font: avatarPlaceholderFont(size: 15.0))
    private let calleeAvatar = AvatarNode(font: avatarPlaceholderFont(size: 15.0))
    private let callerName = UILabel()
    private let calleeName = UILabel()
    private let lineTrack = UIView()
    private let lineFill = UIView()
    private let phoneBadge = UIView()
    private let phoneIcon = UIImageView()
    private let calleeRing = CAShapeLayer()
    private let checkBadge = UIView()
    private let checkIcon = UIImageView()
    private let statusContainer = UIView()
    private let statusLabel = UILabel()
    private let dotsView = UIView()
    private var dots: [UIView] = []
    private let button = HighlightTrackingButton()
    private let buttonIcon = UIImageView()
    private let buttonLabel = UILabel()

    private var model: Model?
    private var isVisibleInChat = false

    public var action: ((Action) -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)

        self.gradientLayer.colors = [ScheduledCallCardView.topColor.cgColor, ScheduledCallCardView.middleColor.cgColor, ScheduledCallCardView.bottomColor.cgColor]
        self.gradientLayer.locations = [0.0, 0.55, 1.0]
        self.gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        self.gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        self.shapeView.layer.addSublayer(self.gradientLayer)
        self.glowLayer.type = .radial
        self.glowLayer.colors = [UIColor(white: 1.0, alpha: 0.3).cgColor, UIColor(white: 1.0, alpha: 0.0).cgColor]
        self.glowLayer.startPoint = CGPoint(x: 0.12, y: 0.05)
        self.glowLayer.endPoint = CGPoint(x: 0.95, y: 0.7)
        self.shapeView.layer.addSublayer(self.glowLayer)
        self.shapeView.layer.cornerRadius = ScheduledCallCardView.cornerRadius
        self.shapeView.layer.cornerCurve = .continuous
        self.shapeView.clipsToBounds = true
        self.revealView.addSubview(self.shapeView)
        self.addSubview(self.revealView)

        self.shapeView.addSubview(self.clockView)
        self.eyebrowLabel.textColor = UIColor(white: 1.0, alpha: 0.7)
        self.shapeView.addSubview(self.eyebrowLabel)
        self.shapeView.addSubview(self.titleView)
        self.subtitleLabel.font = ScheduledCallCardView.subtitleFont
        self.subtitleLabel.textColor = UIColor(white: 1.0, alpha: 0.82)
        self.subtitleLabel.adjustsFontSizeToFitWidth = true
        self.subtitleLabel.minimumScaleFactor = 0.8
        self.shapeView.addSubview(self.subtitleLabel)
        self.zoneLabel.font = ScheduledCallCardView.zoneFont
        self.zoneLabel.textColor = UIColor(white: 1.0, alpha: 0.8)
        self.zoneLabel.numberOfLines = 2
        self.shapeView.addSubview(self.zoneLabel)
        self.separator.backgroundColor = UIColor(white: 1.0, alpha: 0.24)
        self.shapeView.addSubview(self.separator)

        self.lineTrack.backgroundColor = UIColor(white: 1.0, alpha: 0.28)
        self.lineTrack.layer.cornerRadius = 1.5
        self.lineTrack.clipsToBounds = true
        self.lineFill.backgroundColor = .white
        self.lineFill.layer.cornerRadius = 1.5
        self.lineTrack.addSubview(self.lineFill)
        self.shapeView.addSubview(self.lineTrack)

        self.phoneBadge.backgroundColor = .white
        self.phoneBadge.layer.cornerRadius = 15.0
        self.phoneIcon.image = UIImage(systemName: "phone.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold))?.withRenderingMode(.alwaysTemplate)
        self.phoneIcon.tintColor = ScheduledCallCardView.middleColor
        self.phoneIcon.contentMode = .center
        self.phoneBadge.addSubview(self.phoneIcon)
        self.shapeView.addSubview(self.phoneBadge)

        for avatar in [self.callerAvatar, self.calleeAvatar] {
            avatar.isUserInteractionEnabled = false
            self.shapeView.addSubview(avatar.view)
        }
        self.calleeRing.fillColor = UIColor.clear.cgColor
        self.calleeRing.strokeColor = UIColor.white.cgColor
        self.calleeRing.lineWidth = 2.0
        self.calleeRing.lineCap = .round
        self.shapeView.layer.addSublayer(self.calleeRing)
        for label in [self.callerName, self.calleeName] {
            label.font = ScheduledCallCardView.nameFont
            label.textColor = UIColor(white: 1.0, alpha: 0.88)
            label.textAlignment = .center
            self.shapeView.addSubview(label)
        }

        self.checkBadge.backgroundColor = .white
        self.checkBadge.layer.cornerRadius = 9.0
        self.checkIcon.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9.0, weight: .heavy))?.withRenderingMode(.alwaysTemplate)
        self.checkIcon.tintColor = ScheduledCallCardView.middleColor
        self.checkIcon.contentMode = .center
        self.checkBadge.addSubview(self.checkIcon)
        self.shapeView.addSubview(self.checkBadge)

        self.statusLabel.font = ScheduledCallCardView.statusFont
        self.statusLabel.textColor = .white
        self.statusLabel.textAlignment = .center
        self.statusContainer.addSubview(self.statusLabel)
        for _ in 0 ..< 3 {
            let dot = UIView()
            dot.backgroundColor = .white
            dot.layer.cornerRadius = 2.0
            self.dots.append(dot)
            self.dotsView.addSubview(dot)
        }
        self.statusContainer.addSubview(self.dotsView)
        self.shapeView.addSubview(self.statusContainer)

        self.button.backgroundColor = .white
        self.button.layer.cornerRadius = 22.0
        self.buttonLabel.font = ScheduledCallCardView.buttonFont
        self.buttonLabel.textColor = ScheduledCallCardView.deepColor
        self.button.addSubview(self.buttonLabel)
        self.buttonIcon.tintColor = ScheduledCallCardView.deepColor
        self.buttonIcon.contentMode = .center
        self.button.addSubview(self.buttonIcon)
        self.button.addTarget(self, action: #selector(self.buttonPressed), for: .touchUpInside)
        self.button.highligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            scheduledCallAnimatePress(self.button.layer, highlighted: highlighted)
        }
        self.shapeView.addSubview(self.button)
        // VoiceOver reads the card as one element; its button is an action of it.
        self.isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func buttonPressed() {
        guard let action = self.model?.action else {
            return
        }
        self.action?(action)
    }

    /// Whether a touch at `point` belongs to the card's button.
    public func isInteractive(at point: CGPoint) -> Bool {
        return !self.button.isHidden && self.button.frame.contains(point)
    }

    /// Lays the card out for `model` and returns its size. `animated`: a change that has just happened is shown (the
    /// call accepted).
    @discardableResult
    public func update(model: Model, context: AccountContext, theme: PresentationTheme, animated: Bool) -> CGSize {
        let previous = self.model
        self.model = model
        let layout = ScheduledCallCardView.layout(model: model)
        let size = layout.size
        let strings = model.strings

        self.revealView.frame = CGRect(origin: CGPoint(), size: size)
        self.shapeView.frame = CGRect(origin: CGPoint(), size: size)
        self.gradientLayer.frame = self.shapeView.bounds
        self.glowLayer.frame = self.shapeView.bounds

        self.clockView.frame = layout.clockFrame
        self.clockView.update(size: layout.clockFrame.size, style: .face(top: .white, bottom: UIColor(rgb: 0xeafbef), ticks: ScheduledCallCardView.middleColor.withAlphaComponent(0.55), hands: ScheduledCallCardView.deepColor, center: ScheduledCallCardView.middleColor))
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let components = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(model.call.timestamp)))
        if previous?.call.timestamp != model.call.timestamp {
            self.clockView.setTime(hour: components.hour ?? 0, minute: components.minute ?? 0, animated: false)
        }

        self.eyebrowLabel.attributedText = NSAttributedString(string: strings.ScheduledCall_Eyebrow.uppercased(), attributes: [.kern: 1.4, .font: ScheduledCallCardView.eyebrowFont, .foregroundColor: UIColor(white: 1.0, alpha: 0.7)])
        self.eyebrowLabel.frame = layout.eyebrowFrame
        self.titleView.update(text: NSAttributedString(string: ScheduledCallCardView.titleText(model), attributes: [.font: ScheduledCallCardView.titleFont, .foregroundColor: UIColor.white]), width: layout.titleFrame.width, maxLines: 2)
        self.titleView.frame = layout.titleFrame
        self.subtitleLabel.text = ScheduledCallCardView.subtitleText(model)
        self.subtitleLabel.frame = layout.subtitleFrame
        if let zoneFrame = layout.zoneFrame {
            self.zoneLabel.isHidden = false
            self.zoneLabel.text = ScheduledCallCardView.zoneText(model)
            self.zoneLabel.frame = zoneFrame
        } else {
            self.zoneLabel.isHidden = true
        }
        self.separator.frame = CGRect(x: ScheduledCallCardView.inset, y: layout.separatorY, width: size.width - ScheduledCallCardView.inset * 2.0, height: UIScreenPixel)

        let avatarSize = CGSize(width: ScheduledCallCardView.avatarSize, height: ScheduledCallCardView.avatarSize)
        self.callerAvatar.frame = layout.callerAvatarFrame
        self.callerAvatar.setPeer(context: context, theme: theme, peer: model.caller.peer, displayDimensions: avatarSize)
        self.calleeAvatar.frame = layout.calleeAvatarFrame
        self.calleeAvatar.setPeer(context: context, theme: theme, peer: model.callee.peer, displayDimensions: avatarSize)
        self.callerName.text = model.caller.id == model.viewerId ? strings.ScheduledCall_You : model.caller.name
        self.callerName.frame = layout.callerNameFrame
        self.calleeName.text = model.callee.id == model.viewerId ? strings.ScheduledCall_You : model.callee.name
        self.calleeName.frame = layout.calleeNameFrame

        self.lineTrack.frame = layout.lineFrame
        self.phoneBadge.frame = layout.phoneFrame
        self.phoneIcon.frame = self.phoneBadge.bounds
        let ringFrame = layout.calleeAvatarFrame.insetBy(dx: -3.5, dy: -3.5)
        self.calleeRing.frame = ringFrame
        self.calleeRing.path = UIBezierPath(arcCenter: CGPoint(x: ringFrame.width * 0.5, y: ringFrame.height * 0.5), radius: ringFrame.width * 0.5, startAngle: -.pi * 0.5, endAngle: .pi * 1.5, clockwise: true).cgPath
        self.checkBadge.frame = CGRect(x: layout.calleeAvatarFrame.maxX - 13.0, y: layout.calleeAvatarFrame.maxY - 13.0, width: 18.0, height: 18.0)
        self.checkIcon.frame = self.checkBadge.bounds
        self.checkBadge.layer.borderWidth = 2.0
        self.checkBadge.layer.borderColor = ScheduledCallCardView.middleColor.cgColor

        let accepted = model.isAccepted
        let becameAccepted = animated && accepted && previous?.call.id == model.call.id && previous?.isAccepted == false
        self.lineFill.frame = CGRect(x: 0.0, y: 0.0, width: accepted ? layout.lineFrame.width : 0.0, height: layout.lineFrame.height)
        self.calleeRing.strokeEnd = accepted ? 1.0 : 0.0
        self.checkBadge.isHidden = !accepted

        // The status.
        let statusText = ScheduledCallCardView.statusText(model)
        let previousStatus = self.statusLabel.text
        self.statusLabel.text = (accepted && !model.call.isCallable(now: model.now) && !model.call.isOver(now: model.now) ? "✓ " : "") + statusText
        self.statusLabel.sizeToFit()
        let isWaiting = !accepted && !model.isViewerCallee && !model.call.isOver(now: model.now) && !model.call.isCallable(now: model.now)
        let dotsWidth: CGFloat = isWaiting ? 18.0 : 0.0
        let statusWidth = min(layout.statusFrame.width - dotsWidth, self.statusLabel.bounds.width)
        self.statusContainer.frame = layout.statusFrame
        let statusX = floor((layout.statusFrame.width - statusWidth - dotsWidth) * 0.5)
        self.statusLabel.frame = CGRect(x: statusX, y: 0.0, width: statusWidth, height: layout.statusFrame.height)
        self.dotsView.frame = CGRect(x: statusX + statusWidth + 3.0, y: layout.statusFrame.height - 8.0, width: 15.0, height: 4.0)
        for (index, dot) in self.dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * 5.5, y: 0.0, width: 4.0, height: 4.0)
        }
        self.dotsView.isHidden = !isWaiting
        self.updateDotsAnimation()

        // The button.
        if let buttonFrame = layout.buttonFrame, let action = model.action {
            let wasHidden = self.button.isHidden
            self.button.isHidden = false
            self.button.frame = buttonFrame
            let title: String
            let icon: String
            switch action {
            case .accept:
                title = strings.ScheduledCall_Accept
                icon = "checkmark"
            case .call:
                title = strings.ScheduledCall_CallNow
                icon = "phone.fill"
            }
            self.buttonLabel.text = title
            self.buttonLabel.sizeToFit()
            self.buttonIcon.image = UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.0, weight: .bold))?.withRenderingMode(.alwaysTemplate)
            let iconWidth: CGFloat = 18.0
            let contentWidth = iconWidth + 7.0 + self.buttonLabel.bounds.width
            let contentX = floor((buttonFrame.width - contentWidth) * 0.5)
            self.buttonIcon.frame = CGRect(x: contentX, y: floor((buttonFrame.height - iconWidth) * 0.5), width: iconWidth, height: iconWidth)
            self.buttonLabel.frame = CGRect(x: contentX + iconWidth + 7.0, y: floor((buttonFrame.height - self.buttonLabel.bounds.height) * 0.5), width: self.buttonLabel.bounds.width, height: self.buttonLabel.bounds.height)
            self.button.accessibilityLabel = title
            if animated && wasHidden {
                scheduledCallAnimateRiseIn(self.button.layer, delay: 0.1, offset: 10.0, scale: 0.9, blur: 6.0)
            }
        } else if !self.button.isHidden {
            if animated {
                let snapshot = self.button.snapshotView(afterScreenUpdates: false)
                if let snapshot {
                    snapshot.frame = self.button.frame
                    self.shapeView.addSubview(snapshot)
                    snapshot.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak snapshot] _ in
                        snapshot?.removeFromSuperview()
                    })
                    snapshot.layer.animateScale(from: 1.0, to: 0.8, duration: 0.25, removeOnCompletion: false)
                }
            }
            self.button.isHidden = true
        }

        if becameAccepted {
            self.animateAcceptance(previousStatus: previousStatus, lineWidth: layout.lineFrame.width)
        } else if animated, let previousStatus, previousStatus != self.statusLabel.text {
            scheduledCallAnimateBlurIn(self.statusLabel.layer, radius: 4.0, duration: 0.25)
            self.statusLabel.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        }

        self.accessibilityLabel = [strings.ScheduledCall_Eyebrow, ScheduledCallCardView.titleText(model), self.subtitleLabel.text ?? "", self.statusLabel.text ?? ""].joined(separator: ", ")
        if let action = model.action {
            let title = action == .call ? strings.ScheduledCall_CallNow : strings.ScheduledCall_Accept
            self.accessibilityCustomActions = [UIAccessibilityCustomAction(name: title, actionHandler: { [weak self] _ in
                self?.buttonPressed()
                return true
            })]
        } else {
            self.accessibilityCustomActions = nil
        }
        self.bounds = CGRect(origin: CGPoint(), size: size)
        return size
    }

    // MARK: - Acceptance

    private func animateAcceptance(previousStatus: String?, lineWidth: CGFloat) {
        if UIAccessibility.isReduceMotionEnabled {
            // Only the new state fading in.
            for layer in [self.lineFill.layer, self.calleeRing, self.checkBadge.layer, self.statusLabel.layer] {
                layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
            }
            return
        }
        // The line runs from one to the other.
        self.lineFill.layer.animateSpring(from: NSValue(cgRect: CGRect(x: 0.0, y: 0.0, width: 0.0, height: self.lineFill.bounds.height)), to: NSValue(cgRect: self.lineFill.bounds), keyPath: "bounds", duration: 0.7, damping: 90.0)
        self.lineFill.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: 0.0, y: self.lineFill.bounds.height * 0.5)), to: NSValue(cgPoint: self.lineFill.center), keyPath: "position", duration: 0.7, damping: 90.0)
        // The phone in the middle rings.
        self.phoneBadge.layer.animateKeyframes(values: [1.0, 1.25, 0.95, 1.0].map { $0 as NSNumber }, keyTimes: [0.0, 0.35, 0.7, 1.0].map { $0 as NSNumber }, duration: 0.5, keyPath: "transform.scale", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
        let ring = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        ring.values = [0.0, 0.35, -0.3, 0.25, -0.18, 0.1, 0.0].map { $0 as NSNumber }
        ring.duration = 0.7
        self.phoneIcon.layer.add(ring, forKey: "ring")
        // The ring closes round the one who accepted, and their check springs in.
        self.calleeRing.animate(from: 0.0 as NSNumber, to: 1.0 as NSNumber, keyPath: "strokeEnd", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, duration: 0.55, delay: 0.3)
        self.calleeAvatar.layer.animateKeyframes(values: [1.0, 1.14, 0.97, 1.0].map { $0 as NSNumber }, keyTimes: [0.0, 0.35, 0.7, 1.0].map { $0 as NSNumber }, duration: 0.55, keyPath: "transform.scale", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
        self.checkBadge.layer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: 0.55, damping: 52.0)
        self.checkBadge.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15, delay: 0.55)
        self.checkIcon.layer.animateRotation(from: -.pi * 0.5, to: 0.0, duration: 0.4, delay: 0.6)
        // The status changes, the clock gives a ring, and light passes over the card.
        self.statusLabel.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25, delay: 0.25)
        self.statusLabel.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: 0.0, y: 8.0)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.55, delay: 0.25, damping: 80.0, additive: true)
        scheduledCallAnimateBlurIn(self.statusLabel.layer, radius: 6.0, duration: 0.3, delay: 0.25)
        if let previousStatus {
            let outgoing = UILabel()
            outgoing.font = self.statusLabel.font
            outgoing.textColor = self.statusLabel.textColor
            outgoing.text = previousStatus
            outgoing.sizeToFit()
            outgoing.center = CGPoint(x: self.statusContainer.bounds.midX, y: self.statusContainer.bounds.midY)
            self.statusContainer.addSubview(outgoing)
            outgoing.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.25, removeOnCompletion: false, completion: { [weak outgoing] _ in
                outgoing?.removeFromSuperview()
            })
            outgoing.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: -8.0), duration: 0.25, removeOnCompletion: false, additive: true)
        }
        self.clockView.ring(delay: 0.1)
        scheduledCallAnimateSheen(over: self.shapeView, cornerRadius: ScheduledCallCardView.cornerRadius, delay: 0.45, duration: 1.0, alpha: 0.38)
        // The whole card gives a little bounce, and once the ring has closed two soft waves go out from it.
        self.shapeView.layer.animateKeyframes(values: [1.0, 1.022, 0.996, 1.0].map { $0 as NSNumber }, keyTimes: [0.0, 0.3, 0.65, 1.0].map { $0 as NSNumber }, duration: 0.7, keyPath: "transform.scale", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
        for (index, delay) in [0.8, 1.05].enumerated() {
            self.addAcceptanceWave(delay: delay, alpha: index == 0 ? 0.75 : 0.45)
        }
    }

    private func addAcceptanceWave(delay: Double, alpha: Float) {
        let wave = CAShapeLayer()
        wave.frame = self.calleeRing.frame
        wave.path = self.calleeRing.path
        wave.fillColor = UIColor.clear.cgColor
        wave.strokeColor = UIColor.white.cgColor
        wave.lineWidth = 1.5
        wave.opacity = 0.0
        self.shapeView.layer.insertSublayer(wave, below: self.calleeRing)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0 as NSNumber
        scale.toValue = 1.9 as NSNumber
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.0, 0.2, 1.0)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, alpha, 0.0].map { $0 as NSNumber }
        fade.keyTimes = [0.0, 0.12, 1.0].map { $0 as NSNumber }
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.95
        group.beginTime = wave.convertTime(CACurrentMediaTime(), from: nil) + delay
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        wave.add(group, forKey: "wave")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.0, execute: { [weak wave] in
            wave?.removeFromSuperlayer()
        })
    }

    // MARK: - Visibility

    public func updateVisibility(_ isVisible: Bool) {
        guard self.isVisibleInChat != isVisible else {
            return
        }
        self.isVisibleInChat = isVisible
        self.updateDotsAnimation()
    }

    /// The three dots after "Waiting for…" breathe one after another while the card is on screen.
    private func updateDotsAnimation() {
        let shouldAnimate = self.isVisibleInChat && !self.dotsView.isHidden && !UIAccessibility.isReduceMotionEnabled
        for (index, dot) in self.dots.enumerated() {
            if shouldAnimate {
                if dot.layer.animation(forKey: "breathe") == nil {
                    let animation = CAKeyframeAnimation(keyPath: "opacity")
                    animation.values = [0.3, 1.0, 0.3, 0.3]
                    animation.keyTimes = [0.0, 0.2, 0.45, 1.0]
                    animation.duration = 1.2
                    animation.repeatCount = .infinity
                    animation.beginTime = dot.layer.convertTime(CACurrentMediaTime(), from: nil) + Double(index) * 0.18
                    animation.fillMode = .backwards
                    dot.layer.add(animation, forKey: "breathe")
                }
            } else {
                dot.layer.removeAnimation(forKey: "breathe")
            }
            dot.alpha = shouldAnimate ? 1.0 : 0.6
        }
    }

    // MARK: - Opening

    /// The card opens out of its clock in a growing circle, then its parts come in one after another.
    public func animateReveal() {
        guard let model = self.model else {
            return
        }
        if UIAccessibility.isReduceMotionEnabled {
            self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
            return
        }
        let bounds = self.shapeView.bounds
        let anchor = self.clockView.center
        let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY), CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
        let radius = corners.map { hypot($0.x - anchor.x, $0.y - anchor.y) }.max() ?? bounds.width

        let circle = CAShapeLayer()
        circle.frame = bounds
        circle.fillColor = UIColor.white.cgColor
        circle.path = UIBezierPath(arcCenter: anchor, radius: radius, startAngle: 0.0, endAngle: .pi * 2.0, clockwise: true).cgPath
        self.revealView.layer.mask = circle
        circle.animate(from: UIBezierPath(arcCenter: anchor, radius: ScheduledCallCardView.clockSize * 0.5, startAngle: 0.0, endAngle: .pi * 2.0, clockwise: true).cgPath, to: circle.path!, keyPath: "path", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, duration: 0.65, mediaTimingFunction: CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.18, 1.0), completion: { [weak self, weak circle] _ in
            guard let self, let circle, self.revealView.layer.mask === circle else {
                return
            }
            self.revealView.layer.mask = nil
        })
        let offset = CGPoint(x: anchor.x - bounds.midX, y: anchor.y - bounds.midY)
        let scale: CGFloat = 0.92
        self.shapeView.layer.animateSpring(from: scale as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.8, damping: 90.0)
        self.shapeView.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: offset.x * (1.0 - scale), y: offset.y * (1.0 - scale))), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.8, damping: 90.0, additive: true)
        self.gradientLayer.animateAlpha(from: 0.5, to: 1.0, duration: 0.5)

        // The clock pops in and its hands sweep round to the time.
        self.clockView.animateIn(delay: 0.0)
        self.eyebrowLabel.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25, delay: 0.2)
        let titleDuration = self.titleView.animateLettersIn(delay: 0.24, stagger: 0.022)
        scheduledCallAnimateRiseIn(self.subtitleLabel.layer, delay: 0.4, offset: 8.0, scale: 1.0, blur: 4.0)
        if !self.zoneLabel.isHidden {
            scheduledCallAnimateRiseIn(self.zoneLabel.layer, delay: 0.46, offset: 8.0, scale: 1.0, blur: 4.0)
        }
        self.separator.layer.animateScaleX(from: 0.0, to: 1.0, duration: 0.5, delay: 0.45, timingFunction: kCAMediaTimingFunctionSpring)

        // The two people come in from the middle, then the line between them.
        let middle = bounds.midX
        for (index, (avatar, name)) in [(self.callerAvatar.view, self.callerName), (self.calleeAvatar.view, self.calleeName)].enumerated() {
            let delay = 0.52 + Double(index) * 0.08
            let dx = middle - avatar.center.x
            avatar.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: dx * 0.6, y: 0.0)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.7, delay: delay, damping: 78.0, additive: true)
            avatar.layer.animateSpring(from: 0.3 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.7, delay: delay, damping: 64.0)
            avatar.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, delay: delay)
            scheduledCallAnimateRiseIn(name.layer, delay: delay + 0.08, offset: 6.0, scale: 1.0, blur: 4.0)
        }
        self.lineTrack.layer.animateScaleX(from: 0.0, to: 1.0, duration: 0.5, delay: 0.62, timingFunction: kCAMediaTimingFunctionSpring)
        self.phoneBadge.layer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: 0.7, damping: 56.0)
        self.phoneBadge.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15, delay: 0.7)
        let ring = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        ring.values = [0.0, 0.35, -0.3, 0.25, -0.18, 0.1, 0.0].map { $0 as NSNumber }
        ring.duration = 0.7
        ring.beginTime = self.phoneIcon.layer.convertTime(CACurrentMediaTime(), from: nil) + 0.85
        ring.fillMode = .backwards
        self.phoneIcon.layer.add(ring, forKey: "ring")
        if model.isAccepted {
            self.checkBadge.layer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: 0.8, damping: 56.0)
        }

        scheduledCallAnimateRiseIn(self.statusContainer.layer, delay: 0.82, offset: 10.0, scale: 0.94, blur: 6.0)
        if !self.button.isHidden {
            scheduledCallAnimateRiseIn(self.button.layer, delay: 0.9, offset: 12.0, scale: 0.9, blur: 6.0)
        }
        scheduledCallAnimateSheen(over: self.shapeView, cornerRadius: ScheduledCallCardView.cornerRadius, delay: max(titleDuration, 0.7), duration: 1.0)
    }
}
