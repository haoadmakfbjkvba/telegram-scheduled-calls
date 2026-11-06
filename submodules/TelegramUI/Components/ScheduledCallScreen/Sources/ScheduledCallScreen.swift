import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import AvatarNode
import TelegramPresentationData
import TelegramStringFormatting
import TextFormat
import ComponentFlow
import ViewControllerComponent
import SheetComponent
import ButtonComponent
import GlassBarButtonComponent
import BundleIconComponent
import ScheduledCall
import ScheduledCallModel

/// A chat that can send a call that has just been scheduled (the chat controller).
public protocol ScheduledCallSendingController: AnyObject {
    func sendScheduledCall(_ call: ScheduledCall)
}

/// The time now (one place, so that it is the same clock everywhere in the form).
private func scheduledCallNow() -> Date {
    return Date()
}

private let slotStartMinutes = 8 * 60
private let slotEndMinutes = 22 * 60
private let slotStep = 30
private let dayCount = 7

/// A button of the form: a day, a time or a length.
private final class ScheduledCallChipView: HighlightTrackingButton {
    let topLabel = UILabel()
    let mainLabel = UILabel()
    /// Whether the chip is the chosen one (the green selection under it, white text).
    private(set) var isChosen: Bool?

    /// Sets the chip's background and text for being chosen or not. When the choice moves, the chip changes as the
    /// selection slides under it: the one chosen keeps its fill and dark text until the selection reaches it, the one
    /// left gets them back as the selection goes, both in a crossfade.
    func setChosen(_ chosen: Bool, background: UIColor, mainColor: UIColor, topText: NSAttributedString?, animated: Bool) {
        let changed = self.isChosen != nil && self.isChosen != chosen
        self.isChosen = chosen
        let fill = chosen ? UIColor.clear : background
        guard changed && animated else {
            self.backgroundColor = fill
            self.mainLabel.textColor = mainColor
            if let topText {
                self.topLabel.attributedText = topText
            }
            return
        }
        let delay = chosen ? 0.07 : 0.0
        UIView.animate(withDuration: 0.24, delay: delay, options: [.curveEaseInOut, .allowUserInteraction], animations: {
            self.backgroundColor = fill
        })
        UIView.transition(with: self.mainLabel, duration: 0.24, options: [.transitionCrossDissolve, .allowUserInteraction], animations: {
            self.mainLabel.textColor = mainColor
        })
        if let topText {
            UIView.transition(with: self.topLabel, duration: 0.24, options: [.transitionCrossDissolve, .allowUserInteraction], animations: {
                self.topLabel.attributedText = topText
            })
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.topLabel.textAlignment = .center
        self.topLabel.isUserInteractionEnabled = false
        self.mainLabel.textAlignment = .center
        self.mainLabel.isUserInteractionEnabled = false
        self.addSubview(self.topLabel)
        self.addSubview(self.mainLabel)
        self.highligthedChanged = { [weak self] highlighted in
            guard let self, self.isEnabled else {
                return
            }
            scheduledCallAnimatePress(self.layer, highlighted: highlighted, pressedScale: 0.92)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ScheduledCallSheetContentComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let context: AccountContext
    let peer: EnginePeer
    let confirm: (Int32, Int32) -> Void
    let close: () -> Void

    init(context: AccountContext, peer: EnginePeer, confirm: @escaping (Int32, Int32) -> Void, close: @escaping () -> Void) {
        self.context = context
        self.peer = peer
        self.confirm = confirm
        self.close = close
    }

    static func ==(lhs: ScheduledCallSheetContentComponent, rhs: ScheduledCallSheetContentComponent) -> Bool {
        return lhs.context === rhs.context && lhs.peer == rhs.peer
    }

    final class View: UIView {
        private let closeButton = ComponentView<Empty>()
        private let titleView = ScheduledCallTextView()
        private let clockView = ScheduledCallClockView()
        private let avatarRing = UIView()
        private let avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 14.0))
        private let dateLabel = ScheduledCallRollingLabel()
        private let detailLabel = UILabel()

        private let daysScroll = UIScrollView()
        private let daySelection = UIView()
        private var dayChips: [ScheduledCallChipView] = []

        private let timesScroll = UIScrollView()
        private let timeSelection = UIView()
        private var timeChips: [ScheduledCallChipView] = []

        private let durationContainer = UIView()
        private let durationSelection = UIView()
        private var durationChips: [ScheduledCallChipView] = []

        private let scheduleButton = ComponentView<Empty>()

        private var component: ScheduledCallSheetContentComponent?
        private var environment: ViewControllerComponentContainer.Environment?
        private weak var state: EmptyComponentState?
        private var isUpdating = false

        private var days: [Date] = []
        private var selectedDay = 0
        private var selectedMinutes = 0
        private var selectedDuration: Int32 = 30
        private var didAnimateIn = false
        private var didScrollToSelection = false
        private var isConfirming = false
        private let haptic = HapticFeedback()

        override init(frame: CGRect) {
            super.init(frame: frame)

            self.addSubview(self.titleView)
            self.addSubview(self.clockView)
            self.avatarRing.isUserInteractionEnabled = false
            self.addSubview(self.avatarRing)
            self.avatarNode.isUserInteractionEnabled = false
            self.avatarRing.addSubview(self.avatarNode.view)
            self.addSubview(self.dateLabel)
            self.detailLabel.font = Font.regular(15.0)
            self.detailLabel.textAlignment = .center
            self.addSubview(self.detailLabel)
            NotificationCenter.default.addObserver(self, selector: #selector(self.significantTimeChange), name: UIApplication.significantTimeChangeNotification, object: nil)

            for scroll in [self.daysScroll, self.timesScroll] {
                scroll.showsHorizontalScrollIndicator = false
                scroll.alwaysBounceHorizontal = true
                scroll.clipsToBounds = false
                scroll.delaysContentTouches = false
                self.addSubview(scroll)
            }
            self.daySelection.isUserInteractionEnabled = false
            self.daysScroll.addSubview(self.daySelection)
            self.timeSelection.isUserInteractionEnabled = false
            self.timesScroll.addSubview(self.timeSelection)

            self.durationContainer.layer.cornerRadius = 19.0
            self.durationSelection.isUserInteractionEnabled = false
            self.durationSelection.layer.cornerRadius = 16.0
            self.durationSelection.layer.shadowColor = UIColor.black.cgColor
            self.durationSelection.layer.shadowOpacity = 0.08
            self.durationSelection.layer.shadowRadius = 4.0
            self.durationSelection.layer.shadowOffset = CGSize(width: 0.0, height: 1.0)
            self.durationContainer.addSubview(self.durationSelection)
            self.addSubview(self.durationContainer)

            self.days = ScheduledCallSheetContentComponent.View.daysAhead()
            // The next whole hour after the next one, or tomorrow morning.
            let components = self.calendar.dateComponents([.hour, .minute], from: scheduledCallNow())
            let nowMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            let candidate = (nowMinutes / 60 + 2) * 60
            if candidate <= slotEndMinutes - slotStep {
                self.selectedDay = 0
                self.selectedMinutes = max(slotStartMinutes, candidate)
            } else {
                self.selectedDay = 1
                self.selectedMinutes = 10 * 60
            }

            for index in 0 ..< self.days.count {
                let chip = ScheduledCallChipView()
                chip.tag = index
                chip.layer.cornerRadius = 16.0
                chip.addTarget(self, action: #selector(self.dayPressed(_:)), for: .touchUpInside)
                self.dayChips.append(chip)
                self.daysScroll.addSubview(chip)
            }
            for minutes in stride(from: slotStartMinutes, through: slotEndMinutes, by: slotStep) {
                let chip = ScheduledCallChipView()
                chip.tag = minutes
                chip.layer.cornerRadius = 15.0
                chip.addTarget(self, action: #selector(self.timePressed(_:)), for: .touchUpInside)
                self.timeChips.append(chip)
                self.timesScroll.addSubview(chip)
            }
            for duration in ScheduledCall.durations {
                let chip = ScheduledCallChipView()
                chip.tag = Int(duration)
                chip.addTarget(self, action: #selector(self.durationPressed(_:)), for: .touchUpInside)
                self.durationChips.append(chip)
                self.durationContainer.addSubview(chip)
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: - Time

        /// Today and the days after it.
        private static func daysAhead() -> [Date] {
            var calendar = Calendar.current
            calendar.timeZone = TimeZone.current
            let today = calendar.startOfDay(for: scheduledCallNow())
            return (0 ..< dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        }

        /// At midnight (or when the clock or the zone changes) the days move on; the chosen time stays if it still can be.
        @objc private func significantTimeChange() {
            let days = ScheduledCallSheetContentComponent.View.daysAhead()
            guard days != self.days, !self.isConfirming else {
                return
            }
            let selectedDate = self.days.indices.contains(self.selectedDay) ? self.days[self.selectedDay] : nil
            self.days = days
            if let selectedDate, let index = days.firstIndex(where: { self.calendar.isDate($0, inSameDayAs: selectedDate) }), self.isSlotAvailable(day: index, minutes: self.selectedMinutes) {
                self.selectedDay = index
            } else if let index = days.indices.first(where: { self.hasAvailableSlots(day: $0) }) {
                self.selectedDay = index
                self.selectedMinutes = stride(from: slotStartMinutes, through: slotEndMinutes, by: slotStep).first(where: { self.isSlotAvailable(day: index, minutes: $0) }) ?? self.selectedMinutes
            }
            self.clockView.setTime(hour: self.selectedMinutes / 60, minute: self.selectedMinutes % 60, animated: !UIAccessibility.isReduceMotionEnabled)
            self.state?.updated(transition: .spring(duration: 0.45))
            self.scrollToSelection(animated: true)
        }

        private func hasAvailableSlots(day: Int) -> Bool {
            return stride(from: slotStartMinutes, through: slotEndMinutes, by: slotStep).contains(where: { self.isSlotAvailable(day: day, minutes: $0) })
        }

        private var calendar: Calendar {
            var calendar = Calendar.current
            calendar.timeZone = TimeZone.current
            return calendar
        }

        private func timestamp(day: Int, minutes: Int) -> Int32 {
            guard day < self.days.count, let date = self.calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: self.days[day]) else {
                return 0
            }
            return Int32(date.timeIntervalSince1970)
        }

        private var selectedTimestamp: Int32 {
            return self.timestamp(day: self.selectedDay, minutes: self.selectedMinutes)
        }

        private func isSlotAvailable(day: Int, minutes: Int) -> Bool {
            return self.timestamp(day: day, minutes: minutes) > Int32(scheduledCallNow().timeIntervalSince1970) + 5 * 60
        }

        private func dateTitle(strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat) -> String {
            let day: String
            switch self.selectedDay {
            case 0:
                day = strings.ScheduledCall_Today
            case 1:
                day = strings.ScheduledCall_Tomorrow
            default:
                let formatter = DateFormatter()
                formatter.locale = localeWithStrings(strings)
                formatter.setLocalizedDateFormatFromTemplate("EEEE")
                day = formatter.string(from: self.days[self.selectedDay])
            }
            let time = stringForShortTimestamp(hours: Int32(self.selectedMinutes / 60), minutes: Int32(self.selectedMinutes % 60), dateTimeFormat: dateTimeFormat)
            return strings.ScheduledCall_DayAtTime(day, time).string
        }

        private func detailText(strings: PresentationStrings) -> String {
            let formatter = DateComponentsFormatter()
            var calendar = self.calendar
            calendar.locale = localeWithStrings(strings)
            formatter.calendar = calendar
            formatter.unitsStyle = .full
            formatter.maximumUnitCount = 1
            let interval = max(60.0, Double(self.selectedTimestamp) - scheduledCallNow().timeIntervalSince1970)
            formatter.allowedUnits = interval >= 24 * 3600 ? [.day, .hour] : (interval >= 3600 ? [.hour] : [.minute])
            let relative = formatter.string(from: interval) ?? ""
            let dateFormatter = DateFormatter()
            dateFormatter.locale = localeWithStrings(strings)
            dateFormatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
            return strings.ScheduledCall_In(relative).string + "  ·  " + dateFormatter.string(from: self.days[self.selectedDay])
        }

        // MARK: - Choosing

        @objc private func dayPressed(_ sender: ScheduledCallChipView) {
            guard !self.isConfirming, sender.tag != self.selectedDay, self.hasAvailableSlots(day: sender.tag) else {
                return
            }
            self.selectedDay = sender.tag
            // A time that has passed today moves to the first one still ahead.
            if !self.isSlotAvailable(day: self.selectedDay, minutes: self.selectedMinutes) {
                if let minutes = stride(from: slotStartMinutes, through: slotEndMinutes, by: slotStep).first(where: { self.isSlotAvailable(day: self.selectedDay, minutes: $0) }) {
                    self.selectedMinutes = minutes
                }
            }
            self.selectionChanged(chip: sender)
        }

        @objc private func timePressed(_ sender: ScheduledCallChipView) {
            guard !self.isConfirming, sender.tag != self.selectedMinutes, self.isSlotAvailable(day: self.selectedDay, minutes: sender.tag) else {
                return
            }
            self.selectedMinutes = sender.tag
            self.selectionChanged(chip: sender)
        }

        @objc private func durationPressed(_ sender: ScheduledCallChipView) {
            guard !self.isConfirming, Int32(sender.tag) != self.selectedDuration else {
                return
            }
            self.selectedDuration = Int32(sender.tag)
            self.haptic.tap()
            if !UIAccessibility.isReduceMotionEnabled {
                scheduledCallAnimatePop(sender.mainLabel.layer, from: 0.9, overshoot: 1.08, duration: 0.36)
            }
            self.state?.updated(transition: .spring(duration: 0.45))
        }

        private func selectionChanged(chip: ScheduledCallChipView?) {
            self.haptic.tap()
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            if let chip, !reduceMotion {
                scheduledCallAnimatePop(chip.layer, from: 0.92, overshoot: 1.06, duration: 0.38)
            }
            self.clockView.setTime(hour: self.selectedMinutes / 60, minute: self.selectedMinutes % 60, animated: !reduceMotion)
            self.state?.updated(transition: .spring(duration: 0.45))
            self.scrollToSelection(animated: true)
        }

        private func scrollToSelection(animated: Bool) {
            for (scroll, chip) in [(self.daysScroll, self.dayChips[self.selectedDay]), (self.timesScroll, self.timeChips.first(where: { $0.tag == self.selectedMinutes }))] {
                guard let chip, scroll.bounds.width > 0.0 else {
                    continue
                }
                let maxOffset = max(0.0, scroll.contentSize.width - scroll.bounds.width)
                let target = min(maxOffset, max(0.0, chip.frame.midX - scroll.bounds.width * 0.5))
                if abs(scroll.contentOffset.x - target) > 0.5 {
                    scroll.setContentOffset(CGPoint(x: target, y: 0.0), animated: animated)
                }
            }
        }

        private func confirm() {
            guard !self.isConfirming, let component = self.component else {
                return
            }
            guard self.isSlotAvailable(day: self.selectedDay, minutes: self.selectedMinutes) else {
                // The time went by while the form was open: the nearest one still ahead is chosen instead, to be confirmed.
                self.haptic.error()
                for day in self.days.indices where day >= self.selectedDay {
                    if let minutes = stride(from: slotStartMinutes, through: slotEndMinutes, by: slotStep).first(where: { self.isSlotAvailable(day: day, minutes: $0) }) {
                        self.selectedDay = day
                        self.selectedMinutes = minutes
                        break
                    }
                }
                self.selectionChanged(chip: nil)
                return
            }
            self.isConfirming = true
            self.haptic.success()
            if !UIAccessibility.isReduceMotionEnabled {
                self.clockView.ring()
            }
            component.confirm(self.selectedTimestamp, self.selectedDuration)
        }

        // MARK: - Appearance

        private func animateIn() {
            guard !UIAccessibility.isReduceMotionEnabled else {
                return
            }
            let _ = self.titleView.animateLettersIn(delay: 0.08, stagger: 0.022)
            self.clockView.animateIn(delay: 0.1)
            self.avatarRing.layer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: 0.42, damping: 56.0)
            self.avatarRing.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15, delay: 0.42)
            self.dateLabel.animateIn(delay: 0.24)
            scheduledCallAnimateRiseIn(self.detailLabel.layer, delay: 0.34, offset: 10.0, scale: 1.0, blur: 4.0)
            for (index, chip) in self.dayChips.enumerated() {
                let delay = 0.36 + Double(index) * 0.035
                chip.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, delay: delay)
                chip.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: 36.0, y: 0.0)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.6, delay: delay, damping: 80.0, additive: true)
                chip.layer.animateSpring(from: 0.8 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: delay, damping: 70.0)
                scheduledCallAnimateBlurIn(chip.layer, radius: 6.0, duration: 0.3, delay: delay)
            }
            self.daySelection.layer.animateSpring(from: 0.4 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: 0.5, damping: 60.0)
            self.daySelection.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, delay: 0.5)
            let visibleTimes = self.timeChips.filter { $0.frame.maxX > self.timesScroll.contentOffset.x && $0.frame.minX < self.timesScroll.contentOffset.x + self.timesScroll.bounds.width }
            for (index, chip) in visibleTimes.enumerated() {
                let delay = 0.46 + Double(index) * 0.035
                chip.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, delay: delay)
                chip.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: 36.0, y: 0.0)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.6, delay: delay, damping: 80.0, additive: true)
                chip.layer.animateSpring(from: 0.8 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: delay, damping: 70.0)
                scheduledCallAnimateBlurIn(chip.layer, radius: 6.0, duration: 0.3, delay: delay)
            }
            self.timeSelection.layer.animateSpring(from: 0.4 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: 0.6, damping: 60.0)
            self.timeSelection.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, delay: 0.6)
            scheduledCallAnimateRiseIn(self.durationContainer.layer, delay: 0.62, offset: 16.0, scale: 0.96, blur: 6.0)
            if let buttonView = self.scheduleButton.view {
                scheduledCallAnimateRiseIn(buttonView.layer, delay: 0.7, offset: 24.0, scale: 0.92, blur: 8.0)
            }
        }

        // MARK: - Layout

        func update(component: ScheduledCallSheetContentComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<ViewControllerComponentContainer.Environment>, transition: ComponentTransition) -> CGSize {
            self.isUpdating = true
            defer {
                self.isUpdating = false
            }
            let environment = environment[ViewControllerComponentContainer.Environment.self].value
            self.component = component
            self.environment = environment
            self.state = state
            let theme = environment.theme
            let strings = environment.strings
            let animated = !transition.animation.isImmediate
            let containedTransition: ContainedViewLayoutTransition = animated ? .animated(duration: 0.45, curve: .spring) : .immediate

            let width = availableSize.width
            let sideInset: CGFloat = 16.0 + environment.safeInsets.left
            let green = ScheduledCallColors.middle
            let chipBackground = theme.overallDarkAppearance ? UIColor(white: 1.0, alpha: 0.08) : theme.list.blocksBackgroundColor
            let primary = theme.list.itemPrimaryTextColor
            let secondary = theme.list.itemSecondaryTextColor

            // The header.
            let closeSize = self.closeButton.update(
                transition: transition,
                component: AnyComponent(GlassBarButtonComponent(
                    size: CGSize(width: 44.0, height: 44.0),
                    backgroundColor: nil,
                    isDark: theme.overallDarkAppearance,
                    state: .glass,
                    component: AnyComponentWithIdentity(id: "close", component: AnyComponent(BundleIconComponent(
                        name: "Navigation/Close",
                        tintColor: theme.chat.inputPanel.panelControlColor
                    ))),
                    action: { [weak self] _ in
                        self?.component?.close()
                    }
                )),
                environment: {},
                containerSize: CGSize(width: 44.0, height: 44.0)
            )
            if let closeView = self.closeButton.view {
                if closeView.superview == nil {
                    self.addSubview(closeView)
                }
                closeView.frame = CGRect(origin: CGPoint(x: sideInset, y: 16.0), size: closeSize)
            }
            let titleSize = self.titleView.update(text: NSAttributedString(string: strings.ScheduledCall_Title, attributes: [.font: Font.semibold(17.0), .foregroundColor: primary]), width: width - 140.0, maxLines: 1)
            self.titleView.frame = CGRect(origin: CGPoint(x: floor((width - titleSize.width) * 0.5), y: 16.0 + floor((44.0 - titleSize.height) * 0.5)), size: titleSize)

            // The clock, with the face of who is called on it.
            let clockSize: CGFloat = 104.0
            let clockFrame = CGRect(x: floor((width - clockSize) * 0.5), y: 72.0, width: clockSize, height: clockSize)
            self.clockView.frame = clockFrame
            self.clockView.update(size: clockFrame.size, style: .face(top: ScheduledCallColors.top, bottom: ScheduledCallColors.bottom, ticks: UIColor(white: 1.0, alpha: 0.7), hands: .white, center: .white))
            if !self.didAnimateIn {
                self.clockView.setTime(hour: self.selectedMinutes / 60, minute: self.selectedMinutes % 60, animated: false)
            }
            let ringSize: CGFloat = 40.0
            self.avatarRing.frame = CGRect(x: clockFrame.maxX - ringSize + 8.0, y: clockFrame.maxY - ringSize + 6.0, width: ringSize, height: ringSize)
            self.avatarRing.layer.cornerRadius = ringSize * 0.5
            self.avatarRing.backgroundColor = theme.actionSheet.opaqueItemBackgroundColor
            self.avatarNode.frame = self.avatarRing.bounds.insetBy(dx: 3.0, dy: 3.0)
            self.avatarNode.setPeer(context: component.context, theme: theme, peer: component.peer, displayDimensions: CGSize(width: ringSize - 6.0, height: ringSize - 6.0))

            // When.
            let dateSize = self.dateLabel.update(text: self.dateTitle(strings: strings, dateTimeFormat: environment.dateTimeFormat), font: Font.with(size: 28.0, design: .round, weight: .bold), color: primary, animated: animated && self.didAnimateIn && !UIAccessibility.isReduceMotionEnabled)
            let dateFrame = CGRect(x: floor((width - dateSize.width) * 0.5), y: clockFrame.maxY + 18.0, width: dateSize.width, height: dateSize.height)
            if animated && self.didAnimateIn {
                containedTransition.updateFrame(view: self.dateLabel, frame: dateFrame)
            } else {
                self.dateLabel.frame = dateFrame
            }
            let detail = self.detailText(strings: strings)
            if self.detailLabel.text != detail {
                let changed = self.detailLabel.text != nil
                self.detailLabel.text = detail
                if changed && animated {
                    self.detailLabel.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
                    scheduledCallAnimateBlurIn(self.detailLabel.layer, radius: 4.0, duration: 0.25)
                }
            }
            self.detailLabel.textColor = secondary
            let detailFrame = CGRect(x: sideInset, y: dateFrame.maxY + 4.0, width: width - sideInset * 2.0, height: 20.0)
            self.detailLabel.frame = detailFrame
            var y = detailFrame.maxY + 24.0

            // The days.
            let dayChipSize = CGSize(width: 54.0, height: 64.0)
            let chipSpacing: CGFloat = 8.0
            let weekdayFormatter = DateFormatter()
            weekdayFormatter.locale = localeWithStrings(strings)
            weekdayFormatter.setLocalizedDateFormatFromTemplate("EEE")
            let dayNumberFormatter = DateFormatter()
            dayNumberFormatter.locale = localeWithStrings(strings)
            dayNumberFormatter.setLocalizedDateFormatFromTemplate("d")
            for (index, chip) in self.dayChips.enumerated() {
                let isSelected = index == self.selectedDay
                chip.frame = CGRect(x: sideInset + CGFloat(index) * (dayChipSize.width + chipSpacing), y: 0.0, width: dayChipSize.width, height: dayChipSize.height)
                let weekday = index == 0 ? strings.ScheduledCall_Today : weekdayFormatter.string(from: self.days[index])
                chip.topLabel.frame = CGRect(x: 0.0, y: 11.0, width: dayChipSize.width, height: 14.0)
                chip.mainLabel.font = Font.with(size: 22.0, design: .round, weight: .semibold)
                chip.mainLabel.text = dayNumberFormatter.string(from: self.days[index])
                chip.setChosen(isSelected, background: chipBackground, mainColor: isSelected ? .white : primary, topText: NSAttributedString(string: weekday.uppercased(), attributes: [.font: Font.semibold(10.0), .kern: 0.4, .foregroundColor: isSelected ? UIColor(white: 1.0, alpha: 0.85) : secondary]), animated: animated)
                chip.mainLabel.frame = CGRect(x: 0.0, y: 27.0, width: dayChipSize.width, height: 28.0)
                let isDayAvailable = self.hasAvailableSlots(day: index)
                chip.isEnabled = isDayAvailable
                let dayAlpha: CGFloat = isDayAvailable ? 1.0 : 0.35
                if chip.alpha != dayAlpha {
                    containedTransition.updateAlpha(layer: chip.layer, alpha: dayAlpha)
                }
                chip.accessibilityLabel = weekday + " " + (chip.mainLabel.text ?? "")
                chip.accessibilityTraits = isSelected ? [.button, .selected] : (isDayAvailable ? [.button] : [.button, .notEnabled])
            }
            self.daysScroll.frame = CGRect(x: 0.0, y: y, width: width, height: dayChipSize.height)
            self.daysScroll.contentSize = CGSize(width: sideInset * 2.0 + CGFloat(self.dayChips.count) * dayChipSize.width + CGFloat(self.dayChips.count - 1) * chipSpacing, height: dayChipSize.height)
            self.daySelection.backgroundColor = green
            self.daySelection.layer.cornerRadius = 16.0
            containedTransition.updateFrame(view: self.daySelection, frame: self.dayChips[self.selectedDay].frame)
            self.daysScroll.sendSubviewToBack(self.daySelection)
            y += dayChipSize.height + 14.0

            // The times.
            let timeChipSize = CGSize(width: 72.0, height: 44.0)
            for (index, chip) in self.timeChips.enumerated() {
                let minutes = chip.tag
                let isSelected = minutes == self.selectedMinutes
                let isAvailable = self.isSlotAvailable(day: self.selectedDay, minutes: minutes)
                chip.frame = CGRect(x: sideInset + CGFloat(index) * (timeChipSize.width + chipSpacing), y: 0.0, width: timeChipSize.width, height: timeChipSize.height)
                chip.mainLabel.font = Font.with(size: 17.0, design: .round, weight: .semibold)
                chip.mainLabel.text = stringForShortTimestamp(hours: Int32(minutes / 60), minutes: Int32(minutes % 60), dateTimeFormat: environment.dateTimeFormat)
                chip.setChosen(isSelected, background: chipBackground, mainColor: isSelected ? .white : primary, topText: nil, animated: animated)
                chip.mainLabel.frame = chip.bounds
                chip.isEnabled = isAvailable
                let alpha: CGFloat = isAvailable ? 1.0 : 0.35
                if chip.alpha != alpha {
                    containedTransition.updateAlpha(layer: chip.layer, alpha: alpha)
                }
                chip.accessibilityLabel = chip.mainLabel.text
                chip.accessibilityTraits = isSelected ? [.button, .selected] : (isAvailable ? [.button] : [.button, .notEnabled])
            }
            self.timesScroll.frame = CGRect(x: 0.0, y: y, width: width, height: timeChipSize.height)
            self.timesScroll.contentSize = CGSize(width: sideInset * 2.0 + CGFloat(self.timeChips.count) * timeChipSize.width + CGFloat(self.timeChips.count - 1) * chipSpacing, height: timeChipSize.height)
            self.timeSelection.backgroundColor = green
            self.timeSelection.layer.cornerRadius = 15.0
            if let selectedChip = self.timeChips.first(where: { $0.tag == self.selectedMinutes }) {
                containedTransition.updateFrame(view: self.timeSelection, frame: selectedChip.frame)
            }
            self.timesScroll.sendSubviewToBack(self.timeSelection)
            y += timeChipSize.height + 22.0

            // How long.
            let durationFrame = CGRect(x: sideInset, y: y, width: width - sideInset * 2.0, height: 38.0)
            self.durationContainer.frame = durationFrame
            self.durationContainer.backgroundColor = chipBackground
            let segmentWidth = floor((durationFrame.width - 6.0) / CGFloat(self.durationChips.count))
            for (index, chip) in self.durationChips.enumerated() {
                let isSelected = Int32(chip.tag) == self.selectedDuration
                chip.frame = CGRect(x: 3.0 + CGFloat(index) * segmentWidth, y: 3.0, width: segmentWidth, height: 32.0)
                chip.mainLabel.font = isSelected ? Font.semibold(14.0) : Font.medium(14.0)
                chip.mainLabel.text = chip.tag == 60 ? strings.ScheduledCall_OneHour : strings.ScheduledCall_Minutes("\(chip.tag)").string
                chip.mainLabel.textColor = primary
                chip.mainLabel.frame = chip.bounds
                chip.accessibilityLabel = chip.mainLabel.text
                chip.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
                if isSelected {
                    containedTransition.updateFrame(view: self.durationSelection, frame: chip.frame)
                }
            }
            self.durationSelection.backgroundColor = theme.overallDarkAppearance ? UIColor(white: 1.0, alpha: 0.2) : .white
            y = durationFrame.maxY + 26.0

            // Schedule.
            let buttonInsets = ContainerViewLayout.concentricInsets(bottomInset: environment.safeInsets.bottom, innerDiameter: 52.0, sideInset: 30.0)
            let buttonSize = self.scheduleButton.update(
                transition: transition,
                component: AnyComponent(ButtonComponent(
                    background: ButtonComponent.Background(
                        style: .glass,
                        color: green,
                        foreground: .white,
                        pressedColor: green.withMultipliedAlpha(0.9),
                        cornerRadius: 26.0
                    ),
                    content: AnyComponentWithIdentity(id: "schedule", component: AnyComponent(Text(
                        text: strings.ScheduledCall_Schedule,
                        font: Font.semibold(17.0),
                        color: .white
                    ))),
                    isEnabled: !self.isConfirming,
                    tintWhenDisabled: false,
                    action: { [weak self] in
                        self?.confirm()
                    }
                )),
                environment: {},
                containerSize: CGSize(width: max(1.0, width - buttonInsets.left - buttonInsets.right), height: 52.0)
            )
            if let buttonView = self.scheduleButton.view {
                if buttonView.superview == nil {
                    self.addSubview(buttonView)
                }
                buttonView.frame = CGRect(origin: CGPoint(x: floor((width - buttonSize.width) * 0.5), y: y), size: buttonSize)
            }
            y += buttonSize.height + buttonInsets.bottom

            if !self.didScrollToSelection && width > 0.0 {
                self.didScrollToSelection = true
                self.scrollToSelection(animated: false)
            }
            if !self.didAnimateIn {
                self.didAnimateIn = true
                self.animateIn()
            }
            return CGSize(width: width, height: y)
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<ViewControllerComponentContainer.Environment>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

private final class ScheduledCallSheetComponent: CombinedComponent {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let context: AccountContext
    let peer: EnginePeer

    init(context: AccountContext, peer: EnginePeer) {
        self.context = context
        self.peer = peer
    }

    static func ==(lhs: ScheduledCallSheetComponent, rhs: ScheduledCallSheetComponent) -> Bool {
        return lhs.context === rhs.context && lhs.peer == rhs.peer
    }

    static var body: Body {
        let sheet = Child(SheetComponent<EnvironmentType>.self)
        let animateOut = StoredActionSlot(Action<Void>.self)
        let externalState = SheetComponent<EnvironmentType>.ExternalState()

        return { context in
            let environment = context.environment[EnvironmentType.self]
            let controller = environment.controller

            let sheet = sheet.update(
                component: SheetComponent<EnvironmentType>(
                    content: AnyComponent(ScheduledCallSheetContentComponent(
                        context: context.component.context,
                        peer: context.component.peer,
                        confirm: { timestamp, duration in
                            (controller() as? ScheduledCallScreen)?.finish(animated: true, animateOut: animateOut, result: (timestamp, duration))
                        },
                        close: {
                            (controller() as? ScheduledCallScreen)?.finish(animated: true, animateOut: animateOut, result: nil)
                        }
                    )),
                    style: .glass,
                    backgroundColor: .color(environment.theme.actionSheet.opaqueItemBackgroundColor),
                    followContentSizeChanges: true,
                    clipsContent: true,
                    autoAnimateOut: false,
                    externalState: externalState,
                    animateOut: animateOut,
                    onPan: {},
                    willDismiss: {}
                ),
                environment: {
                    environment
                    SheetComponentEnvironment(
                        metrics: environment.metrics,
                        deviceMetrics: environment.deviceMetrics,
                        isDisplaying: environment.value.isVisible,
                        isCentered: environment.presentsFloatingPanels,
                        hasInputHeight: !environment.inputHeight.isZero,
                        regularMetricsSize: CGSize(width: 430.0, height: 900.0),
                        dismiss: { animated in
                            (controller() as? ScheduledCallScreen)?.finish(animated: animated, animateOut: animateOut, result: nil)
                        }
                    )
                },
                availableSize: context.availableSize,
                transition: context.transition
            )
            context.add(sheet.position(CGPoint(x: context.availableSize.width / 2.0, y: context.availableSize.height / 2.0)))
            return context.availableSize
        }
    }
}

/// The form a call is scheduled in, from a profile: the day, the time and how long.
public final class ScheduledCallScreen: ViewControllerComponentContainer {
    private let completion: (Int32, Int32) -> Void
    private var isFinishing = false

    /// `completion` gets the time (seconds since 1970) and the length in minutes, once the form has gone.
    public init(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)? = nil, peer: EnginePeer, completion: @escaping (Int32, Int32) -> Void) {
        self.completion = completion
        super.init(
            context: context,
            component: ScheduledCallSheetComponent(context: context, peer: peer),
            navigationBarAppearance: .none,
            statusBarStyle: .ignore,
            theme: .default,
            updatedPresentationData: updatedPresentationData
        )
        self.navigationPresentation = .flatModal
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    fileprivate func finish(animated: Bool, animateOut: ActionSlot<Action<Void>>?, result: (Int32, Int32)?) {
        guard !self.isFinishing else {
            return
        }
        self.isFinishing = true
        let completion = self.completion
        let dismiss: () -> Void = { [weak self] in
            if let self {
                if let navigationController = self.navigationController as? NavigationController {
                    navigationController.setViewControllers(navigationController.viewControllers.filter { $0 !== self }, animated: false)
                } else {
                    self.dismiss()
                }
            }
            if let result {
                completion(result.0, result.1)
            }
        }
        if animated, let animateOut {
            animateOut.invoke(Action { _ in dismiss() })
        } else {
            dismiss()
        }
    }
}
