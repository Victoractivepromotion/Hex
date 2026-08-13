//
//  LarryHUDWindow.swift
//  Hex — "Hey Larry" command centre
//
//  Hosts the Larry HUD (a hosted HTML page) in a borderless window and reflects
//  the live voice state into it.
//
//  The page is loaded from the server rather than bundled, so the layout can be
//  changed server-side without shipping a new build. A copy is cached on disk
//  and used when the network is unavailable, so the HUD still opens offline.
//
//  The hosted page has no element IDs on its voice card, so the status is
//  driven by class selectors (`.voice .st`, `.voice .wake`, `.orb`). The
//  injected script tolerates missing elements — if the page is restyled and a
//  selector stops matching, the HUD keeps working and simply stops updating
//  that line, rather than throwing.
//

import AppKit
import HexCore
import WebKit

private let hudLog = HexLog.larryHUD

@MainActor
final class LarryHUD: NSObject, WKNavigationDelegate {
  static let shared = LarryHUD()

  /// What the voice pipeline is doing right now.
  enum VoiceState {
    case standby
    case listening
    case thinking
    case speaking
    case muted

    /// (status line, accent colour, sub-line)
    var display: (String, String, String) {
      switch self {
      case .muted:
        return ("Muted — tryk højre Option for at lytte igen", "#ff5d6c", "○ Wake-word slået fra · mikrofon frigivet")
      case .standby:
        return ("Standby — lytter efter \"Hey Larry\"", "#3fd8ff", "● Wake-word aktiv · auto-send ved stilhed")
      case .listening:
        return ("Lytter…", "#39e0a0", "● Optager · slip for at sende")
      case .thinking:
        return ("Tænker…", "#ffb454", "● Sendt til /larry/voice · venter på svar")
      case .speaking:
        return ("Larry taler", "#3fd8ff", "● Afspiller svar · tal for at afbryde")
      }
    }
  }

  private static let remote = URL(
    string: "https://shopify.activepromotion.dk/rebuilt-videos/larry-hud.html"
  )!

  private var window: NSWindow?
  private var webView: WKWebView?
  private var pendingState: VoiceState = .standby
  private var isLoaded = false

  // MARK: Window lifecycle

  func toggle() {
    if window?.isVisible == true {
      close()
    } else {
      show()
    }
  }

  func show() {
    let window = window ?? makeWindow()
    self.window = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func close() {
    window?.orderOut(nil)
  }

  private func makeWindow() -> NSWindow {
    let configuration = WKWebViewConfiguration()
    configuration.suppressesIncrementalRendering = false

    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1240, height: 820), configuration: configuration)
    webView.navigationDelegate = self
    self.webView = webView

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "LARRY // Command Center"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.backgroundColor = NSColor(red: 0.016, green: 0.027, blue: 0.051, alpha: 1)
    window.isReleasedWhenClosed = false
    window.contentView = webView
    window.center()

    load(into: webView)
    return window
  }

  // MARK: Loading

  private var cacheURL: URL? {
    guard let support = try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ) else { return nil }
    let directory = support.appendingPathComponent("Hex", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("larry-hud.html")
  }

  private func load(into webView: WKWebView) {
    isLoaded = false
    webView.load(URLRequest(url: Self.remote, cachePolicy: .reloadRevalidatingCacheData))

    // Refresh the offline copy in the background; failure is silent by design.
    Task { [weak self] in
      guard let self, let cacheURL = self.cacheURL else { return }
      do {
        let (data, response) = try await URLSession.shared.data(from: Self.remote)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { return }
        try data.write(to: cacheURL, options: .atomic)
      } catch {
        hudLog.debug("HUD cache refresh skipped: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  nonisolated func webView(_: WKWebView, didFinish _: WKNavigation!) {
    Task { @MainActor in
      self.isLoaded = true
      self.apply(self.pendingState)
    }
  }

  nonisolated func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
    Task { @MainActor in self.loadFromCache(webView, after: error) }
  }

  nonisolated func webView(
    _ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error
  ) {
    Task { @MainActor in self.loadFromCache(webView, after: error) }
  }

  private func loadFromCache(_ webView: WKWebView, after error: Error) {
    hudLog.error("HUD load failed: \(error.localizedDescription, privacy: .public)")
    guard let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) else { return }
    hudLog.info("Falling back to cached HUD")
    webView.loadFileURL(cacheURL, allowingReadAccessTo: cacheURL.deletingLastPathComponent())
  }

  // MARK: Live state

  /// Reflects the current voice state into the HUD. Safe to call when the
  /// window is closed — the state is replayed once the page finishes loading.
  func setState(_ state: VoiceState) {
    pendingState = state
    guard isLoaded else { return }
    apply(state)
  }

  private func apply(_ state: VoiceState) {
    guard let webView, window?.isVisible == true else { return }
    let (status, accent, sub) = state.display
    let script = """
    (function () {
      var status = document.querySelector('.voice .st');
      if (status) { status.textContent = \(jsString(status_: status)); }
      var wake = document.querySelector('.voice .wake');
      if (wake) { wake.textContent = \(jsString(status_: sub)); wake.style.color = \(jsString(status_: accent)); }
      var orb = document.querySelector('.orb');
      if (orb) { orb.style.boxShadow = '0 0 26px ' + \(jsString(status_: accent)); }
    })();
    """
    webView.evaluateJavaScript(script) { _, error in
      if let error {
        hudLog.debug("HUD script error: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// JSON-encodes a Swift string into a JS string literal, so quotes and
  /// non-ASCII in the status text cannot break out of the script.
  private func jsString(status_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value], options: .fragmentsAllowed),
          let array = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    // Strip the surrounding [ ] from the single-element array encoding.
    return String(array.dropFirst().dropLast())
  }
}
