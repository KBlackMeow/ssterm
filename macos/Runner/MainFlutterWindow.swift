import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // 4:3 content area (960×720)
  private static let defaultContentSize = NSSize(width: 960, height: 720)

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.appearance = NSAppearance(named: .vibrantDark)
    setContentSize(Self.defaultContentSize)
    center()

    minSize = frameRect(
      forContentRect: NSRect(origin: .zero, size: NSSize(width: 640, height: 480))
    ).size

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

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

    disableDesktopDropOverlay(in: flutterViewController.view)

    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  override func sendEvent(_ event: NSEvent) {
    #if DEBUG
    if event.type == .leftMouseDown || event.type == .leftMouseUp {
      logMouseEvent(event)
    }
    #endif
    super.sendEvent(event)
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

  // MARK: - Drop overlay

  private func disableDesktopDropOverlay(in rootView: NSView) {
    for subview in rootView.subviews {
      disableDesktopDropOverlay(in: subview)
      if NSStringFromClass(type(of: subview)).contains("desktop_drop.DropTarget") {
        subview.removeFromSuperview()
      }
    }
  }

  #if DEBUG
  private func logMouseEvent(_ event: NSEvent) {
    let point = event.locationInWindow
    let titleBarHeight = frame.height - contentRect(forFrameRect: frame).height
    let yFromTop = frame.height - point.y
    let inTitleBarBand = yFromTop <= titleBarHeight + 6

    let contentHit = contentView.flatMap {
      $0.hitTest($0.convert(point, from: nil))
    }

    let closeButton = standardWindowButton(.closeButton)
    let buttonContainer = closeButton?.superview
    let titleBarView = buttonContainer?.superview
    let titleBarContainer = titleBarView?.superview

    let titleBarHit = titleBarView.flatMap { view -> NSView? in
      let local = view.convert(point, from: nil)
      return view.bounds.contains(local) ? view.hitTest(local) : nil
    }

    let titleBarContainerHit = titleBarContainer.flatMap { view -> NSView? in
      let local = view.convert(point, from: nil)
      return view.bounds.contains(local) ? view.hitTest(local) : nil
    }

    Swift.print(
      """
      [ssterm][macos] \(event.type == .leftMouseDown ? "down" : "up") \
      ts=\(String(format: "%.4f", event.timestamp)) \
      clickCount=\(event.clickCount) \
      point=(\(Int(point.x)),\(Int(point.y))) \
      yFromTop=\(String(format: "%.1f", yFromTop)) \
      titleBarHeight=\(String(format: "%.1f", titleBarHeight)) \
      inTitleBarBand=\(inTitleBarBand) \
      contentHit=\(debugViewName(contentHit)) \
      titleBarHit=\(debugViewName(titleBarHit)) \
      titleBarContainerHit=\(debugViewName(titleBarContainerHit))
      """
    )
  }

  private func debugViewName(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    return "\(NSStringFromClass(type(of: view)))#\(Unmanaged.passUnretained(view).toOpaque())"
  }
  #endif
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
