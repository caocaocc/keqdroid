import AppKit
import CoreFoundation

/// Presentation only: connection ownership and traffic sampling remain in Dart.
public struct StatusItemPresentation: Equatable {
    public enum Status: String, CaseIterable {
        case disconnected, connecting, connected, disconnecting, error
    }

    public let status: Status
    public let statusText: String
    public let showSpeed: Bool
    public let uploadText: String
    public let downloadText: String
    public let uploadLabel: String
    public let downloadLabel: String

    public static let initial = StatusItemPresentation(status: .disconnected,
        statusText: "KEQDIS", showSpeed: false, uploadText: "— KB/s", downloadText: "— KB/s",
        uploadLabel: "", downloadLabel: "")

    public init(arguments: [String: Any]) throws {
        guard let rawStatus = arguments["status"] as? String,
              let status = Status(rawValue: rawStatus),
              let showSpeed = arguments["showSpeed"] as? NSNumber,
              CFGetTypeID(showSpeed) == CFBooleanGetTypeID() else {
            throw DesktopError.message("Invalid menu bar state")
        }
        self.status = status
        self.showSpeed = showSpeed.boolValue
        statusText = try Self.text(arguments, "statusText", limit: 160)
        uploadText = try Self.text(arguments, "uploadText", limit: 12)
        downloadText = try Self.text(arguments, "downloadText", limit: 12)
        uploadLabel = try Self.text(arguments, "uploadLabel", limit: 32)
        downloadLabel = try Self.text(arguments, "downloadLabel", limit: 32)
    }

    private init(status: Status, statusText: String, showSpeed: Bool, uploadText: String,
                 downloadText: String, uploadLabel: String, downloadLabel: String) {
        self.status = status
        self.statusText = statusText
        self.showSpeed = showSpeed
        self.uploadText = uploadText
        self.downloadText = downloadText
        self.uploadLabel = uploadLabel
        self.downloadLabel = downloadLabel
    }

    private static func text(_ arguments: [String: Any], _ key: String, limit: Int) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty,
              value.utf8.count <= limit * 4, value.count <= limit,
              value.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && !(0x7f...0x9f).contains($0.value) &&
                  $0.value != 0x2028 && $0.value != 0x2029
              }) else { throw DesktopError.message("Invalid menu bar text: \(key)") }
        return value
    }

    public var accessibilityText: String {
        let title = statusText == "KEQDIS" ? statusText : "KEQDIS — \(statusText)"
        guard showSpeed else { return title }
        return "\(title)\n\(uploadLabel): \(uploadText)\n\(downloadLabel): \(downloadText)"
    }
}

public enum StatusItemRenderer {
    public static let iconSize: CGFloat = 18
    public static let speedImageWidth: CGFloat = 87
    public static let speedItemLength: CGFloat = 95
    public static let rateNumberWidth: CGFloat = 30
    public static let rateUnitWidth: CGFloat = 24
    public static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
    public static let rateUnitFont = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .medium)

    public static func size(showSpeed: Bool) -> NSSize {
        NSSize(width: showSpeed ? speedImageWidth : iconSize, height: iconSize)
    }

    public static func image(for presentation: StatusItemPresentation) -> NSImage {
        let image = NSImage(size: size(showSpeed: presentation.showSpeed), flipped: false) { _ in
            draw(presentation, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = presentation.accessibilityText
        return image
    }

    /// Shared by the template image and the offline preview; no status item is created.
    public static func draw(_ presentation: StatusItemPresentation, color: NSColor) {
        color.setStroke()
        color.setFill()
        let ring = NSBezierPath()
        ring.lineWidth = 1.65
        ring.lineCapStyle = .round
        ring.lineJoinStyle = .round
        appendArc(to: ring, from: 148, through: 436)
        appendArc(to: ring, from: 103, through: 128)
        ring.stroke()

        switch presentation.status {
        case .disconnected:
            let center = NSBezierPath(ovalIn: NSRect(x: 6.75, y: 6.75, width: 4.5, height: 4.5))
            center.lineWidth = 1.25
            center.stroke()
        case .connected:
            NSBezierPath(ovalIn: NSRect(x: 6.65, y: 6.65, width: 4.7, height: 4.7)).fill()
        case .connecting, .disconnecting:
            for x: CGFloat in [5.7, 9, 12.3] {
                NSBezierPath(ovalIn: NSRect(x: x - 0.75, y: 8.25, width: 1.5, height: 1.5)).fill()
            }
        case .error:
            let mark = NSBezierPath()
            mark.lineWidth = 1.4
            mark.lineCapStyle = .round
            mark.move(to: NSPoint(x: 9, y: 8.9))
            mark.line(to: NSPoint(x: 9, y: 12))
            mark.stroke()
            NSBezierPath(ovalIn: NSRect(x: 8.25, y: 5.8, width: 1.5, height: 1.5)).fill()
        }

        guard presentation.showSpeed else { return }
        drawRate(presentation.uploadText, arrow: "↑", y: 9, color: color)
        drawRate(presentation.downloadText, arrow: "↓", y: 0, color: color)
    }

    private static func appendArc(to path: NSBezierPath, from start: Int, through end: Int) {
        for degree in stride(from: start, through: end, by: 2) {
            let angle = CGFloat(degree) * .pi / 180
            let radius = 6.95 + 0.55 * cos(7 * angle + .pi / 5)
            let point = NSPoint(x: 9 + radius * cos(angle), y: 9 + radius * sin(angle))
            if degree == start { path.move(to: point) } else { path.line(to: point) }
        }
    }

    public static func rateColumns(_ value: String) -> (number: String, unit: String, numberX: CGFloat, unitX: CGFloat) {
        let split = value.lastIndex(of: " ")
        let number = split.map { String(value[..<$0]) } ?? value
        let unit = split.map { String(value[value.index(after: $0)...]) } ?? ""
        let width = (number as NSString).size(withAttributes: [.font: rateFont]).width
        return (number, unit, 31 + rateNumberWidth - width, 63)
    }

    private static func drawRate(_ value: String, arrow: String, y: CGFloat, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: rateFont, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        let columns = rateColumns(value)
        (arrow as NSString).draw(at: NSPoint(x: 22, y: y - 0.4), withAttributes: attributes)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 31, y: y, width: rateNumberWidth, height: 9)).addClip()
        (columns.number as NSString).draw(at: NSPoint(x: columns.numberX, y: y - 0.4), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        var unitAttributes = attributes
        unitAttributes[.font] = rateUnitFont
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: columns.unitX, y: y, width: rateUnitWidth, height: 9)).addClip()
        (columns.unit as NSString).draw(at: NSPoint(x: columns.unitX, y: y - 0.4), withAttributes: unitAttributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}
