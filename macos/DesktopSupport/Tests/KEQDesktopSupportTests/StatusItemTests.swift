import AppKit
import XCTest
@testable import KEQDesktopSupport

final class StatusItemTests: XCTestCase {
    private func arguments(status: String = "connected", showSpeed: Bool = true) -> [String: Any] {
        ["status": status, "statusText": "已连接", "showSpeed": showSpeed,
         "uploadText": "12 MB/s", "downloadText": "— KB/s",
         "uploadLabel": "上传", "downloadLabel": "下载"]
    }

    func testAcceptsExistingStatesAndKeepsLocalizedAccessibleRates() throws {
        for status in StatusItemPresentation.Status.allCases {
            let value = try StatusItemPresentation(arguments: arguments(status: status.rawValue))
            XCTAssertEqual(value.status, status)
            XCTAssertEqual(value.accessibilityText, "KEQDIS — 已连接\n上传: 12 MB/s\n下载: — KB/s")
        }
        let iconOnly = try StatusItemPresentation(arguments: arguments(showSpeed: false))
        XCTAssertEqual(iconOnly.accessibilityText, "KEQDIS — 已连接")
    }

    func testRejectsMalformedUpdatesInsteadOfPartiallyApplyingThem() {
        let mutations: [(String, Any)] = [
            ("status", "running"), ("status", 1), ("showSpeed", 1), ("showSpeed", "true"),
            ("statusText", ""), ("statusText", String(repeating: "a", count: 161)),
            ("uploadText", "12\nMB/s"), ("downloadText", "12\tMB/s"),
            ("uploadText", String(repeating: "9", count: 13)),
            ("downloadLabel", String(repeating: "x", count: 33)), ("uploadLabel", false),
        ]
        for (key, value) in mutations {
            var input = arguments()
            input[key] = value
            XCTAssertThrowsError(try StatusItemPresentation(arguments: input), "\(key): \(value)")
        }
        for key in arguments().keys {
            var input = arguments()
            input.removeValue(forKey: key)
            XCTAssertThrowsError(try StatusItemPresentation(arguments: input), key)
        }
    }

    func testTemplateSizeDoesNotDependOnStateOrRateLength() throws {
        for status in StatusItemPresentation.Status.allCases {
            for speed in [false, true] {
                var input = arguments(status: status.rawValue, showSpeed: speed)
                for rate in ["— KB/s", "0 KB/s", "9999 MB/s"] {
                    input["uploadText"] = rate
                    let value = try StatusItemPresentation(arguments: input)
                    let image = StatusItemRenderer.image(for: value)
                    XCTAssertTrue(image.isTemplate)
                    XCTAssertEqual(image.size, NSSize(width: speed ? 87 : 18, height: 18))
                    XCTAssertEqual(image.accessibilityDescription, value.accessibilityText)
                }
            }
        }
    }

    func testPersianAndJoinedEmojiRemainValidWithoutAcceptingLineBreaks() throws {
        var input = arguments()
        input["statusText"] = "اشتراک‌ها 👩‍💻"
        let value = try StatusItemPresentation(arguments: input)
        XCTAssertEqual(value.statusText, "اشتراک‌ها 👩‍💻")
        for scalar in ["\u{0000}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            input["statusText"] = "before\(scalar)after"
            XCTAssertThrowsError(try StatusItemPresentation(arguments: input))
        }
    }

    func testLargestFormattedRatesFitWithoutClipping() {
        let attributes: [NSAttributedString.Key: Any] = [.font: StatusItemRenderer.rateFont]
        for text in ["— KB/s", "0 KB/s", "1023 KB/s", "9999 MB/s", ">9999 MB/s"] {
            XCTAssertLessThanOrEqual((text as NSString).size(withAttributes: attributes).width,
                StatusItemRenderer.rateTextWidth, text)
        }
    }

    func testRasterHasDistinctStateMarkersAtOneAndTwoTimesScale() throws {
        for scale in [1, 2] {
            let disconnected = try raster("disconnected", scale: scale)
            let connected = try raster("connected", scale: scale)
            let connecting = try raster("connecting", scale: scale)
            let disconnecting = try raster("disconnecting", scale: scale)
            let error = try raster("error", scale: scale)
            XCTAssertNotEqual(disconnected, connected)
            XCTAssertNotEqual(connected, connecting)
            XCTAssertNotEqual(connecting, error)
            XCTAssertNotEqual(disconnected, error)
            // Both transition states use static dots; the accessible text distinguishes them.
            XCTAssertEqual(connecting, disconnecting)
        }
    }

    private func raster(_ state: String, scale: Int) throws -> Data {
        let value = try StatusItemPresentation(arguments: arguments(status: state, showSpeed: false))
        let image = StatusItemRenderer.image(for: value)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 18 * scale,
            pixelsHigh: 18 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
