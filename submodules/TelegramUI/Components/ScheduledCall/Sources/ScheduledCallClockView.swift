import Foundation
import UIKit
import Display

/// An analog clock whose hands turn to a time: a filled face for the form and the card, or a line icon for a menu.
public final class ScheduledCallClockView: UIView {
    public enum Style: Equatable {
        /// A filled face with ticks.
        case face(top: UIColor, bottom: UIColor, ticks: UIColor, hands: UIColor, center: UIColor)
        /// A line icon in one colour.
        case line(UIColor)
    }

    private let faceLayer = CAGradientLayer()
    private let faceMask = CAShapeLayer()
    private let highlightLayer = CAGradientLayer()
    private let rimLayer = CAShapeLayer()
    private let ticksLayer = CAShapeLayer()
    private let hourHand = CAShapeLayer()
    private let minuteHand = CAShapeLayer()
    private let centerDot = CAShapeLayer()

    private var style: Style?
    private var currentSize = CGSize()
    /// The hands' angles, unbounded, so that they always turn forward.
    private var hourAngle: CGFloat = 0.0
    private var minuteAngle: CGFloat = 0.0

    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.faceLayer.mask = self.faceMask
        self.layer.addSublayer(self.faceLayer)
        self.highlightLayer.type = .radial
        self.highlightLayer.colors = [UIColor(white: 1.0, alpha: 0.35).cgColor, UIColor(white: 1.0, alpha: 0.0).cgColor]
        self.highlightLayer.startPoint = CGPoint(x: 0.3, y: 0.2)
        self.highlightLayer.endPoint = CGPoint(x: 1.0, y: 0.9)
        self.layer.addSublayer(self.highlightLayer)
        self.rimLayer.fillColor = UIColor.clear.cgColor
        self.layer.addSublayer(self.rimLayer)
        self.ticksLayer.fillColor = UIColor.clear.cgColor
        self.ticksLayer.lineCap = .round
        self.layer.addSublayer(self.ticksLayer)
        for hand in [self.hourHand, self.minuteHand] {
            hand.fillColor = UIColor.clear.cgColor
            hand.lineCap = .round
            hand.anchorPoint = CGPoint(x: 0.5, y: 1.0)
            self.layer.addSublayer(hand)
        }
        self.layer.addSublayer(self.centerDot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(size: CGSize, style: Style) {
        guard self.currentSize != size || self.style != style else {
            return
        }
        self.currentSize = size
        self.style = style
        let bounds = CGRect(origin: CGPoint(), size: size)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(size.width, size.height) * 0.5

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style {
        case let .face(top, bottom, ticks, hands, centerColor):
            self.faceLayer.isHidden = false
            self.highlightLayer.isHidden = false
            self.faceLayer.frame = bounds
            self.faceLayer.colors = [top.cgColor, bottom.cgColor]
            self.faceLayer.startPoint = CGPoint(x: 0.2, y: 0.0)
            self.faceLayer.endPoint = CGPoint(x: 0.8, y: 1.0)
            self.faceMask.frame = bounds
            self.faceMask.path = UIBezierPath(ovalIn: bounds).cgPath
            self.highlightLayer.frame = bounds
            let highlightMask = CAShapeLayer()
            highlightMask.path = UIBezierPath(ovalIn: bounds).cgPath
            self.highlightLayer.mask = highlightMask
            self.rimLayer.isHidden = false
            self.rimLayer.frame = bounds
            self.rimLayer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: radius * 0.02, dy: radius * 0.02)).cgPath
            self.rimLayer.strokeColor = UIColor(white: 1.0, alpha: 0.28).cgColor
            self.rimLayer.lineWidth = max(1.0, radius * 0.03)

            let ticksPath = UIBezierPath()
            for index in 0 ..< 12 {
                let angle = CGFloat(index) / 12.0 * .pi * 2.0
                let isQuarter = index % 3 == 0
                let outer = radius * 0.84
                let inner = radius * (isQuarter ? 0.68 : 0.75)
                ticksPath.move(to: CGPoint(x: center.x + sin(angle) * inner, y: center.y - cos(angle) * inner))
                ticksPath.addLine(to: CGPoint(x: center.x + sin(angle) * outer, y: center.y - cos(angle) * outer))
            }
            self.ticksLayer.frame = bounds
            self.ticksLayer.path = ticksPath.cgPath
            self.ticksLayer.strokeColor = ticks.cgColor
            self.ticksLayer.lineWidth = max(1.0, radius * 0.045)
            self.ticksLayer.isHidden = false

            self.layoutHands(center: center, hourLength: radius * 0.42, minuteLength: radius * 0.62, hourWidth: max(2.0, radius * 0.1), minuteWidth: max(1.5, radius * 0.065), color: hands)
            let dot = max(3.0, radius * 0.14)
            self.centerDot.frame = bounds
            self.centerDot.path = UIBezierPath(ovalIn: CGRect(x: center.x - dot * 0.5, y: center.y - dot * 0.5, width: dot, height: dot)).cgPath
            self.centerDot.fillColor = centerColor.cgColor
        case let .line(color):
            self.faceLayer.isHidden = true
            self.highlightLayer.isHidden = true
            self.ticksLayer.isHidden = true
            self.rimLayer.isHidden = false
            self.rimLayer.frame = bounds
            let lineWidth: CGFloat = 1.66
            self.rimLayer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: radius * 0.12 + lineWidth * 0.5, dy: radius * 0.12 + lineWidth * 0.5)).cgPath
            self.rimLayer.strokeColor = color.cgColor
            self.rimLayer.lineWidth = lineWidth
            self.layoutHands(center: center, hourLength: radius * 0.38, minuteLength: radius * 0.56, hourWidth: lineWidth, minuteWidth: lineWidth, color: color)
            self.centerDot.frame = bounds
            self.centerDot.path = UIBezierPath(ovalIn: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3.0, height: 3.0)).cgPath
            self.centerDot.fillColor = color.cgColor
        }
        CATransaction.commit()
    }

    private func layoutHands(center: CGPoint, hourLength: CGFloat, minuteLength: CGFloat, hourWidth: CGFloat, minuteWidth: CGFloat, color: UIColor) {
        for (hand, length, width, angle) in [(self.hourHand, hourLength, hourWidth, self.hourAngle), (self.minuteHand, minuteLength, minuteWidth, self.minuteAngle)] {
            let handBounds = CGRect(x: 0.0, y: 0.0, width: width * 2.0, height: length)
            hand.transform = CATransform3DIdentity
            hand.bounds = handBounds
            hand.position = center
            let path = UIBezierPath()
            path.move(to: CGPoint(x: handBounds.midX, y: length))
            path.addLine(to: CGPoint(x: handBounds.midX, y: width * 0.5))
            hand.path = path.cgPath
            hand.lineWidth = width
            hand.strokeColor = color.cgColor
            hand.transform = CATransform3DMakeRotation(angle, 0.0, 0.0, 1.0)
        }
    }

    /// Turns the hands to `hour`:`minute`, always forward; `extraTurns` sends the minute hand round more times first.
    public func setTime(hour: Int, minute: Int, animated: Bool, extraTurns: Int = 0, delay: Double = 0.0) {
        let minuteTarget = CGFloat(minute) / 60.0 * .pi * 2.0
        let hourTarget = (CGFloat(hour % 12) + CGFloat(minute) / 60.0) / 12.0 * .pi * 2.0

        func forward(from current: CGFloat, to target: CGFloat, extra: Int) -> CGFloat {
            let full = CGFloat.pi * 2.0
            var value = target + floor(current / full) * full
            while value < current - 0.0001 {
                value += full
            }
            return value + CGFloat(extra) * full
        }

        let previousHour = self.hourAngle
        let previousMinute = self.minuteAngle
        // The hands always turn forward (clockwise) to the new time.
        let newMinute: CGFloat
        let newHour: CGFloat
        if animated {
            newMinute = forward(from: previousMinute, to: minuteTarget, extra: extraTurns)
            newHour = forward(from: previousHour, to: hourTarget, extra: 0)
        } else {
            newMinute = minuteTarget
            newHour = hourTarget
        }
        self.minuteAngle = newMinute
        self.hourAngle = newHour

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.minuteHand.transform = CATransform3DMakeRotation(newMinute, 0.0, 0.0, 1.0)
        self.hourHand.transform = CATransform3DMakeRotation(newHour, 0.0, 0.0, 1.0)
        CATransaction.commit()

        guard animated else {
            self.minuteHand.removeAnimation(forKey: "turn")
            self.hourHand.removeAnimation(forKey: "turn")
            return
        }
        let presentationMinute = (self.minuteHand.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber).map { CGFloat($0.doubleValue) } ?? previousMinute
        let presentationHour = (self.hourHand.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber).map { CGFloat($0.doubleValue) } ?? previousHour
        // The presentation value is folded into (-π, π]: take the turn of the stored angle.
        func unfold(_ value: CGFloat, near reference: CGFloat) -> CGFloat {
            let full = CGFloat.pi * 2.0
            return value + round((reference - value) / full) * full
        }
        let fromMinute = unfold(presentationMinute, near: previousMinute)
        let fromHour = unfold(presentationHour, near: previousHour)
        let duration = 0.9 + Double(extraTurns) * 0.25
        self.minuteHand.animateSpring(from: fromMinute as NSNumber, to: newMinute as NSNumber, keyPath: "transform.rotation.z", duration: duration, delay: delay, damping: 82.0, key: "turn")
        self.hourHand.animateSpring(from: fromHour as NSNumber, to: newHour as NSNumber, keyPath: "transform.rotation.z", duration: duration, delay: delay, damping: 88.0, key: "turn")
    }

    /// The clock comes in: out of a small dot, the hands sweeping round to their time.
    public func animateIn(delay: Double) {
        self.layer.animateSpring(from: 0.2 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.7, delay: delay, damping: 60.0)
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, delay: delay)
        self.ticksLayer.animate(from: 0.0 as NSNumber, to: 1.0 as NSNumber, keyPath: "strokeEnd", timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, duration: 0.55, delay: delay + 0.1)
        let full = CGFloat.pi * 2.0
        self.minuteHand.animateSpring(from: (self.minuteAngle - full * 2.0) as NSNumber, to: self.minuteAngle as NSNumber, keyPath: "transform.rotation.z", duration: 1.3, delay: delay, damping: 82.0, key: "turn")
        self.hourHand.animateSpring(from: (self.hourAngle - full * 0.5) as NSNumber, to: self.hourAngle as NSNumber, keyPath: "transform.rotation.z", duration: 1.3, delay: delay, damping: 88.0, key: "turn")
    }

    /// A little shake, as of a ringing bell.
    public func ring(delay: Double = 0.0) {
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = [0.0, 0.22, -0.2, 0.16, -0.12, 0.07, -0.03, 0.0].map { $0 as NSNumber }
        animation.duration = 0.6
        animation.isAdditive = true
        animation.beginTime = self.layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.fillMode = .backwards
        self.layer.add(animation, forKey: "ring")
    }
}

/// The green of scheduled calls, as on the card.
public enum ScheduledCallColors {
    public static let top = UIColor(rgb: 0x48d672)
    public static let middle = UIColor(rgb: 0x27b356)
    public static let bottom = UIColor(rgb: 0x13893d)
    public static let deep = UIColor(rgb: 0x0f7a35)
}
