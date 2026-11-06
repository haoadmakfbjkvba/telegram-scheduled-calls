import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ContextUI
import TelegramPresentationData
import ScheduledCall

/// "Schedule Call" in a profile's menu. The first times it is seen it introduces itself: the row lights up green and
/// grows a little, the clock's hands sweep round, the title comes in letter by letter and a NEW badge pops up.
public final class ScheduledCallMenuItem: ContextMenuCustomItem {
    private static let introductionsKey = "ScheduledCallMenuItem.Introductions"
    private static let introductionCount = 3

    let title: String
    let badge: String
    let action: () -> Void

    public init(title: String, badge: String, action: @escaping () -> Void) {
        self.title = title
        self.badge = badge
        self.action = action
    }

    public func node(presentationData: PresentationData, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) -> ContextMenuCustomNode {
        let introduces = UserDefaults.standard.integer(forKey: ScheduledCallMenuItem.introductionsKey) < ScheduledCallMenuItem.introductionCount
        return ScheduledCallMenuItemNode(presentationData: presentationData, item: self, introduces: introduces, actionSelected: actionSelected)
    }

    fileprivate static func noteIntroduction() {
        let count = UserDefaults.standard.integer(forKey: ScheduledCallMenuItem.introductionsKey)
        UserDefaults.standard.set(count + 1, forKey: ScheduledCallMenuItem.introductionsKey)
    }
}

private final class ScheduledCallMenuItemNode: ASDisplayNode, ContextMenuCustomNode {
    private let item: ScheduledCallMenuItem
    private let actionSelected: (ContextMenuActionResult) -> Void
    private var presentationData: PresentationData
    private let introduces: Bool
    private var didIntroduce = false

    private let tintView = UIView()
    private let contentView = UIView()
    private let clockView = ScheduledCallClockView()
    private let titleView = ScheduledCallTextView()
    private let badgeView = UIView()
    private let badgeLabel = UILabel()

    var needsSeparator: Bool {
        return false
    }

    var needsPadding: Bool {
        return true
    }

    init(presentationData: PresentationData, item: ScheduledCallMenuItem, introduces: Bool, actionSelected: @escaping (ContextMenuActionResult) -> Void) {
        self.item = item
        self.presentationData = presentationData
        self.introduces = introduces
        self.actionSelected = actionSelected
        super.init()

        self.isAccessibilityElement = true
        self.accessibilityLabel = item.title
        self.accessibilityTraits = [.button]
    }

    override func didLoad() {
        super.didLoad()
        self.tintView.isUserInteractionEnabled = false
        self.tintView.alpha = 0.0
        self.view.addSubview(self.tintView)
        self.contentView.isUserInteractionEnabled = false
        self.view.addSubview(self.contentView)
        self.contentView.addSubview(self.clockView)
        self.contentView.addSubview(self.titleView)
        self.badgeLabel.textAlignment = .center
        self.badgeView.addSubview(self.badgeLabel)
        self.badgeView.isHidden = !self.introduces
        self.contentView.addSubview(self.badgeView)
        self.clockView.setTime(hour: 10, minute: 10, animated: false)
        if self.introduces && !UIAccessibility.isReduceMotionEnabled {
            // The row comes in by itself as the menu opens: until then it is empty.
            self.clockView.alpha = 0.0
            self.titleView.alpha = 0.0
            self.badgeView.alpha = 0.0
        }
    }

    override func didEnterHierarchy() {
        super.didEnterHierarchy()
        if self.introduces && !self.didIntroduce {
            self.didIntroduce = true
            ScheduledCallMenuItem.noteIntroduction()
            // As the menu settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: { [weak self] in
                self?.playIntroduction()
            })
        }
    }

    private var titleFont: UIFont {
        return Font.regular(self.presentationData.listsFontSize.baseDisplaySize)
    }

    func updateLayout(constrainedWidth: CGFloat, constrainedHeight: CGFloat) -> (CGSize, (CGSize, ContainedViewLayoutTransition) -> Void) {
        let theme = self.presentationData.theme
        let iconSideInset: CGFloat = 20.0
        let titleX = iconSideInset + 40.0
        let verticalInset: CGFloat = 11.0
        self.badgeLabel.attributedText = NSAttributedString(string: self.item.badge, attributes: [.font: Font.with(size: 11.0, design: .regular, weight: .bold), .kern: 0.4, .foregroundColor: UIColor.white])
        self.badgeLabel.sizeToFit()
        let badgeSize = CGSize(width: self.badgeLabel.bounds.width + 12.0, height: 18.0)
        let badgeSpace = self.introduces ? badgeSize.width + 8.0 : 0.0
        // The title takes what the badge leaves (it is cut short if it has to be), and the badge follows it.
        let titleSize = ScheduledCallTextView.measure(text: NSAttributedString(string: self.item.title, attributes: [.font: self.titleFont]), width: max(1.0, constrainedWidth - titleX - 18.0 - badgeSpace), maxLines: 1)
        let height = verticalInset * 2.0 + max(22.0, titleSize.height)
        let minWidth = titleX + titleSize.width + badgeSpace + 18.0

        return (CGSize(width: minWidth, height: height), { [weak self] size, transition in
            guard let self else {
                return
            }
            self.tintView.frame = CGRect(origin: CGPoint(), size: size)
            self.tintView.backgroundColor = ScheduledCallColors.middle.withAlphaComponent(theme.overallDarkAppearance ? 0.22 : 0.12)
            self.contentView.frame = CGRect(origin: CGPoint(), size: size)
            let iconSize: CGFloat = 24.0
            self.clockView.frame = CGRect(x: iconSideInset + floor((32.0 - iconSize) * 0.5), y: floor((size.height - iconSize) * 0.5), width: iconSize, height: iconSize)
            self.clockView.update(size: CGSize(width: iconSize, height: iconSize), style: .line(theme.contextMenu.primaryColor))
            let titleWidth = max(1.0, min(titleSize.width, size.width - titleX - 18.0 - badgeSpace))
            self.titleView.update(text: NSAttributedString(string: self.item.title, attributes: [.font: self.titleFont, .foregroundColor: theme.contextMenu.primaryColor]), width: titleWidth, maxLines: 1)
            self.titleView.frame = CGRect(origin: CGPoint(x: titleX, y: floor((size.height - titleSize.height) * 0.5)), size: CGSize(width: titleWidth, height: titleSize.height))
            self.badgeView.frame = CGRect(x: self.titleView.frame.maxX + 8.0, y: floor((size.height - badgeSize.height) * 0.5), width: badgeSize.width, height: badgeSize.height)
            self.badgeView.layer.cornerRadius = badgeSize.height * 0.5
            self.badgeView.backgroundColor = ScheduledCallColors.middle
            self.badgeLabel.frame = CGRect(origin: CGPoint(), size: badgeSize)
        })
    }

    /// The row lights up green and grows a little as its parts come in: the clock pops up with its hands sweeping
    /// round, the title rises letter by letter and the NEW badge springs out; then it all settles.
    private func playIntroduction() {
        guard self.isNodeLoaded else {
            return
        }
        self.clockView.alpha = 1.0
        self.titleView.alpha = 1.0
        self.badgeView.alpha = 1.0
        guard !UIAccessibility.isReduceMotionEnabled else {
            return
        }
        self.tintView.alpha = 0.0
        self.tintView.layer.animateKeyframes(values: [0.0, 1.0, 1.0, 0.0].map { $0 as NSNumber }, keyTimes: [0.0, 0.18, 0.65, 1.0].map { $0 as NSNumber }, duration: 1.6, keyPath: "opacity")
        // The whole row grows a little as it fills, then settles.
        self.contentView.layer.animateKeyframes(values: [0.94, 1.075, 1.075, 1.0].map { $0 as NSNumber }, keyTimes: [0.0, 0.3, 0.6, 1.0].map { $0 as NSNumber }, duration: 1.4, keyPath: "transform.scale", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
        self.clockView.layer.animateSpring(from: 0.2 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.7, damping: 54.0)
        self.clockView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.18)
        self.clockView.setTime(hour: 10, minute: 10, animated: true, extraTurns: 2)
        self.clockView.ring(delay: 0.8)
        let _ = self.titleView.animateLettersIn(delay: 0.08, stagger: 0.024)
        if !self.badgeView.isHidden {
            self.badgeView.layer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: 0.42, damping: 52.0)
            self.badgeView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15, delay: 0.42)
            scheduledCallAnimateSheen(over: self.badgeView, cornerRadius: self.badgeView.bounds.height * 0.5, delay: 0.85, duration: 0.7, alpha: 0.6)
        }
    }

    func updateTheme(presentationData: PresentationData) {
        self.presentationData = presentationData
    }

    func canBeHighlighted() -> Bool {
        return true
    }

    func updateIsHighlighted(isHighlighted: Bool) {
    }

    func performAction() {
        self.actionSelected(.dismissWithoutContent)
        self.item.action()
    }
}
