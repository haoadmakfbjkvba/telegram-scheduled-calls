import Foundation
import UIKit
import CoreText
import Display

// MARK: - Layer animations

/// A layer coming into focus: from `radius` points of blur to sharp.
public func scheduledCallAnimateBlurIn(_ layer: CALayer, radius: CGFloat, duration: Double, delay: Double = 0.0) {
    // Not on a layer that has filters of its own.
    guard layer.filters == nil || layer.value(forKey: "scheduledCallBlur") != nil, let blur = CALayer.blur() else {
        return
    }
    blur.setValue(0.0 as NSNumber, forKey: "inputRadius")
    layer.filters = [blur]
    layer.setValue(true, forKey: "scheduledCallBlur")
    layer.animate(from: radius as NSNumber, to: 0.0 as NSNumber, keyPath: "filters.gaussianBlur.inputRadius", timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, duration: duration, delay: delay, removeOnCompletion: true, completion: { [weak layer] _ in
        // Also when the animation is cut short: a blur filter left on a layer costs a pass on every frame.
        guard let layer, layer.animation(forKey: "filters.gaussianBlur.inputRadius") == nil else {
            return
        }
        layer.filters = nil
        layer.setValue(nil, forKey: "scheduledCallBlur")
    })
}

/// An element rising into place: up from below, out of a blur, a little larger first.
public func scheduledCallAnimateRiseIn(_ layer: CALayer, delay: Double, offset: CGFloat = 18.0, scale: CGFloat = 0.94, blur: CGFloat = 8.0) {
    layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.28, delay: delay)
    layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: 0.0, y: offset)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.7, delay: delay, damping: 88.0, additive: true)
    if scale != 1.0 {
        layer.animateSpring(from: scale as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.7, delay: delay, damping: 88.0)
    }
    if blur > 0.0 {
        scheduledCallAnimateBlurIn(layer, radius: blur, duration: 0.36, delay: delay)
    }
}

/// A short pop: down a little, over, and back.
public func scheduledCallAnimatePop(_ layer: CALayer, from: CGFloat = 0.82, overshoot: CGFloat = 1.12, duration: Double = 0.42) {
    layer.animateKeyframes(values: [1.0, from, overshoot, 0.98, 1.0].map { $0 as NSNumber }, keyTimes: [0.0, 0.25, 0.55, 0.8, 1.0].map { $0 as NSNumber }, duration: duration, keyPath: "transform.scale", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
}

/// A button pressed and released: it gives a little under the finger and springs back.
public func scheduledCallAnimatePress(_ layer: CALayer, highlighted: Bool, pressedScale: CGFloat = 0.96) {
    let current = (layer.presentation()?.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue ?? 1.0
    let target: CGFloat = highlighted ? pressedScale : 1.0
    layer.transform = CATransform3DMakeScale(target, target, 1.0)
    if highlighted {
        layer.animate(from: current as NSNumber, to: target as NSNumber, keyPath: "transform.scale", timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, duration: 0.12)
    } else {
        layer.animateSpring(from: current as NSNumber, to: target as NSNumber, keyPath: "transform.scale", duration: 0.5, damping: 60.0)
    }
}

/// A soft band of light passing over a layer once, clipped to it.
public func scheduledCallAnimateSheen(over view: UIView, cornerRadius: CGFloat, delay: Double, duration: Double = 0.9, alpha: CGFloat = 0.32) {
    let bounds = view.bounds
    guard !bounds.isEmpty else {
        return
    }
    let container = CALayer()
    container.frame = bounds
    container.cornerRadius = cornerRadius
    if #available(iOS 13.0, *) {
        container.cornerCurve = .continuous
    }
    container.masksToBounds = true

    let band = CAGradientLayer()
    let bandWidth = max(80.0, bounds.width * 0.45)
    band.frame = CGRect(x: -bandWidth, y: -bounds.height * 0.25, width: bandWidth, height: bounds.height * 1.5)
    band.colors = [UIColor(white: 1.0, alpha: 0.0).cgColor, UIColor(white: 1.0, alpha: alpha).cgColor, UIColor(white: 1.0, alpha: 0.0).cgColor]
    band.startPoint = CGPoint(x: 0.0, y: 0.5)
    band.endPoint = CGPoint(x: 1.0, y: 0.5)
    band.transform = CATransform3DMakeRotation(0.35, 0.0, 0.0, 1.0)
    container.addSublayer(band)
    view.layer.addSublayer(container)

    let animation = CABasicAnimation(keyPath: "position.x")
    animation.fromValue = -bandWidth
    animation.toValue = bounds.width + bandWidth
    animation.duration = duration
    animation.beginTime = band.convertTime(CACurrentMediaTime(), from: nil) + delay
    animation.fillMode = .both
    animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
    animation.isRemovedOnCompletion = false
    CATransaction.begin()
    CATransaction.setCompletionBlock({ [weak container] in
        container?.removeFromSuperlayer()
    })
    band.add(animation, forKey: "sheen")
    CATransaction.commit()
}

// MARK: - Text that can come in letter by letter

/// Text laid out with Core Text, so that every letter's place is known and the letters can rise in one after another.
public final class ScheduledCallTextView: UIView {
    private struct Glyph {
        let rect: CGRect
        let isSpace: Bool
    }

    private let contentLayer = CALayer()
    private var image: UIImage?
    private var glyphs: [Glyph] = []
    private var currentText: NSAttributedString?
    private var currentWidth: CGFloat = 0.0
    private var currentLines: Int = 0
    private(set) var textSize: CGSize = .zero

    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.layer.addSublayer(self.contentLayer)
        self.contentLayer.contentsScale = UIScreenScale
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Lays the text out within `width`, at most `maxLines` lines (the last one ends with "…"), and returns its size.
    @discardableResult
    public func update(text: NSAttributedString, width: CGFloat, maxLines: Int, alignment: NSTextAlignment = .left) -> CGSize {
        if let currentText = self.currentText, currentText.isEqual(to: text), self.currentWidth == width, self.currentLines == maxLines {
            return self.textSize
        }
        self.currentText = text
        self.currentWidth = width
        self.currentLines = maxLines

        let (placed, size) = scheduledCallPlaceLines(text: text, width: width, maxLines: maxLines)
        self.textSize = size

        var glyphs: [Glyph] = []
        let string = text.string as NSString
        let renderWidth = max(size.width, 1.0)
        let image = generateImage(CGSize(width: renderWidth, height: max(size.height, 1.0)), rotatedContext: { contextSize, context in
            context.clear(CGRect(origin: CGPoint(), size: contextSize))
            context.textMatrix = .identity
            context.translateBy(x: 0.0, y: contextSize.height)
            context.scaleBy(x: 1.0, y: -1.0)
            for line in placed {
                var x: CGFloat = 0.0
                switch alignment {
                case .center:
                    x = floor((renderWidth - line.width) * 0.5)
                case .right:
                    x = renderWidth - line.width
                default:
                    x = 0.0
                }
                context.textPosition = CGPoint(x: x, y: contextSize.height - line.origin.y)
                CTLineDraw(line.line, context)

                // Every composed character of the line, in the view's coordinates.
                var index = line.range.location
                let end = line.range.location + line.range.length
                let top = line.origin.y - line.ascent
                var coveredWidth: CGFloat = 0.0
                while index < end {
                    let range = string.rangeOfComposedCharacterSequence(at: index)
                    index = range.location + range.length
                    let start = CTLineGetOffsetForStringIndex(line.line, range.location, nil)
                    let next = CTLineGetOffsetForStringIndex(line.line, range.location + range.length, nil)
                    // A truncated line ends early: the letters past its end are not drawn.
                    if min(start, next) < coveredWidth - 0.5 || max(start, next) > line.width + 0.5 || next == start {
                        continue
                    }
                    coveredWidth = max(start, next)
                    let rect = CGRect(x: x + min(start, next) - 1.0, y: top - 2.0, width: abs(next - start) + 2.0, height: line.ascent + line.descent + 4.0)
                    let character = string.substring(with: range)
                    glyphs.append(Glyph(rect: rect, isSpace: character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
                if line.width > coveredWidth + 1.0 {
                    // The ellipsis of a truncated line.
                    glyphs.append(Glyph(rect: CGRect(x: x + coveredWidth - 1.0, y: top - 2.0, width: line.width - coveredWidth + 2.0, height: line.ascent + line.descent + 4.0), isSpace: false))
                }
            }
        })
        self.image = image
        self.glyphs = glyphs
        self.contentLayer.contents = image?.cgImage
        self.contentLayer.frame = CGRect(origin: CGPoint(), size: CGSize(width: renderWidth, height: size.height))
        return size
    }

    /// The letters come in one after another: each rises, out of a blur. Returns how long it takes.
    @discardableResult
    public func animateLettersIn(delay: Double, stagger: Double = 0.018, offset: CGFloat = 9.0) -> Double {
        guard let image = self.image?.cgImage, !self.glyphs.isEmpty else {
            return 0.0
        }
        let scale = CGFloat(image.width) / max(1.0, self.contentLayer.bounds.width)
        let glyphLayers = CALayer()
        glyphLayers.frame = self.contentLayer.frame
        // At once: an implicit fade of the whole text would show over the letters coming in.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layer.addSublayer(glyphLayers)
        self.contentLayer.opacity = 0.0
        CATransaction.commit()

        var visibleIndex = 0
        for glyph in self.glyphs where !glyph.isSpace {
            let cropRect = CGRect(x: glyph.rect.minX * scale, y: glyph.rect.minY * scale, width: glyph.rect.width * scale, height: glyph.rect.height * scale).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !cropRect.isEmpty, let cropped = image.cropping(to: cropRect) else {
                continue
            }
            let layer = CALayer()
            layer.contents = cropped
            layer.contentsScale = scale
            layer.frame = CGRect(x: cropRect.minX / scale, y: cropRect.minY / scale, width: cropRect.width / scale, height: cropRect.height / scale)
            layer.opacity = 0.0
            glyphLayers.addSublayer(layer)

            let letterDelay = delay + Double(visibleIndex) * stagger
            layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, delay: letterDelay, removeOnCompletion: false)
            layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: 0.0, y: offset)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.55, delay: letterDelay, damping: 70.0, additive: true)
            layer.animateSpring(from: 1.3 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.55, delay: letterDelay, damping: 70.0)
            scheduledCallAnimateBlurIn(layer, radius: 5.0, duration: 0.3, delay: letterDelay)
            visibleIndex += 1
        }
        let total = delay + Double(max(0, visibleIndex - 1)) * stagger + 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + total, execute: { [weak self, weak glyphLayers] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.contentLayer.opacity = 1.0
            glyphLayers?.removeFromSuperlayer()
            CATransaction.commit()
        })
        return total
    }

    /// The size `update` would give the text, measured on any thread.
    public static func measure(text: NSAttributedString, width: CGFloat, maxLines: Int) -> CGSize {
        return scheduledCallPlaceLines(text: text, width: width, maxLines: maxLines).size
    }
}

private func scheduledCallPlaceLines(text: NSAttributedString, width: CGFloat, maxLines: Int) -> (placed: [(line: CTLine, origin: CGPoint, width: CGFloat, ascent: CGFloat, descent: CGFloat, range: CFRange)], size: CGSize) {
    let lines = scheduledCallLayoutLines(text: text, width: width, maxLines: maxLines)
    var height: CGFloat = 0.0
    var maxWidth: CGFloat = 0.0
    var placed: [(line: CTLine, origin: CGPoint, width: CGFloat, ascent: CGFloat, descent: CGFloat, range: CFRange)] = []
    for line in lines {
        var ascent: CGFloat = 0.0
        var descent: CGFloat = 0.0
        var leading: CGFloat = 0.0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line.line, &ascent, &descent, &leading))
        let lineHeight = ceil(ascent + descent) + (placed.isEmpty ? 0.0 : floor(leading + 2.0))
        height += lineHeight
        placed.append((line.line, CGPoint(x: 0.0, y: height - descent), lineWidth, ascent, descent, line.range))
        maxWidth = max(maxWidth, lineWidth)
    }
    return (placed, CGSize(width: ceil(maxWidth), height: ceil(height)))
}

private func scheduledCallLayoutLines(text: NSAttributedString, width: CGFloat, maxLines: Int) -> [(line: CTLine, range: CFRange)] {
    let typesetter = CTTypesetterCreateWithAttributedString(text as CFAttributedString)
    let length = text.length
    var result: [(line: CTLine, range: CFRange)] = []
    var start = 0
    while start < length {
        let isLast = maxLines > 0 && result.count == maxLines - 1
        var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
        if count <= 0 {
            count = length - start
        }
        // A hard line break ends the line without being drawn.
        let substring = (text.string as NSString).substring(with: NSRange(location: start, length: count))
        var drawnCount = count
        if substring.hasSuffix("\n") {
            drawnCount -= 1
        }
        if isLast && start + count < length {
            let rest = text.attributedSubstring(from: NSRange(location: start, length: length - start))
            let restLine = CTLineCreateWithAttributedString(rest as CFAttributedString)
            let ellipsisAttributes = rest.length > 0 ? rest.attributes(at: 0, effectiveRange: nil) : [:]
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: ellipsisAttributes) as CFAttributedString)
            let truncated = CTLineCreateTruncatedLine(restLine, Double(width), .end, token) ?? restLine
            result.append((truncated, CFRange(location: start, length: length - start)))
            break
        }
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: drawnCount))
        result.append((line, CFRange(location: start, length: drawnCount)))
        start += count
        if maxLines > 0 && result.count >= maxLines {
            break
        }
    }
    return result
}
