import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // 4:3 content area (1024×768)
  private static let defaultContentSize = NSSize(width: 1024, height: 768)

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    setContentSize(Self.defaultContentSize)
    center()

    minSize = frameRect(
      forContentRect: NSRect(origin: .zero, size: NSSize(width: 800, height: 600))
    ).size

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
