import Cocoa
import CoreImage
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // 4:3 content area (960×720)
  private static let defaultContentSize = NSSize(width: 960, height: 720)
  private var startupWallpaper: StartupWallpaperView?
  private var startupAppearanceChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    // AppKit displays the saved wallpaper before Flutter's first frame.
    // Neither window visibility nor this backdrop waits for the login shell.
    let wallpaper = StartupWallpaperView.loadSavedWallpaper()
    backgroundColor = NSColor(calibratedWhite: 30.0 / 255.0, alpha: 1)
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = wallpaper == nil ? backgroundColor : .clear
    self.contentViewController = TerminalContentViewController(
      terminal: flutterViewController, wallpaper: wallpaper
    )
    startupWallpaper = wallpaper
    self.appearance = NSAppearance(named: .vibrantDark)
    // Give the native window its final frame before AppKit makes the nib
    // window visible. Dart applies the same title-bar style and size later.
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    styleMask.insert(.fullSizeContentView)
    setContentSize(Self.defaultContentSize)
    let cursor = NSEvent.mouseLocation
    let display = NSScreen.screens.first { $0.frame.contains(cursor) }
      ?? NSScreen.screens.first
    if let area = display?.visibleFrame {
      setFrameOrigin(NSPoint(
        x: area.midX - frame.width / 2,
        y: area.midY - frame.height / 2
      ))
    }

    minSize = frameRect(
      forContentRect: NSRect(origin: .zero, size: NSSize(width: 640, height: 480))
    ).size

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    // Rapid terminal output stutters in macOS system full screen while the
    // system title bar is hidden. Revealing the title bar or a notification
    // makes the same output smooth without changing Flutter frame timings.
    // A nearly opaque window keeps the smooth full-screen presentation path
    // even after the system overlay disappears.
    NotificationCenter.default.addObserver(
      forName: NSWindow.didEnterFullScreenNotification,
      object: self,
      queue: .main
    ) { [weak self] _ in
      if let self = self, self.alphaValue > 0 {
        self.alphaValue = 0.999
      }
    }
    NotificationCenter.default.addObserver(
      forName: NSWindow.didExitFullScreenNotification,
      object: self,
      queue: .main
    ) { [weak self] _ in
      if let self = self, self.alphaValue > 0 {
        self.alphaValue = 1
      }
    }

    // With TitleBarStyle.hidden the Flutter view fills the entire window
    // (including the title bar region), but NSWindow still delays mouse-up
    // events in that region while it decides whether the user is
    // clicking, double-clicking (to zoom), or starting a drag.
    //
    // NSWindow asks NSView.mouseDownCanMoveWindow to decide. Swizzling the
    // getter to always return false prevents the tracking loop from ever
    // starting, so every mouse-up arrives immediately — matching the
    // fullscreen behaviour where no title bar exists at all.
    //
    // Window dragging is handled explicitly by Flutter via
    // windowManager.startDragging(), which calls performDrag(with:)
    // directly and doesn't go through mouseDownCanMoveWindow.
    swizzleMouseDownCanMoveWindow()

    // The desktop_drop plugin adds a full-window DropTarget NSView to
    // receive file drags, but that view sits on top of the Flutter view
    // and intercepts mouse events — breaking title-bar click handling
    // above.  Remove the view-level overlay…
    removeDesktopDropOverlay(in: flutterViewController.view)

    // …and instead handle file drags at the NSWindow level, which
    // AppKit only consults when no view in the hierarchy accepts the
    // drag.  NSWindow does not participate in hitTest, so mouse events
    // are unaffected.
    setupDesktopDrop(for: flutterViewController)
    startupAppearanceChannel = FlutterMethodChannel(
      name: "ssterm/startup_appearance",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    startupAppearanceChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "ready" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // Only the background is replaced. Flutter's controls are already visible.
      self?.startupWallpaper?.removeFromSuperview()
      self?.startupWallpaper = nil
      result(nil)
    }
    makeKeyAndOrderFront(nil)
  }

  // MARK: - Swizzle mouseDownCanMoveWindow

  private func swizzleMouseDownCanMoveWindow() {
    let original = #selector(getter: NSView.mouseDownCanMoveWindow)
    let swizzled = #selector(NSView._ssterm_mouseDownCanMoveWindow)
    guard
      let m1 = class_getInstanceMethod(NSView.self, original),
      let m2 = class_getInstanceMethod(NSView.self, swizzled)
    else {
      print("[ssterm] WARNING: mouseDownCanMoveWindow swizzle failed")
      return
    }
    method_exchangeImplementations(m1, m2)
  }

  // MARK: - Drop overlay — remove the view-level handler

  /// The `desktop_drop` plugin registers a full-window DropTarget NSView
  /// that receives drag events via NSDraggingDestination.  While convenient,
  /// it sits on top of the Flutter view and intercepts *all* mouse events
  /// (hitTest returns self for a plain NSView), which breaks title-bar
  /// click handling.  Remove it — drags are handled at the NSWindow level
  /// instead (see `setupDesktopDrop`).
  private func removeDesktopDropOverlay(in rootView: NSView) {
    for subview in rootView.subviews {
      removeDesktopDropOverlay(in: subview)
      if NSStringFromClass(type(of: subview)).contains("desktop_drop.DropTarget") {
        subview.removeFromSuperview()
      }
    }
  }

  // MARK: - Window-level drag destination

  private var desktopDropChannel: FlutterMethodChannel?

  private lazy var dropDestinationURL: URL = {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("Drops")
    try? FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true)
    return url
  }()

  private lazy var dropWorkQueue: OperationQueue = {
    let q = OperationQueue()
    q.qualityOfService = .userInitiated
    return q
  }()

  private func setupDesktopDrop(for vc: FlutterViewController) {
    desktopDropChannel = FlutterMethodChannel(
      name: "desktop_drop",
      binaryMessenger: vc.engine.binaryMessenger
    )
    registerForDraggedTypes(
      NSFilePromiseReceiver.readableDraggedTypes.map {
        NSPasteboard.PasteboardType($0)
      }
      + [NSPasteboard.PasteboardType.fileURL]
    )
  }

  // MARK: NSDraggingDestination (window-level)

  @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    desktopDropChannel?.invokeMethod(
      "entered", arguments: flippedPoint(for: sender))
    return .copy
  }

  @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    desktopDropChannel?.invokeMethod(
      "updated", arguments: flippedPoint(for: sender))
    return .copy
  }

  @objc func draggingExited(_ sender: NSDraggingInfo?) {
    desktopDropChannel?.invokeMethod("exited", arguments: nil)
  }

  @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    var urls = [String]()
    let searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
    ]
    let group = DispatchGroup()

    sender.enumerateDraggingItems(
      options: [], for: nil,
      classes: [NSFilePromiseReceiver.self, NSURL.self],
      searchOptions: searchOptions
    ) { draggingItem, _, _ in
      switch draggingItem.item {
      case let filePromiseReceiver as NSFilePromiseReceiver:
        group.enter()
        filePromiseReceiver.receivePromisedFiles(
          atDestination: self.dropDestinationURL,
          options: [:],
          operationQueue: self.dropWorkQueue
        ) { fileURL, error in
          if let error = error {
            debugPrint("desktop_drop file promise error: \(error)")
          } else {
            urls.append(fileURL.path)
          }
          group.leave()
        }
      case let fileURL as URL:
        urls.append(fileURL.path)
      default:
        break
      }
    }

    group.notify(queue: .main) {
      self.desktopDropChannel?.invokeMethod(
        "performOperation", arguments: urls)
    }
    return true
  }

  /// Convert `sender.draggingLocation` (window coords, y=0 at bottom)
  /// to Flutter coords (y=0 at top).
  private func flippedPoint(for sender: NSDraggingInfo) -> [CGFloat] {
    let p = sender.draggingLocation
    let h = contentView?.bounds.height ?? 0
    return [p.x, h - p.y]
  }

}

/// Keep the startup image below the Flutter surface so it never masks controls.
final class TerminalContentViewController: NSViewController {
  init(terminal: NSViewController, wallpaper: NSView?) {
    super.init(nibName: nil, bundle: nil)
    view = NSView()
    addChild(terminal)
    if let wallpaper = wallpaper {
      wallpaper.frame = view.bounds
      wallpaper.autoresizingMask = [.width, .height]
      view.addSubview(wallpaper)
    }
    terminal.view.frame = view.bounds
    terminal.view.autoresizingMask = [.width, .height]
    view.addSubview(terminal.view)
  }

  required init?(coder: NSCoder) { return nil }
}

/// An AppKit view of the original wallpaper, used only during engine startup.
/// It passes input through and is removed once Flutter has painted that image.
final class StartupWallpaperView: NSView {
  private let image: NSImage
  private let opacity: CGFloat
  private let blur: CGFloat
  private let backgroundOpacity: CGFloat
  private let surfaceColor: NSColor
  private var renderedImage: NSImage?
  private var renderedSize = NSSize.zero
  private let background = NSColor(calibratedWhite: 30.0 / 255.0, alpha: 1)

  private static var appDataDirectory: URL {
    let home = ProcessInfo.processInfo.environment["HOME"]
    return URL(fileURLWithPath: home?.isEmpty == false ? home! : NSHomeDirectory())
      .appendingPathComponent(".ssterm", isDirectory: true)
  }

  static func loadSavedWallpaper(from directory: URL? = nil) -> StartupWallpaperView? {
    let base = directory ?? appDataDirectory
    guard
      let data = try? Data(contentsOf: base.appendingPathComponent("config.json")),
      let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let settings = config["terminal"] as? [String: Any],
      let id = settings["wallpaperId"] as? String, !id.isEmpty,
      (settings["wallpaperEnabled"] as? Bool ?? true),
      let image = NSImage(contentsOf: base.appendingPathComponent("wallpapers")
        .appendingPathComponent(id)),
      image.isValid
    else { return nil }
    return StartupWallpaperView(image: image, settings: settings)
  }

  init(image: NSImage, settings: [String: Any]) {
    self.image = image
    opacity = CGFloat(min(1, max(0, settings["wallpaperOpacity"] as? Double ?? 1)))
    blur = CGFloat(min(64, max(0, settings["wallpaperBlur"] as? Double ?? 12)))
    backgroundOpacity = CGFloat(min(1, max(0, settings["backgroundOpacity"] as? Double ?? 0.88)))
    // Match the background colors in TerminalThemePresets, including custom
    // themes, so the first native image has the final terminal brightness.
    let presets: [String: UInt32] = [
      "vscodeDark": 0x1E1E1E, "vscodeLight": 0xFFFFFF,
      "campbell": 0x0C0C0C, "campbellPowershell": 0x012456,
      "macTerminalBasic": 0xFFFFFF, "macTerminalPro": 0x000000,
      "iterm2Default": 0x000000, "ubuntu": 0x300A24, "gnomeTango": 0x2E3436,
    ]
    var rgb = presets[settings["themePreset"] as? String ?? "vscodeDark"] ?? 0x1E1E1E
    if settings["themePreset"] as? String == "custom",
      let custom = settings["customTheme"] as? [String: Any],
      let hex = custom["background"] as? String,
      let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16)
    { rgb = value & 0xFFFFFF }
    surfaceColor = NSColor(
      srgbRed: CGFloat((rgb >> 16) & 255) / 255,
      green: CGFloat((rgb >> 8) & 255) / 255,
      blue: CGFloat(rgb & 255) / 255, alpha: 1
    )
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { return nil }

  override var isOpaque: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    background.setFill()
    bounds.fill()
    guard bounds.width > 0, bounds.height > 0 else { return }

    if renderedSize != bounds.size {
      renderedSize = bounds.size
      renderedImage = makeRenderedImage()
    }
    (renderedImage ?? image).draw(
      in: bounds, from: .zero, operation: .sourceOver, fraction: opacity,
      respectFlipped: true, hints: [.interpolation: NSImageInterpolation.medium]
    )
    surfaceColor.withAlphaComponent(backgroundOpacity).setFill()
    bounds.fill()
  }

  private func makeRenderedImage() -> NSImage? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }
    let scale = window?.backingScaleFactor ?? 1
    let target = CGRect(origin: .zero, size: NSSize(
      width: bounds.width * scale, height: bounds.height * scale
    ))
    let cover = max(target.width / CGFloat(cgImage.width), target.height / CGFloat(cgImage.height))
    var output = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(
      a: cover, b: 0, c: 0, d: cover,
      tx: (target.width - CGFloat(cgImage.width) * cover) / 2,
      ty: (target.height - CGFloat(cgImage.height) * cover) / 2
    ))
    if blur > 0 {
      output = output.clampedToExtent().applyingFilter(
        "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur * scale]
      )
    }
    guard let rendered = CIContext().createCGImage(output, from: target) else { return nil }
    return NSImage(cgImage: rendered, size: bounds.size)
  }
}

// MARK: - NSView swizzled getter

extension NSView {
  /// Swizzled replacement for `mouseDownCanMoveWindow`.
  /// Always returns `false` so NSWindow never enters its title-bar
  /// drag-tracking loop — window dragging is handled by Flutter instead.
  @objc func _ssterm_mouseDownCanMoveWindow() -> Bool {
    // This implementation is swapped with the original at runtime.
    // After swizzling, this runs when anyone calls the ORIGINAL
    // `mouseDownCanMoveWindow` getter.
    return false
  }
}
