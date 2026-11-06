import Foundation
import UIKit
import Display
import ScheduledCall

/// A line of text whose letters change in place: what stays slides to its new spot, what goes falls away, and what
/// comes rises in, so "Today, 11:00" turns into "Tomorrow, 10:00" letter by letter. Writing whose letters join or run
/// from right to left changes as a whole line instead.
final class ScheduledCallRollingLabel: UIView {
    private final class Glyph {
        let piece: String
        let label: UILabel

        init(piece: String) {
            self.piece = piece
            self.label = UILabel()
            self.label.text = piece
        }
    }

    /// Whether the letters of `text` can be set one by one: not for scripts that join letters, shape them together or
    /// run from right to left.
    private static func isPerLetter(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590 ... 0x08FF, 0x0900 ... 0x0DFF, 0x0E00 ... 0x0FFF, 0x1000 ... 0x109F, 0x1780 ... 0x17FF, 0x1800 ... 0x18AF, 0xA800 ... 0xABFF, 0xFB1D ... 0xFDFF, 0xFE70 ... 0xFEFF, 0x200F, 0x202B, 0x202E:
                return false
            default:
                continue
            }
        }
        return true
    }

    private var glyphs: [Glyph] = []
    private(set) var textSize = CGSize()
    private var font: UIFont = Font.regular(17.0)
    private var color: UIColor = .black

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = true
        self.accessibilityTraits = [.staticText, .updatesFrequently]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var text: String {
        return self.glyphs.map { $0.piece }.joined()
    }

    /// Lays `text` out from the left and returns its size.
    @discardableResult
    func update(text: String, font: UIFont, color: UIColor, animated: Bool) -> CGSize {
        let characters: [String] = ScheduledCallRollingLabel.isPerLetter(text) ? text.map { String($0) } : [text]
        let old = self.glyphs.map { $0.piece }
        let fontChanged = font != self.font
        self.font = font
        self.color = color

        // What is the same at both ends stays; the middle changes.
        var prefix = 0
        while prefix < min(old.count, characters.count), old[prefix] == characters[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(old.count, characters.count) - prefix, old[old.count - 1 - suffix] == characters[characters.count - 1 - suffix] {
            suffix += 1
        }
        let removed = fontChanged ? self.glyphs : Array(self.glyphs[prefix ..< self.glyphs.count - suffix])
        var updated: [Glyph] = []
        var added: [Glyph] = []
        if fontChanged {
            for character in characters {
                let glyph = Glyph(piece: character)
                updated.append(glyph)
                added.append(glyph)
            }
        } else {
            updated.append(contentsOf: self.glyphs[0 ..< prefix])
            for character in characters[prefix ..< characters.count - suffix] {
                let glyph = Glyph(piece: character)
                updated.append(glyph)
                added.append(glyph)
            }
            updated.append(contentsOf: self.glyphs[self.glyphs.count - suffix ..< self.glyphs.count])
        }
        self.glyphs = updated

        let height = ceil(font.lineHeight)
        var x: CGFloat = 0.0
        let transition: ContainedViewLayoutTransition = animated ? .animated(duration: 0.45, curve: .spring) : .immediate
        for glyph in self.glyphs {
            glyph.label.font = font
            glyph.label.textColor = color
            let width = ceil((glyph.piece as NSString).size(withAttributes: [.font: font]).width)
            let frame = CGRect(x: x, y: 0.0, width: width, height: height)
            x += width
            if let addedIndex = added.firstIndex(where: { $0 === glyph }) {
                self.addSubview(glyph.label)
                glyph.label.frame = frame
                if animated {
                    let delay = Double(addedIndex) * 0.025
                    glyph.label.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.18, delay: delay)
                    glyph.label.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: 0.0, y: height * 0.5)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.5, delay: delay, damping: 78.0, additive: true)
                    glyph.label.layer.animateSpring(from: 0.5 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.5, delay: delay, damping: 70.0)
                    scheduledCallAnimateBlurIn(glyph.label.layer, radius: 5.0, duration: 0.22, delay: delay)
                }
            } else {
                transition.updateFrame(view: glyph.label, frame: frame)
            }
        }
        for glyph in removed {
            let label = glyph.label
            if animated {
                label.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.18, removeOnCompletion: false, completion: { [weak label] _ in
                    label?.removeFromSuperview()
                })
                label.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: -height * 0.4), duration: 0.24, removeOnCompletion: false, additive: true)
                label.layer.animateScale(from: 1.0, to: 0.6, duration: 0.24, removeOnCompletion: false)
            } else {
                label.removeFromSuperview()
            }
        }
        self.textSize = CGSize(width: ceil(x), height: height)
        self.accessibilityLabel = text
        return self.textSize
    }

    /// The letters come in one after another.
    func animateIn(delay: Double) {
        for (index, glyph) in self.glyphs.enumerated() {
            scheduledCallAnimateRiseIn(glyph.label.layer, delay: delay + Double(index) * 0.022, offset: 14.0, scale: 0.7, blur: 6.0)
        }
    }
}
