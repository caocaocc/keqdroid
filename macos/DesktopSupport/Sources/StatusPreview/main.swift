import AppKit
import KEQDesktopSupport

// Offline renderer: this does not initialize NSApplication, install a menu bar
// item, read user settings, or communicate with the network service.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: keqdis-status-preview OUTPUT_DIRECTORY\n", stderr)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let width = 650
let height = 248
let states = StatusItemPresentation.Status.allCases
let titles = ["Disconnected", "Connecting", "Connected", "Disconnecting", "Error"]

for dark in [false, true] {
    for scale in [1, 2] {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale,
            pixelsHigh: height * scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: width, height: height)
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let background = dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.95, alpha: 1)
        let foreground = dark ? NSColor.white : NSColor.black
        background.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: foreground]
        let heading = "KEQDIS · menu bar · \(dark ? "dark" : "light") · \(scale)× · rendered at actual point size"
        (heading as NSString).draw(at: NSPoint(x: 18, y: 223), withAttributes: label)
        for (index, state) in states.enumerated() {
            let x = CGFloat(18 + index * 128)
            (titles[index] as NSString).draw(at: NSPoint(x: x, y: 194), withAttributes: label)
            for sample in 0..<4 {
                let values = [(false, "— KB/s", "— KB/s"), (true, "— KB/s", "— KB/s"),
                              (true, "0 KB/s", "12 MB/s"), (true, "1023 KB/s", "9999 MB/s")][sample]
                let presentation = try StatusItemPresentation(arguments: [
                    "status": state.rawValue, "statusText": titles[index],
                    "showSpeed": values.0, "uploadText": values.1, "downloadText": values.2,
                    "uploadLabel": "Upload", "downloadLabel": "Download",
                ])
                NSGraphicsContext.saveGraphicsState()
                let placement = NSAffineTransform()
                placement.translateX(by: x + 5, yBy: CGFloat(158 - sample * 38))
                placement.concat()
                StatusItemRenderer.draw(presentation, color: foreground)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let file = output.appendingPathComponent("menu-bar-\(dark ? "dark" : "light")-\(scale)x.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
        print(file.path)
    }
}
