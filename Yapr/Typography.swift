import AppKit
import SwiftUI

/// EB Garamond (SIL Open Font License), bundled, and Yapr's paper-and-ink palette.
enum Typography {
    static func registerFonts() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func garamond(_ size: CGFloat, italic: Bool = false) -> NSFont {
        NSFont(name: italic ? "EBGaramond-Italic" : "EBGaramond-Regular", size: size) ?? .systemFont(ofSize: size)
    }

    static func garamondFont(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "EBGaramond-Italic" : "EBGaramond-Regular", fixedSize: size)
    }
}

enum Palette {
    static let paperNS = NSColor(srgbRed: 0.980, green: 0.973, blue: 0.957, alpha: 1)   // #FAF8F4
    static let inkNS = NSColor(srgbRed: 0.090, green: 0.086, blue: 0.082, alpha: 1)     // #171615

    static let paper = Color(nsColor: paperNS)
    static let ink = Color(nsColor: inkNS)
    static let pencil = Color(nsColor: inkNS).opacity(0.38)
    static let hairline = Color(nsColor: inkNS).opacity(0.08)
    static let signal = Color(red: 0.80, green: 0.22, blue: 0.16)
}
