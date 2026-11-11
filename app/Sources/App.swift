// Homeword: a menu bar app that brings next-word suggestions and proofreading to every text field, on top of the local engine
// (the policies' HTTP server and predictd, Apple's on-device model): your words never leave the Mac. No Dock icon; its only window
// is Settings.
import AppKit
import SwiftUI

@main
struct HomewordApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private let tap = KeyTap()
    private let predictor = Predictor()
    private let proofreader = Proofreader()
    private var settings: NSWindow?
    private let nav = SettingsNav()
    private var tapRunning = false, axTrusted = false, askedListen = false
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        Pref.migrate()
        Bundled.prepare()
        Pref.register()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "house", accessibilityDescription: nil)
        icon?.isTemplate = true                                 // black on transparent: macOS tints it for the menu bar
        icon?.accessibilityDescription = "Homeword"
        status.button?.image = icon
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu

        tap.onKey = { [weak self] k in self?.key(k) ?? .pass }
        tap.onMouseDown = { [weak self] in self?.predictor.mouseDown() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.predictor.appChanged(pid: app.processIdentifier, bundle: app.bundleIdentifier ?? "")
        }
        Services.shared.onChange = { [weak self] in self?.updateIcon() }
        Services.shared.check()
        startTap(prompt: true)

        // for development: `open Homeword.app --args -show prompts` opens a Settings tab, `-demoProofread file` runs the
        // proofread panel on a file's text (no selection, Replace disabled)
        let args = UserDefaults(suiteName: UserDefaults.argumentDomain)
        if let tab = args?.string(forKey: "show") { showSettings(tab: tab) }
        if let path = args?.string(forKey: "demoProofread"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
            proofreader.demo(text: text, mode: args?.string(forKey: "demoMode") ?? "fix")
        }
    }

    func applicationWillTerminate(_ note: Notification) { Metrics.shared.flushKeys() }

    /// Reading fields needs the Accessibility permission, the keyboard tap needs it too (and on some systems Input Monitoring);
    /// until both work, check again every 2 s.
    private func startTap(prompt: Bool) {
        axTrusted = AX.trusted(prompt: prompt)
        if axTrusted && !tapRunning {
            tapRunning = tap.start()
            if !tapRunning && !askedListen { askedListen = true; CGRequestListenEventAccess() }
        }
        writeStatus()
        updateIcon()
        if axTrusted && tapRunning {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.startTap(prompt: false) }
        }
    }

    /// Permission state for troubleshooting (status.json next to the metrics; no user data).
    private func writeStatus() {
        let o: [String: Any] = ["accessibility": axTrusted, "keyTap": tapRunning, "listenAccess": CGPreflightListenEventAccess(),
                                "postAccess": CGPreflightPostEventAccess(), "bundlePath": Bundle.main.bundlePath,
                                "t": ISO8601DateFormatter().string(from: Date())]
        let url = Metrics.shared.url.deletingLastPathComponent().appendingPathComponent("status.json")
        try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    private func key(_ k: KeyPress) -> TapDecision {
        if Hotkey.recording { return .pass }                    // Settings is recording a new shortcut
        if proofreader.enabled {
            if Hotkey.load(Pref.proofreadKey).matches(k) { proofreader.run(mode: "fix"); return .consume }
            if Hotkey.load(Pref.rewriteKey).matches(k) { proofreader.run(mode: "rewrite"); return .consume }
        }
        return predictor.key(k)
    }

    private func updateIcon() {
        let ok = tapRunning && Services.shared.state != .stopped
        status.button?.appearsDisabled = !ok || !Pref.d.bool(forKey: Pref.predictions)
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let predict = NSMenuItem(title: "Predict While Typing", action: #selector(togglePredictions), keyEquivalent: "")
        predict.state = Pref.d.bool(forKey: Pref.predictions) ? .on : .off
        menu.addItem(predict)
        for (title, sel, key) in [("Proofread Selection", #selector(proofreadSelection), Pref.proofreadKey),
                                  ("Rewrite Selection", #selector(rewriteSelection), Pref.rewriteKey)] {
            let (ch, mods) = Hotkey.load(key).menuEquivalent
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: ch)
            item.keyEquivalentModifierMask = mods
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: axTrusted ? "Accessibility: allowed" : "Accessibility: not allowed (click to open Settings)",
                                action: axTrusted ? nil : #selector(openAccessibility), keyEquivalent: ""))
        if axTrusted && !tapRunning {
            menu.addItem(NSMenuItem(title: "Keyboard: blocked (click to allow in Input Monitoring)", action: #selector(openInputMonitoring), keyEquivalent: ""))
        }
        let e = Services.shared
        let engine = e.state == .stopped ? (e.stoppedByUser ? "Engine: stopped (click to start)" : "Engine: stopped, starts when needed (click to start)")
            : "Engine: \(e.state.rawValue.lowercased())"
        menu.addItem(NSMenuItem(title: engine, action: e.state == .stopped ? #selector(startServices) : nil, keyEquivalent: ""))
        if let problem = e.availabilityProblem, e.state == .running {
            let item = NSMenuItem(title: problem, action: #selector(openSystemSettings), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Statistics…", action: #selector(showStats), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettingsGeneral), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Homeword", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc private func openSystemSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    @objc private func togglePredictions() {
        Pref.d.set(!Pref.d.bool(forKey: Pref.predictions), forKey: Pref.predictions)
        updateIcon()
    }
    @objc private func proofreadSelection() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.proofreader.run(mode: "fix") } }
    @objc private func rewriteSelection() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.proofreader.run(mode: "rewrite") } }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc private func startServices() { Services.shared.start(force: true) }
    @objc private func showSettingsGeneral() { showSettings(tab: "general") }
    @objc private func showStats() { showSettings(tab: "stats") }

    private func showSettings(tab: String) {
        nav.tab = tab
        let w = settings ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 660), styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Homeword"
            w.contentView = NSHostingView(rootView: SettingsView(nav: nav))
            w.isReleasedWhenClosed = false
            w.center()
            settings = w
            return w
        }()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}
