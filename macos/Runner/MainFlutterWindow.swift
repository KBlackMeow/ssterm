import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // 4:3 content area (960×720)
  private static let defaultContentSize = NSSize(width: 960, height: 720)

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    setContentSize(Self.defaultContentSize)
    center()

    minSize = frameRect(
      forContentRect: NSRect(origin: .zero, size: NSSize(width: 640, height: 480))
    ).size

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
