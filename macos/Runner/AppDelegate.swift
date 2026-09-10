import Cocoa
import FlutterMacOS
import KEQDesktopSupport

@main
class AppDelegate: FlutterAppDelegate {
  var desktop: DesktopController?
  private var pendingURLs: [URL] = []
  private static let activationNotification = Notification.Name("io.github.caocaocc.keqdroid.activate")
  private var shouldShowWhenAttached = false

  override init() {
    super.init()
    DistributedNotificationCenter.default().addObserver(self, selector: #selector(receiveActivation(_:)),
      name: Self.activationNotification, object: String(getuid()), suspensionBehavior: .deliverImmediately)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let identifier = Bundle.main.bundleIdentifier {
      let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
      let primary = applications.min {
        let left = $0.launchDate ?? .distantPast
        let right = $1.launchDate ?? .distantPast
        return left == right ? $0.processIdentifier < $1.processIdentifier : left < right
      }
      if let primary, primary.processIdentifier != getpid() {
        let links = pendingURLs.map(\.absoluteString) + (desktop?.linksForForwarding ?? [])
        DistributedNotificationCenter.default().postNotificationName(Self.activationNotification,
          object: String(getuid()), userInfo: ["pid": primary.processIdentifier, "urls": links], deliverImmediately: true)
        exit(0)
      }
    }
    super.applicationDidFinishLaunching(notification)
  }

  @objc private func receiveActivation(_ notification: Notification) {
    guard (notification.userInfo?["pid"] as? NSNumber)?.int32Value == getpid() else { return }
    // Links received from another local process still use the normal import confirmation.
    let links = (notification.userInfo?["urls"] as? [String] ?? []).prefix(32)
      .filter { $0.utf8.count <= 262144 }.compactMap(URL.init(string:))
    if let desktop {
      links.forEach { desktop.enqueue(url: $0) }
      desktop.showWindow()
    } else {
      pendingURLs.append(contentsOf: links)
      shouldShowWhenAttached = true
    }
  }

  func attachDesktop(_ controller: DesktopController) {
    desktop = controller
    pendingURLs.forEach { controller.enqueue(url: $0) }
    pendingURLs.removeAll()
    if shouldShowWhenAttached { controller.showWindow(); shouldShowWhenAttached = false }
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    if let desktop { urls.forEach { desktop.enqueue(url: $0) } }
    else { pendingURLs.append(contentsOf: urls.prefix(32)) }
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    desktop?.showWindow()
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let desktop, !desktop.terminationApproved else { return .terminateNow }
    DispatchQueue.main.async { desktop.requestQuit() }
    return .terminateLater
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  deinit { DistributedNotificationCenter.default().removeObserver(self) }
}
