// Writing styles: which prompt the engine uses for the field being typed in. The user's choice per app wins; browsers are mapped
// by the page's host name; other apps by bundle ID; everything else is General. "off" = never predict in that app.
import AppKit

enum Style {
    static let all = ["general", "chat", "email", "work", "academic", "code"]
    static let titles = ["general": "General", "chat": "Chat", "email": "Email", "work": "Work documents", "academic": "Academic",
                         "code": "Code", "off": "Off"]
    static func title(_ s: String) -> String { titles[s] ?? s }

    /// Built-in styles by bundle ID (an app not listed is General).
    static let builtIn: [String: String] = {
        var m: [String: String] = [:]
        for b in ["com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "net.whatsapp.WhatsApp",
                  "ru.keepcoder.Telegram", "org.telegram.desktop", "com.hnc.Discord", "org.whispersystems.signal-desktop",
                  "com.facebook.archon", "us.zoom.xos", "com.facebook.Workplace"] { m[b] = "chat" }
        for b in ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
                  "com.mimestream.Mimestream", "it.bloop.airmail2"] { m[b] = "email" }
        for b in ["com.apple.iWork.Pages", "com.apple.iWork.Keynote", "com.microsoft.Word", "com.microsoft.Powerpoint",
                  "notion.id", "com.quip.Desktop"] { m[b] = "work" }
        for b in ["TeXShop", "org.texstudio.texstudio", "com.texifier.Texifier", "fi.iki.hsivonen.texworks"] { m[b] = "academic" }
        for b in ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.jetbrains.intellij",
                  "com.jetbrains.pycharm", "com.jetbrains.goland", "dev.zed.Zed", "com.sublimetext.4", "com.panic.Nova"] { m[b] = "code" }
        // terminals (shells have their own completion and Tab) and password managers
        for b in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "dev.warp.Warp-Stable",
                  "io.alacritty", "com.github.wez.wezterm", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                  "com.apple.keychainaccess", "com.apple.Passwords"] { m[b] = "off" }
        return m
    }()

    static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac",
                                        "com.brave.Browser", "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "org.chromium.Chromium",
                                        "org.mozilla.firefox"]

    /// Web apps by host name (suffix match).
    static let hosts: [(String, String)] = [
        ("mail.google.com", "email"), ("outlook.live.com", "email"), ("outlook.office.com", "email"), ("outlook.office365.com", "email"),
        ("app.slack.com", "chat"), ("teams.microsoft.com", "chat"), ("teams.live.com", "chat"), ("discord.com", "chat"),
        ("web.whatsapp.com", "chat"), ("messenger.com", "chat"), ("web.telegram.org", "chat"), ("chat.google.com", "chat"),
        ("docs.google.com", "work"), ("notion.so", "work"), ("atlassian.net", "work"), ("quip.com", "work"),
        ("overleaf.com", "academic"), ("github.com", "code"), ("gitlab.com", "code"),
    ]

    static func forHost(_ host: String) -> String? {
        let h = host.lowercased()
        return hosts.first { h == $0.0 || h.hasSuffix("." + $0.0) }?.1
    }

    /// The user's choices: bundle ID → style ("off" included). Missing = Automatic.
    static var userChoices: [String: String] {
        get { Pref.d.dictionary(forKey: Pref.appStyles) as? [String: String] ?? [:] }
        set { Pref.d.set(newValue, forKey: Pref.appStyles) }
    }

    /// The automatic style of an app (no user choice), and for browsers of the page.
    static func automatic(bundle: String, host: String?) -> String {
        if browsers.contains(bundle), let host, let s = forHost(host) { return s }
        return builtIn[bundle] ?? "general"
    }

    /// The style to use: the user's choice ("auto" = listed in Settings but automatic), else the automatic one.
    static func resolve(bundle: String, host: String?) -> String {
        if let c = userChoices[bundle], c != "auto" { return c }
        return automatic(bundle: bundle, host: host)
    }
}

/// An installed app's display name and icon.
struct AppInfo {
    let bundle: String
    let name: String
    let icon: NSImage?
    let installed: Bool

    static func of(_ bundle: String) -> AppInfo {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            let info = Bundle(url: url)?.infoDictionary
            let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
                ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return AppInfo(bundle: bundle, name: name, icon: NSWorkspace.shared.icon(forFile: url.path), installed: true)
        }
        return AppInfo(bundle: bundle, name: bundle, icon: nil, installed: false)
    }
}
