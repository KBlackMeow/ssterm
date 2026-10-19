import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // 4:3 content area (960×720)
  private static let defaultContentSize = NSSize(width: 960, height: 720)

  override func awakeFromNib() {
    // AppKit can show the nib window again after awakeFromNib. Keep it
    // transparent while Flutter renders its first wallpaper-backed frame.
    setIsVisible(false)
    alphaValue = 0
    ignoresMouseEvents = true
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
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
    if styleMask.contains(.fullScreen) {
      // The first frame still controls when the startup window is revealed.
      alphaValue = 0
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
