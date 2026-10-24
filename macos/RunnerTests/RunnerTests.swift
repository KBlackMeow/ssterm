import Cocoa
import FlutterMacOS
import XCTest
@testable import SSTerm

class RunnerTests: XCTestCase {

  func testStartupWallpaperAlreadyHasTheTerminalBackgroundShade() throws {
    let image = NSImage(size: NSSize(width: 20, height: 20))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 20, height: 20).fill()
    image.unlockFocus()
    let view = StartupWallpaperView(image: image, settings: [
      "wallpaperOpacity": 1.0, "wallpaperBlur": 0.0,
      "backgroundOpacity": 0.5, "themePreset": "vscodeDark",
    ])
    view.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    view.draw(view.bounds)
    let color = try XCTUnwrap(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
    // Flutter's final surface: white wallpaper + 50% #1E1E1E = #8F8F8F.
    XCTAssertEqual(color.redComponent, 143.0 / 255.0, accuracy: 0.02)
  }

  func testStartupWallpaperIsBelowTheTerminalView() {
    let terminal = NSViewController()
    terminal.view = NSView()
    let wallpaper = NSView()
    let content = TerminalContentViewController(terminal: terminal, wallpaper: wallpaper)

    XCTAssertTrue(content.view.subviews.first === wallpaper)
    XCTAssertTrue(content.view.subviews.last === terminal.view)
    XCTAssertTrue(terminal.parent === content)
  }

  func testStartupWallpaperCoversTheViewWithoutBlackBars() throws {
    let image = NSImage(size: NSSize(width: 300, height: 100))
    image.lockFocus()
    NSColor.blue.setFill()
    NSRect(x: 0, y: 0, width: 300, height: 100).fill()
    NSColor.red.setFill()
    NSRect(x: 100, y: 0, width: 100, height: 100).fill()
    image.unlockFocus()
    let view = StartupWallpaperView(image: image, settings: [
      "wallpaperOpacity": 1.0, "wallpaperBlur": 0.0, "backgroundOpacity": 0.0,
    ])
    view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    view.draw(view.bounds)
    for x in [5, 50, 95] {
      let color = try XCTUnwrap(bitmap.colorAt(x: x, y: 50)?.usingColorSpace(.deviceRGB))
      XCTAssertGreaterThan(color.redComponent, 0.9)
      XCTAssertLessThan(color.blueComponent, 0.1)
    }
    XCTAssertNil(view.hitTest(NSPoint(x: 50, y: 50)))
  }

  func testDisabledOrBrokenStartupWallpaperUsesTheNormalWindow() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let wallpapers = directory.appendingPathComponent("wallpapers")
    try FileManager.default.createDirectory(at: wallpapers, withIntermediateDirectories: true)
    try Data("invalid image".utf8).write(to: wallpapers.appendingPathComponent("broken.png"))
    for enabled in [false, true] {
      let config: [String: Any] = ["terminal": [
        "wallpaperId": "broken.png", "wallpaperEnabled": enabled,
      ]]
      try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("config.json"))
      XCTAssertNil(StartupWallpaperView.loadSavedWallpaper(from: directory))
    }
  }
}
