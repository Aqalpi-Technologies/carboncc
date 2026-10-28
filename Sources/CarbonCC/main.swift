// CarbonCC — a clipboard history in the macOS menu bar.
// https://github.com/Aqalpi-Technologies/carboncc
// Copyright (c) 2026 Aqalpi Technologies. MIT License.
//
// Build with scripts/install.sh (needs macOS 13+ and Xcode Command Line Tools).

import Cocoa
import SwiftUI
import Combine
import Carbon.HIToolbox
import CryptoKit
import ServiceManagement
import ApplicationServices
import Vision
import ImageIO

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

// MARK: - Helpers

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}

extension NSImage {
    func resized(maxSide: CGFloat) -> NSImage {
        let s = size
        guard s.width > 0, s.height > 0 else { return self }
        let scale = min(maxSide / s.width, maxSide / s.height, 1)
        let newSize = NSSize(width: max(1, s.width * scale), height: max(1, s.height * scale))
        let out = NSImage(size: newSize)
        out.lockFocus()
        draw(in: NSRect(origin: .zero, size: newSize), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}

/// First line, whitespace collapsed, truncated, with a "+N lines" hint.
func previewText(_ text: String, limit: Int) -> String {
    let lines = text.split(whereSeparator: \.isNewline)
    let first = (lines.first.map(String.init) ?? text)
        .replacingOccurrences(of: "\t", with: " ")
        .split(separator: " ", omittingEmptySubsequences: true)
        .joined(separator: " ")
    var out = first.count > limit ? String(first.prefix(limit)) + "…" : first
    if lines.count > 1 { out += "  (+\(lines.count - 1) lines)" }
    return out
}

/// NSMenuItem that runs a closure.
final class BlockMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(BlockMenuItem.fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }
}

// MARK: - Text transforms

enum JSONFormatter {
    /// Re-indents (or minifies) JSON while keeping the original key order.
    static func format(_ s: String, pretty: Bool) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        else { return nil }

        func pad(_ n: Int) -> String { String(repeating: "  ", count: max(0, n)) }

        let chars = Array(trimmed)
        var out = ""
        var indent = 0
        var inString = false
        var escaped = false
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                // Keep empty containers on one line: {} and []
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" {
                    out.append(c)
                    out.append(chars[j])
                    i = j + 1
                    continue
                }
                out.append(c)
                if pretty { indent += 1; out += "\n" + pad(indent) }
            case "}", "]":
                if pretty { indent -= 1; out += "\n" + pad(indent) }
                out.append(c)
            case ",":
                out.append(c)
                if pretty { out += "\n" + pad(indent) }
            case ":":
                out.append(c)
                if pretty { out += " " }
            default:
                if !c.isWhitespace { out.append(c) }
            }
            i += 1
        }
        return out
    }
}

enum TextTransform: String, CaseIterable, Identifiable {
    case uppercase, lowercase, titleCase
    case trim, singleLine, sortLines, uniqueLines
    case prettyJSON, minifyJSON
    case urlEncode, urlDecode, base64Encode, base64Decode

    var id: String { rawValue }

    static let groups: [[TextTransform]] = [
        [.uppercase, .lowercase, .titleCase],
        [.trim, .singleLine, .sortLines, .uniqueLines],
        [.prettyJSON, .minifyJSON],
        [.urlEncode, .urlDecode, .base64Encode, .base64Decode],
    ]

    var label: String {
        switch self {
        case .uppercase:    return "UPPERCASE"
        case .lowercase:    return "lowercase"
        case .titleCase:    return "Title Case"
        case .trim:         return "Trim Whitespace"
        case .singleLine:   return "Join Into One Line"
        case .sortLines:    return "Sort Lines"
        case .uniqueLines:  return "Remove Duplicate Lines"
        case .prettyJSON:   return "Format JSON"
        case .minifyJSON:   return "Minify JSON"
        case .urlEncode:    return "URL Encode"
        case .urlDecode:    return "URL Decode"
        case .base64Encode: return "Base64 Encode"
        case .base64Decode: return "Base64 Decode"
        }
    }

    private static let urlSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Returns nil when the transform doesn't apply (e.g. invalid JSON).
    func apply(_ s: String) -> String? {
        let lines = s.components(separatedBy: .newlines)
        switch self {
        case .uppercase:
            return s.uppercased()
        case .lowercase:
            return s.lowercased()
        case .titleCase:
            return s.capitalized
        case .trim:
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .singleLine:
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .sortLines:
            return lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .joined(separator: "\n")
        case .uniqueLines:
            var seen = Set<String>()
            return lines.filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .prettyJSON:
            return JSONFormatter.format(s, pretty: true)
        case .minifyJSON:
            return JSONFormatter.format(s, pretty: false)
        case .urlEncode:
            return s.addingPercentEncoding(withAllowedCharacters: Self.urlSafe)
        case .urlDecode:
            return s.removingPercentEncoding
        case .base64Encode:
            return Data(s.utf8).base64EncodedString()
        case .base64Decode:
            var t = s.filter { !$0.isWhitespace }
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while t.count % 4 != 0 { t += "=" }
            guard let d = Data(base64Encoded: t), let out = String(data: d, encoding: .utf8) else { return nil }
            return out
        }
    }
}

// MARK: - OCR (Apple Vision, fully on-device)

enum OCR {
    static func recognize(url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        } catch {
            return ""
        }

        // Top-to-bottom, then left-to-right.
        let observations = (request.results ?? []).sorted { a, b in
            let ay = (a.boundingBox.midY * 100).rounded()
            let by = (b.boundingBox.midY * 100).rounded()
            return ay != by ? ay > by : a.boundingBox.minX < b.boundingBox.minX
        }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

// MARK: - Global hotkey presets

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case cmdShiftV, optCmdV, ctrlCmdV, ctrlOptV, off
    var id: String { rawValue }

    var label: String {
        switch self {
        case .cmdShiftV: return "⇧⌘V"
        case .optCmdV:   return "⌥⌘V"
        case .ctrlCmdV:  return "⌃⌘V"
        case .ctrlOptV:  return "⌃⌥V"
        case .off:       return "Off"
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .cmdShiftV: return UInt32(cmdKey | shiftKey)
        case .optCmdV:   return UInt32(cmdKey | optionKey)
        case .ctrlCmdV:  return UInt32(cmdKey | controlKey)
        case .ctrlOptV:  return UInt32(controlKey | optionKey)
        case .off:       return 0
        }
    }
}

// MARK: - Settings (persisted in UserDefaults)

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    private enum Key {
        static let maxItems = "maxItems"
        static let groupSize = "groupSize"
        static let previewLength = "previewLength"
        static let moveToTop = "moveToTopOnPaste"
        static let autoPaste = "autoPaste"
        static let plainDefault = "plainTextByDefault"
        static let captureImages = "captureImages"
        static let captureFiles = "captureFiles"
        static let ocrImages = "ocrImages"
        static let hotKey = "hotKey"
        static let useCustomColor = "useCustomColor"
        static let iconColor = "iconColor"
        static let iconName = "iconName"
    }

    @Published var maxItems: Int            { didSet { d.set(maxItems, forKey: Key.maxItems) } }
    @Published var groupSize: Int           { didSet { d.set(groupSize, forKey: Key.groupSize) } }
    @Published var previewLength: Int       { didSet { d.set(previewLength, forKey: Key.previewLength) } }
    @Published var moveToTopOnPaste: Bool   { didSet { d.set(moveToTopOnPaste, forKey: Key.moveToTop) } }
    @Published var autoPaste: Bool          { didSet { d.set(autoPaste, forKey: Key.autoPaste) } }
    @Published var plainTextByDefault: Bool { didSet { d.set(plainTextByDefault, forKey: Key.plainDefault) } }
    @Published var captureImages: Bool      { didSet { d.set(captureImages, forKey: Key.captureImages) } }
    @Published var captureFiles: Bool       { didSet { d.set(captureFiles, forKey: Key.captureFiles) } }
    @Published var ocrImages: Bool          { didSet { d.set(ocrImages, forKey: Key.ocrImages) } }
    @Published var hotKey: String           { didSet { d.set(hotKey, forKey: Key.hotKey) } }
    @Published var useCustomColor: Bool     { didSet { d.set(useCustomColor, forKey: Key.useCustomColor) } }
    @Published var iconColor: Color         { didSet { d.set(NSColor(iconColor).hexString, forKey: Key.iconColor) } }
    @Published var iconName: String         { didSet { d.set(iconName, forKey: Key.iconName) } }

    var hotKeyPreset: HotKeyPreset { HotKeyPreset(rawValue: hotKey) ?? .cmdShiftV }
    var accentNSColor: NSColor { useCustomColor ? NSColor(iconColor) : .secondaryLabelColor }
    var accentColor: Color { useCustomColor ? iconColor : Color.accentColor }

    private init() {
        d.register(defaults: [
            Key.maxItems: 100,
            Key.groupSize: 10,
            Key.previewLength: 50,
            Key.moveToTop: true,
            Key.autoPaste: true,
            Key.plainDefault: false,
            Key.captureImages: true,
            Key.captureFiles: true,
            Key.ocrImages: true,
            Key.hotKey: HotKeyPreset.cmdShiftV.rawValue,
            Key.useCustomColor: false,
            Key.iconColor: "#0A84FF",
            Key.iconName: "doc.on.clipboard",
        ])
        maxItems = d.integer(forKey: Key.maxItems)
        groupSize = d.integer(forKey: Key.groupSize)
        previewLength = d.integer(forKey: Key.previewLength)
        moveToTopOnPaste = d.bool(forKey: Key.moveToTop)
        autoPaste = d.bool(forKey: Key.autoPaste)
        plainTextByDefault = d.bool(forKey: Key.plainDefault)
        captureImages = d.bool(forKey: Key.captureImages)
        captureFiles = d.bool(forKey: Key.captureFiles)
        ocrImages = d.bool(forKey: Key.ocrImages)
        hotKey = d.string(forKey: Key.hotKey) ?? HotKeyPreset.cmdShiftV.rawValue
        useCustomColor = d.bool(forKey: Key.useCustomColor)
        iconColor = Color(nsColor: NSColor(hex: d.string(forKey: Key.iconColor) ?? "") ?? .systemBlue)
        iconName = d.string(forKey: Key.iconName) ?? "doc.on.clipboard"
    }
}

// MARK: - Clipboard item

struct ClipItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image, files }

    var id = UUID()
    var kind: Kind
    var text: String              // the text, file paths, or "Image W×H"
    var rtf: Data? = nil          // formatting, if the source app provided it
    var html: Data? = nil
    var imageFile: String? = nil  // PNG in ~/Library/Application Support/CarbonCC/images
    var filePaths: [String]? = nil
    var ocrText: String? = nil    // text recognized in an image ("" = none found)
    var hash: String              // used to detect duplicates
    var pinned = false
    var date = Date()
    var sourceApp: String? = nil      // e.g. "Safari" — the app that was frontmost when copied
    var sourceBundleID: String? = nil

    var displayText: String {
        switch kind {
        case .text, .image:
            return text
        case .files:
            let names = (filePaths ?? []).map { ($0 as NSString).lastPathComponent }
            if names.count > 1 { return "\(names[0])  +\(names.count - 1) more" }
            return names.first ?? "Files"
        }
    }

    var kindLabel: String {
        switch kind {
        case .text:  return (rtf != nil || html != nil) ? "Formatted text" : "Text"
        case .image: return "Image"
        case .files: return (filePaths?.count ?? 0) > 1 ? "\(filePaths!.count) files" : "File"
        }
    }

    var details: String {
        switch kind {
        case .text:
            let lines = text.components(separatedBy: .newlines).count
            let words = text.split { $0.isWhitespace || $0.isNewline }.count
            return "\(kindLabel) · \(text.count) chars · \(words) words · \(lines) lines"
        case .image:
            let ocr: String
            switch ocrText {
            case nil: ocr = ""
            case let t? where t.isEmpty: ocr = " · no text found"
            case let t?: ocr = " · \(t.split { $0.isWhitespace || $0.isNewline }.count) words of text"
            }
            return text + ocr
        case .files:
            return kindLabel
        }
    }

    func matches(_ q: String) -> Bool {
        text.localizedCaseInsensitiveContains(q)
            || displayText.localizedCaseInsensitiveContains(q)
            || (ocrText?.localizedCaseInsensitiveContains(q) ?? false)
            || (sourceApp?.localizedCaseInsensitiveContains(q) ?? false)
    }
}

/// "just now", "5 mins ago", "2 hours ago", "yesterday", "3 days ago", "12 Oct"
func relativeTime(_ date: Date, now: Date = Date()) -> String {
    let s = max(0, now.timeIntervalSince(date))
    func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
    switch s {
    case ..<60:        return "just now"
    case ..<3600:      return plural(Int(s / 60), "min")
    case ..<86_400:    return plural(Int(s / 3600), "hour")
    case ..<172_800:   return "yesterday"
    case ..<604_800:   return plural(Int(s / 86_400), "day")
    default:
        let f = DateFormatter()
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        f.dateFormat = sameYear ? "d MMM" : "d MMM yyyy"
        return f.string(from: date)
    }
}

// MARK: - Categories

enum ClipCategory: String, CaseIterable, Identifiable {
    case all, pinned, text, images, links, code, json, colors, files
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .pinned: return "Pinned"
        case .text: return "Text"
        case .images: return "Images"
        case .links: return "Links"
        case .code: return "Code"
        case .json: return "JSON"
        case .colors: return "Colors"
        case .files: return "Files"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .pinned: return "pin"
        case .text: return "text.alignleft"
        case .images: return "photo"
        case .links: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .json: return "curlybraces"
        case .colors: return "paintpalette"
        case .files: return "doc"
        }
    }
}

/// A color written as #hex, rgb()/rgba() or hsl()/hsla().
struct ColorValue {
    let r: Double, g: Double, b: Double, a: Double   // 0…1

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(nsColor: nsColor) }

    var hex: String {
        let base = String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
        return a < 1 ? base + String(format: "%02X", Int(round(a * 255))) : base
    }

    var rgb: String {
        let (R, G, B) = (Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
        return a < 1 ? "rgba(\(R), \(G), \(B), \(String(format: "%.2g", a)))" : "rgb(\(R), \(G), \(B))"
    }

    var hsl: String {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        var h = 0.0, s = 0.0
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            switch mx {
            case r: h = (g - b) / d + (g < b ? 6 : 0)
            case g: h = (b - r) / d + 2
            default: h = (r - g) / d + 4
            }
            h /= 6
        }
        return "hsl(\(Int(round(h * 360))), \(Int(round(s * 100)))%, \(Int(round(l * 100)))%)"
    }

    static func parse(_ raw: String) -> ColorValue? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty, t.count <= 48 else { return nil }

        if t.hasPrefix("#") {
            var hex = String(t.dropFirst())
            guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
            if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard let v = UInt64(hex, radix: 16) else { return nil }
            if hex.count == 6 {
                return ColorValue(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255,
                                  b: Double(v & 0xFF) / 255, a: 1)
            }
            return ColorValue(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
                              b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
        }

        func args(_ prefix: String) -> [String]? {
            guard t.hasPrefix(prefix), t.hasSuffix(")"),
                  let open = t.firstIndex(of: "(") else { return nil }
            let inner = t[t.index(after: open)..<t.index(before: t.endIndex)]
            let parts = inner.split { $0 == "," || $0 == " " || $0 == "/" }.map(String.init)
            return (3...4).contains(parts.count) ? parts : nil
        }
        func num(_ s: String, scale: Double) -> Double? {
            if s.hasSuffix("%") { return Double(s.dropLast()).map { $0 / 100 } }
            return Double(s).map { $0 / scale }
        }
        func alpha(_ p: [String]) -> Double? { p.count == 4 ? num(p[3], scale: 1) : 1 }

        if let p = args("rgb") {
            guard let r = num(p[0], scale: 255), let g = num(p[1], scale: 255),
                  let b = num(p[2], scale: 255), let a = alpha(p),
                  [r, g, b, a].allSatisfy({ (0...1).contains($0) }) else { return nil }
            return ColorValue(r: r, g: g, b: b, a: a)
        }
        if let p = args("hsl") {
            guard let h = Double(p[0].replacingOccurrences(of: "deg", with: "")),
                  let s = num(p[1], scale: 100), let l = num(p[2], scale: 100), let a = alpha(p),
                  [s, l, a].allSatisfy({ (0...1).contains($0) }) else { return nil }
            let c = (1 - abs(2 * l - 1)) * s
            let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
            let (r1, g1, b1): (Double, Double, Double)
            switch hh {
            case ..<1: (r1, g1, b1) = (c, x, 0)
            case ..<2: (r1, g1, b1) = (x, c, 0)
            case ..<3: (r1, g1, b1) = (0, c, x)
            case ..<4: (r1, g1, b1) = (0, x, c)
            case ..<5: (r1, g1, b1) = (x, 0, c)
            default:   (r1, g1, b1) = (c, 0, x)
            }
            let m = l - c / 2
            return ColorValue(r: r1 + m, g: g1 + m, b: b1 + m, a: a)
        }
        return nil
    }
}

/// Decides which category a copied item belongs to.
enum Classifier {
    static func category(of item: ClipItem) -> ClipCategory {
        switch item.kind {
        case .image: return .images
        case .files: return .files
        case .text:  break
        }
        let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ColorValue.parse(t) != nil { return .colors }
        if isLink(t) { return .links }
        if isJSON(t) { return .json }
        if isCode(t, bundleID: item.sourceBundleID) { return .code }
        return .text
    }

    static func url(from t: String) -> URL? {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count < 4000, !s.contains(where: { $0.isWhitespace }) else { return nil }
        if let u = URL(string: s), let scheme = u.scheme?.lowercased() {
            if ["http", "https", "ftp"].contains(scheme), u.host != nil { return u }
            if scheme == "mailto" { return u }
            return nil
        }
        if s.lowercased().hasPrefix("www."), s.dropFirst(4).contains(".") {
            return URL(string: "https://" + s)
        }
        return nil
    }

    static func isLink(_ t: String) -> Bool { url(from: t) != nil }

    static func isJSON(_ t: String) -> Bool {
        guard let f = t.first, f == "{" || f == "[", t.utf8.count < 2_000_000,
              let d = t.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: d)) != nil
    }

    // Apps where copied text is very likely code.
    private static let codeApps = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed", "com.sublimetext", "com.jetbrains.", "com.google.android.studio",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.", "com.mitchellh.ghostty",
        "com.github.GitHubClient", "com.panic.Nova", "com.barebones.bbedit",
    ]

    private static func rx(_ p: String, _ opts: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: opts)
    }

    // (pattern, weight)
    private static let signals: [(NSRegularExpression, Int)] = [
        (rx(#"^\s*(import\s+[\w.{]|from\s+\S+\s+import|#include\s*[<"]|package\s+[\w.]+;?$|using\s+[\w.]+;)"#), 3),
        (rx(#"^\s*(\$\s+)?(sudo|git|npm|npx|yarn|pnpm|brew|pip3?|cd|ls|curl|wget|docker|kubectl|ssh|scp|chmod|chown|mkdir|rm|mv|cp|xcrun|cargo|tar|grep)\s+\S"#), 3),
        (rx(#"^\s*(SELECT\s+[\w*,.\s]+\s+FROM\s+\w|INSERT\s+INTO\s+\w|UPDATE\s+\w+\s+SET\s|DELETE\s+FROM\s+\w|CREATE\s+(TABLE|INDEX|VIEW)\s+\w)"#), 3),
        (rx(#"\b(func|function|def|class|struct|enum|interface|const|let|var|return|public|private|static|async|await|elif|lambda|impl|fn)\b"#), 1),
        (rx(#"(=>|->|::|&&|\|\||===|!==|\+=|-=|==|!=)"#), 1),
        (rx(#"[;{}]\s*$"#), 1),
        (rx(#"\w+\([^()\n]*\)\s*[{;:]?\s*$"#), 1),
        (rx(#"</?[a-zA-Z][\w-]*(\s+[\w-]+(="[^"]*")?)*\s*/?>"#), 2),
        (rx(#"^\s*(//|/\*|\*\s|#!)"#), 1),
        (rx(#"^( {2,}|\t)\S"#), 1),
    ]

    static func isCode(_ t: String, bundleID: String?) -> Bool {
        let sample = String(t.prefix(5000))
        let range = NSRange(sample.startIndex..., in: sample)
        var score = 0
        if let b = bundleID, codeApps.contains(where: { b.hasPrefix($0) }) { score += 2 }
        for (re, weight) in signals where re.firstMatch(in: sample, range: range) != nil {
            score += weight
        }
        return score >= 3
    }
}

// MARK: - Clipboard store

final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var items: [ClipItem] = []
    var pinned: [ClipItem] { items.filter { $0.pinned } }
    var history: [ClipItem] { items.filter { !$0.pinned } }

    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let thumbs = NSCache<NSString, NSImage>()
    private let dir: URL
    private let imagesDir: URL
    private var dataFile: URL { dir.appendingPathComponent("items.json") }

    private let ocrQueue = DispatchQueue(label: "carboncc.ocr", qos: .utility)
    private var ocrPending = Set<UUID>()

    private let maxImageBytes = 40_000_000
    private let maxRichBytes = 2_000_000

    // Password managers mark secrets with these types — never record them.
    private let ignoredTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("CarbonCC", isDirectory: true)
        imagesDir = dir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: dataFile),
           let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) {
            items = decoded
        } else if let old = UserDefaults.standard.stringArray(forKey: "history") {
            // Migrate history from v1.x
            items = old.map { ClipItem(kind: .text, text: $0, hash: Self.hash("t:" + $0)) }
            save()
            UserDefaults.standard.removeObject(forKey: "history")
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: dataFile, options: .atomic)
        }
    }

    static func hash(_ s: String) -> String { hash(Data(s.utf8)) }
    static func hash(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    func imageURL(_ item: ClipItem) -> URL? {
        item.imageFile.map { imagesDir.appendingPathComponent($0) }
    }

    // MARK: Capture

    func start() {
        // macOS has no "copy" notification, so we watch the pasteboard's change counter.
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        recognizeMissingText()
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount

        let types = Set((pb.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: ignoredTypes) else { return }
        guard var captured = capture(pb) else { return }
        // The app in front when the copy happened is (almost always) where it came from.
        if let front = NSWorkspace.shared.frontmostApplication {
            captured.item.sourceApp = front.localizedName
            captured.item.sourceBundleID = front.bundleIdentifier
        }
        insert(captured.item, png: captured.png)
    }

    private func capture(_ pb: NSPasteboard) -> (item: ClipItem, png: Data?)? {
        let s = AppSettings.shared

        // 1. Files copied in Finder
        if s.captureFiles,
           let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map(\.path)
            let joined = paths.joined(separator: "\n")
            return (ClipItem(kind: .files, text: joined, filePaths: paths, hash: Self.hash("f:" + joined)), nil)
        }

        // 2. Text (keeping formatting if present)
        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var item = ClipItem(kind: .text, text: text, hash: Self.hash("t:" + text))
            if let rtf = pb.data(forType: .rtf), rtf.count <= maxRichBytes { item.rtf = rtf }
            if let html = pb.data(forType: .html), html.count <= maxRichBytes { item.html = html }
            return (item, nil)
        }

        // 3. Images (screenshots, "Copy Image", etc.)
        if s.captureImages,
           let raw = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           raw.count <= maxImageBytes,
           let rep = NSBitmapImageRep(data: raw),
           let png = rep.representation(using: .png, properties: [:]) {
            let item = ClipItem(kind: .image,
                                text: "Image \(rep.pixelsWide)×\(rep.pixelsHigh)",
                                hash: Self.hash(png))
            return (item, png)
        }
        return nil
    }

    private func insert(_ newItem: ClipItem, png: Data?) {
        if let i = items.firstIndex(where: { $0.hash == newItem.hash }) {
            if items[i].pinned { return } // already pinned, leave it where it is
            var existing = items.remove(at: i)
            existing.date = Date()
            existing.sourceApp = newItem.sourceApp
            existing.sourceBundleID = newItem.sourceBundleID
            if newItem.kind == .text {
                existing.rtf = newItem.rtf
                existing.html = newItem.html
            }
            items.insert(existing, at: 0)
        } else {
            var item = newItem
            if let png {
                let name = item.id.uuidString + ".png"
                do {
                    try png.write(to: imagesDir.appendingPathComponent(name))
                    item.imageFile = name
                } catch { return }
            }
            items.insert(item, at: 0)
            if item.kind == .image && AppSettings.shared.ocrImages {
                recognizeText(item.id)
            }
        }
        trim()
        save()
    }

    // MARK: OCR

    /// Runs OCR on any images that haven't been scanned yet (one at a time, in the background).
    func recognizeMissingText() {
        guard AppSettings.shared.ocrImages else { return }
        for item in items where item.kind == .image && item.ocrText == nil {
            recognizeText(item.id)
        }
    }

    func recognizeText(_ id: UUID, completion: ((String) -> Void)? = nil) {
        guard let item = items.first(where: { $0.id == id }), item.kind == .image else {
            completion?("")
            return
        }
        if let done = item.ocrText { completion?(done); return }
        guard let url = imageURL(item) else { completion?(""); return }
        if completion == nil && ocrPending.contains(id) { return }

        ocrPending.insert(id)
        ocrQueue.async {
            let text = OCR.recognize(url: url)
            DispatchQueue.main.async {
                self.ocrPending.remove(id)
                if let i = self.items.firstIndex(where: { $0.id == id }) {
                    self.items[i].ocrText = text
                    self.save()
                }
                completion?(text)
            }
        }
    }

    /// The text an item stands for: its text, its file paths, or the text inside its image.
    func sourceText(for item: ClipItem, completion: @escaping (String) -> Void) {
        switch item.kind {
        case .text, .files: completion(item.text)
        case .image:        recognizeText(item.id, completion: completion)
        }
    }

    // MARK: Editing

    func trim() {
        let maxItems = AppSettings.shared.maxItems
        guard items.filter({ !$0.pinned }).count > maxItems else { return }
        var count = 0
        var removed: [ClipItem] = []
        items.removeAll { item in
            guard !item.pinned else { return false }
            count += 1
            if count > maxItems { removed.append(item); return true }
            return false
        }
        removed.forEach(deleteFiles)
        save()
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: i)
        item.pinned.toggle()
        if item.pinned {
            items.append(item)       // pinned list keeps the order you pinned in
        } else {
            item.date = Date()
            items.insert(item, at: 0) // unpinned goes to the top of history
        }
        trim()
        save()
    }

    func delete(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: i)
        deleteFiles(removed)
        save()
    }

    /// Clears history but keeps pinned items.
    func clearHistory() {
        let removed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        removed.forEach(deleteFiles)
        save()
    }

    private func deleteFiles(_ item: ClipItem) {
        if let url = imageURL(item) { try? FileManager.default.removeItem(at: url) }
        thumbs.removeAllObjects()
    }

    // MARK: Using an item

    /// Puts the item on the clipboard (without recording it again).
    @discardableResult
    func use(_ id: UUID, plain: Bool, moveToTop: Bool) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        var item = items[i]
        if moveToTop && !item.pinned {
            items.remove(at: i)
            item.date = Date()
            items.insert(item, at: 0)
            save()
        }
        write(item, plain: plain)
        return true
    }

    /// Puts plain text on the clipboard without adding it to history.
    func writePlainText(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        lastChange = pb.changeCount
    }

    private func write(_ item: ClipItem, plain: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text, forType: .string)
            if !plain {
                if let rtf = item.rtf { pb.setData(rtf, forType: .rtf) }
                if let html = item.html { pb.setData(html, forType: .html) }
            }
        case .image:
            if let url = imageURL(item), let data = try? Data(contentsOf: url) {
                pb.setData(data, forType: .png)
                if let tiff = NSImage(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            }
        case .files:
            if plain {
                pb.setString(item.text, forType: .string) // paste the paths as text
            } else {
                let urls = (item.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL }
                pb.writeObjects(urls)
            }
        }
        lastChange = pb.changeCount
    }

    // MARK: Thumbnails

    func thumbnail(for item: ClipItem, size: CGFloat) -> NSImage? {
        switch item.kind {
        case .text:
            return nil
        case .image:
            let key = "\(item.id.uuidString)-\(Int(size))" as NSString
            if let cached = thumbs.object(forKey: key) { return cached }
            guard let url = imageURL(item), let img = NSImage(contentsOf: url) else { return nil }
            let t = img.resized(maxSide: size)
            thumbs.setObject(t, forKey: key)
            return t
        case .files:
            guard let path = item.filePaths?.first else { return nil }
            return fileIcon(path, size: size)
        }
    }

    func fileIcon(_ path: String, size: CGFloat) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path).copy() as! NSImage
        icon.size = NSSize(width: size, height: size)
        return icon
    }

    // MARK: Categories & source apps

    private var categoryCache: [UUID: ClipCategory] = [:]
    private let appIcons = NSCache<NSString, NSImage>()

    func category(of item: ClipItem) -> ClipCategory {
        if let c = categoryCache[item.id] { return c }
        let c = Classifier.category(of: item)
        categoryCache[item.id] = c
        return c
    }

    func counts() -> [ClipCategory: Int] {
        var out: [ClipCategory: Int] = [.all: items.count, .pinned: 0]
        for item in items {
            if item.pinned { out[.pinned, default: 0] += 1 }
            out[category(of: item), default: 0] += 1
        }
        return out
    }

    func appIcon(bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = appIcons.object(forKey: bundleID as NSString) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as! NSImage
        icon.size = NSSize(width: 32, height: 32)
        appIcons.setObject(icon, forKey: bundleID as NSString)
        return icon
    }
}

// MARK: - Simulated ⌘V

enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func pasteIntoFrontApp() {
        let src = CGEventSource(stateID: .combinedSessionState)
        // Ignore keys you might still be physically holding while the paste fires.
        src?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Global hotkey (Carbon — works without extra permissions)

final class GlobalHotKey {
    static let shared = GlobalHotKey()
    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var current: HotKeyPreset?
    private var handlerInstalled = false

    func register(_ preset: HotKeyPreset) {
        guard preset != current else { return }
        current = preset
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard preset != .off else { return }

        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { GlobalHotKey.shared.onPress?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x43424343), id: 1) // "CBCC"
        RegisterEventHotKey(UInt32(kVK_ANSI_V), preset.carbonModifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - Search panel

final class PanelModel: ObservableObject {
    @Published var query = "" { didSet { if oldValue != query { selection = 0 } } }
    @Published var category: ClipCategory = .all { didSet { if oldValue != category { selection = 0 } } }
    @Published var selection = 0
    @Published var focusToken = 0
    @Published var busy = false
    var choose: (ClipItem, Bool) -> Void = { _, _ in }                  // (item, plain)
    var transform: (ClipItem, TextTransform?) -> Void = { _, _ in }     // nil = image text as-is

    var results: [ClipItem] {
        let store = ClipboardStore.shared
        var list: [ClipItem]
        switch category {
        case .all:    list = store.pinned + store.history
        case .pinned: list = store.pinned
        default:      list = (store.pinned + store.history).filter { store.category(of: $0) == category }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.matches(q) } }
        return list
    }

    func cycleCategory(_ step: Int) {
        let all = ClipCategory.allCases
        let i = all.firstIndex(of: category) ?? 0
        category = all[(i + step + all.count) % all.count]
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Menu entries shared by the right-click menu and the preview's Transform button.
struct TransformMenuItems: View {
    let item: ClipItem
    let model: PanelModel

    var body: some View {
        if item.kind == .image {
            Button("Paste Text from Image") { model.transform(item, nil) }
            Divider()
        }
        ForEach(Array(TextTransform.groups.enumerated()), id: \.offset) { gi, group in
            if gi > 0 { Divider() }
            ForEach(group) { t in
                Button(t.label) { model.transform(item, t) }
            }
        }
    }
}

/// "Safari · 5 mins ago", with the app's icon. Updates itself every 30 seconds.
struct SourceAndTime: View {
    let item: ClipItem

    var body: some View {
        HStack(spacing: 4) {
            if let app = item.sourceApp {
                if let icon = ClipboardStore.shared.appIcon(bundleID: item.sourceBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                }
                Text(app)
                Text("·")
            }
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(relativeTime(item.date, now: ctx.date))
            }
        }
    }
}

/// The small picture at the start of each row.
struct ItemIcon: View {
    let item: ClipItem
    let category: ClipCategory
    var size: CGFloat = 26

    var body: some View {
        Group {
            if category == .colors, let c = ColorValue.parse(item.text) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(c.color)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
                    .padding(2)
            } else if let thumb = ClipboardStore.shared.thumbnail(for: item, size: size * 2) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(3)
            } else {
                Image(systemName: category.symbol).foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct ClipRow: View {
    let item: ClipItem
    let category: ClipCategory
    let index: Int
    let selected: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(index < 10 ? "⌘\(index == 9 ? 0 : index + 1)" : "")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .leading)

            ItemIcon(item: item, category: category)

            VStack(alignment: .leading, spacing: 2) {
                Text(previewText(item.displayText, limit: 80))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if item.pinned {
                        Image(systemName: "pin.fill").foregroundColor(accent)
                    }
                    Text(category.label)
                    Text("·")
                    SourceAndTime(item: item)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? accent.opacity(0.25) : Color.clear))
        .contentShape(Rectangle())
    }
}

/// The row of category tabs under the search field.
struct CategoryBar: View {
    @ObservedObject var model: PanelModel
    let counts: [ClipCategory: Int]
    let accent: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ClipCategory.allCases) { cat in
                    let count = counts[cat] ?? 0
                    let selected = model.category == cat
                    Button {
                        model.category = cat
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: cat.symbol)
                            Text(cat.label)
                            Text("\(count)")
                                .foregroundColor(selected ? Color.white.opacity(0.85) : Color.secondary)
                        }
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(selected ? accent : Color.primary.opacity(0.06)))
                        .foregroundColor(selected ? Color.white : (count == 0 ? Color.secondary : Color.primary))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
    }
}

struct PreviewPane: View {
    let item: ClipItem?
    let category: ClipCategory
    @ObservedObject var model: PanelModel
    private let maxChars = 20_000

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                ScrollView {
                    content(item)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(14)
                }
                Divider()
                HStack(spacing: 8) {
                    SourceAndTime(item: item)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("·").font(.caption).foregroundColor(.secondary)
                    Text(item.details)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Menu("Transform") { TransformMenuItems(item: item, model: model) }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        } else {
            VStack {
                Spacer()
                Text("Nothing selected").foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func limited(_ s: String) -> String {
        s.count > maxChars ? String(s.prefix(maxChars)) + "\n\n… (preview truncated)" : s
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.caption2.bold()).foregroundColor(.secondary)
    }

    @ViewBuilder
    private func content(_ item: ClipItem) -> some View {
        switch item.kind {
        case .text:
            textContent(item)

        case .image:
            VStack(alignment: .leading, spacing: 12) {
                if let img = ClipboardStore.shared.thumbnail(for: item, size: 900) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 240)
                        .cornerRadius(6)
                }
                switch item.ocrText {
                case nil:
                    Button("Find text in image") {
                        ClipboardStore.shared.recognizeText(item.id)
                    }
                case let t? where t.isEmpty:
                    Text("No text found in this image")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case let t?:
                    label("TEXT IN IMAGE")
                    Text(limited(t))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

        case .files:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(item.filePaths ?? [], id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(nsImage: ClipboardStore.shared.fileIcon(path, size: 32))
                        VStack(alignment: .leading, spacing: 2) {
                            Text((path as NSString).lastPathComponent)
                            Text(path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func textContent(_ item: ClipItem) -> some View {
        switch category {
        case .colors:
            if let c = ColorValue.parse(item.text) {
                VStack(alignment: .leading, spacing: 14) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(c.color)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15)))
                        .frame(height: 140)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        GridRow { label("HEX"); Text(c.hex) }
                        GridRow { label("RGB"); Text(c.rgb) }
                        GridRow { label("HSL"); Text(c.hsl) }
                    }
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    Text("Tip: right-click → Transform & Paste works on the text as copied.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

        case .links:
            VStack(alignment: .leading, spacing: 10) {
                if let url = Classifier.url(from: item.text) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text(url.host ?? url.absoluteString).font(.headline)
                    }
                    Text(limited(item.text))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Open in Browser") { NSWorkspace.shared.open(url) }
                }
            }

        case .json:
            VStack(alignment: .leading, spacing: 8) {
                label("JSON (FORMATTED)")
                Text(limited(item.text.count < 200_000
                             ? (JSONFormatter.format(item.text, pretty: true) ?? item.text)
                             : item.text))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }

        case .code:
            Text(limited(item.text))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)

        default:
            Text(limited(item.text))
                .font(.system(size: 13))
                .textSelection(.enabled)
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var store = ClipboardStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        let results = model.results
        let selected = results.indices.contains(model.selection) ? results[model.selection] : nil

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search clipboard, text inside images, or app name…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 4)

            CategoryBar(model: model, counts: store.counts(), accent: settings.accentColor)

            Divider()

            HStack(spacing: 0) {
                list(results)
                    .frame(width: 360)
                Divider()
                PreviewPane(item: selected,
                            category: selected.map { store.category(of: $0) } ?? .text,
                            model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            Text("↩ paste   ⇧↩ plain text   ⌘1–0 quick paste   ⇥ next category   ⌘T transform   ⌘P pin   ⌘⌫ delete   esc close")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.vertical, 8)
        }
        .frame(width: 880, height: 560)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onReceive(model.$focusToken) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
        }
    }

    @ViewBuilder
    private func list(_ results: [ClipItem]) -> some View {
        if results.isEmpty {
            VStack {
                Spacer()
                Text(model.query.isEmpty
                     ? (model.category == .all ? "Nothing copied yet" : "Nothing in \(model.category.label) yet")
                     : "No matches")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, item in
                            ClipRow(item: item,
                                    category: store.category(of: item),
                                    index: idx,
                                    selected: idx == model.selection,
                                    accent: settings.accentColor)
                                .id(item.id)
                                .onHover { inside in if inside { model.selection = idx } }
                                .onTapGesture {
                                    let shift = NSEvent.modifierFlags.contains(.shift)
                                    model.choose(item, settings.plainTextByDefault != shift)
                                }
                                .contextMenu {
                                    Button("Paste") { model.choose(item, false) }
                                    Button("Paste as Plain Text") { model.choose(item, true) }
                                    Menu("Transform & Paste") { TransformMenuItems(item: item, model: model) }
                                    Divider()
                                    Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item.id) }
                                    Button("Delete") { store.delete(item.id) }
                                }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { sel in
                    let current = model.results
                    if current.indices.contains(sel) { proxy.scrollTo(current[sel].id) }
                }
            }
        }
    }
}

/// Borderless panel that can take keyboard input without activating CarbonCC,
/// so the app you were typing in stays frontmost and receives the paste.
final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelController: NSObject, NSWindowDelegate {
    let model = PanelModel()
    var onChoose: ((UUID, Bool) -> Void)?   // (id, plain)
    var onPasteText: ((String) -> Void)?
    private var panel: SearchPanel!
    private var monitor: Any?
    private var menuOpen = false

    override init() {
        super.init()
        model.choose = { [weak self] item, plain in self?.choose(item, plain: plain) }
        model.transform = { [weak self] item, t in self?.transform(item, t) }

        let p = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: PanelView(model: model))
        p.delegate = self
        panel = p
    }

    func toggle() { panel.isVisible ? close() : show() }

    func show() {
        model.query = ""
        model.category = .all
        model.selection = 0
        model.busy = false
        position()
        panel.orderFrontRegardless()
        panel.makeKey()
        model.focusToken += 1
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.panel.isKeyWindow else { return event }
                return self.handle(event)
            }
        }
    }

    func close() {
        panel.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        if !menuOpen { close() }
    }

    private func choose(_ item: ClipItem, plain: Bool) {
        close()
        onChoose?(item.id, plain)
    }

    /// Converts the item's text (or the text inside its image) and pastes the result.
    private func transform(_ item: ClipItem, _ t: TextTransform?) {
        model.busy = true
        ClipboardStore.shared.sourceText(for: item) { [weak self] source in
            guard let self else { return }
            self.model.busy = false
            let result = t == nil ? source : t!.apply(source)
            guard let out = result, !out.isEmpty else {
                NSSound.beep() // e.g. invalid JSON, or no text found in the image
                return
            }
            self.close()
            self.onPasteText?(out)
        }
    }

    private func showTransformMenu(for item: ClipItem) {
        guard let view = panel.contentView else { return }
        let menu = NSMenu()
        if item.kind == .image {
            menu.addItem(BlockMenuItem("Paste Text from Image") { [weak self] in self?.transform(item, nil) })
            menu.addItem(.separator())
        }
        for (gi, group) in TextTransform.groups.enumerated() {
            if gi > 0 { menu.addItem(.separator()) }
            for t in group {
                menu.addItem(BlockMenuItem(t.label) { [weak self] in self?.transform(item, t) })
            }
        }
        let y: CGFloat = view.isFlipped ? 70 : view.bounds.height - 70
        menuOpen = true
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: 380, y: y), in: view)
        menuOpen = false
    }

    /// Centers the panel on the screen you're working on (the one with the mouse).
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let plainDefault = AppSettings.shared.plainTextByDefault
        let results = model.results
        let key = Int(e.keyCode)
        let hasSelection = results.indices.contains(model.selection)

        switch key {
        case kVK_Escape:
            close(); return nil
        case kVK_DownArrow:
            if !results.isEmpty { model.selection = min(model.selection + 1, results.count - 1) }
            return nil
        case kVK_UpArrow:
            model.selection = max(model.selection - 1, 0)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if hasSelection { choose(results[model.selection], plain: plainDefault != shift) }
            return nil
        case kVK_Tab:
            model.cycleCategory(shift ? -1 : 1)
            return nil
        default:
            break
        }

        guard flags.contains(.command) else { return e }

        if let n = Self.digit(for: key) {
            let idx = n == 0 ? 9 : n - 1
            if results.indices.contains(idx) { choose(results[idx], plain: plainDefault != shift) }
            return nil
        }
        if key == kVK_ANSI_T, hasSelection {
            showTransformMenu(for: results[model.selection])
            return nil
        }
        if key == kVK_ANSI_P, hasSelection {
            ClipboardStore.shared.togglePin(results[model.selection].id)
            return nil
        }
        if key == kVK_Delete, hasSelection {
            ClipboardStore.shared.delete(results[model.selection].id)
            model.selection = max(0, min(model.selection, results.count - 2))
            return nil
        }
        return e
    }

    private static func digit(for keyCode: Int) -> Int? {
        switch keyCode {
        case kVK_ANSI_1: return 1
        case kVK_ANSI_2: return 2
        case kVK_ANSI_3: return 3
        case kVK_ANSI_4: return 4
        case kVK_ANSI_5: return 5
        case kVK_ANSI_6: return 6
        case kVK_ANSI_7: return 7
        case kVK_ANSI_8: return 8
        case kVK_ANSI_9: return 9
        case kVK_ANSI_0: return 0
        default: return nil
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var s = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var axGranted = Paster.isTrusted
    @State private var cleared = false

    private let icons = ["doc.on.clipboard", "clipboard", "list.clipboard", "paperclip", "tray.full", "scissors"]
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Shortcut & pasting") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Open search panel", selection: $s.hotKey) {
                        ForEach(HotKeyPreset.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle("Paste automatically after selecting", isOn: $s.autoPaste)
                    Toggle("Paste as plain text by default (hold ⇧ for the opposite)", isOn: $s.plainTextByDefault)
                    Toggle("Move used item to the top", isOn: $s.moveToTopOnPaste)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("History") {
                VStack(alignment: .leading, spacing: 10) {
                    Stepper("Total items: \(s.maxItems)  (pinned items don't count)", value: $s.maxItems, in: 10...1000, step: 10)
                    Stepper("Items per group: \(s.groupSize)", value: $s.groupSize, in: 5...50, step: 5)
                    Stepper("Preview length: \(s.previewLength) characters", value: $s.previewLength, in: 20...150, step: 10)
                    Toggle("Save copied images", isOn: $s.captureImages)
                    Toggle("Find text in images automatically (makes screenshots searchable)", isOn: $s.ocrImages)
                        .onChange(of: s.ocrImages) { on in
                            if on { ClipboardStore.shared.recognizeMissingText() }
                        }
                    Toggle("Save copied files (from Finder)", isOn: $s.captureFiles)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Appearance") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Menu bar icon", selection: $s.iconName) {
                        ForEach(icons, id: \.self) { name in
                            Label(name, systemImage: name).tag(name)
                        }
                    }
                    Toggle("Use custom color", isOn: $s.useCustomColor)
                    ColorPicker("Icon, number & highlight color", selection: $s.iconColor, supportsOpacity: false)
                        .disabled(!s.useCustomColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("General") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { on in
                            do {
                                if on { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                    HStack {
                        Text("Auto-paste permission:")
                        Text(axGranted ? "Granted" : "Not granted")
                            .foregroundColor(axGranted ? .green : .orange)
                            .bold()
                        Spacer()
                        Button("Open Accessibility Settings") { Paster.openAccessibilitySettings() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack {
                Button(cleared ? "History cleared" : "Clear history (keeps pinned)") {
                    ClipboardStore.shared.clearHistory()
                    cleared = true
                }
                Spacer()
                Text("CarbonCC \(appVersion)").foregroundColor(.secondary).font(.caption)
            }
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(refresh) { _ in axGranted = Paster.isTrusted }
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let settings = AppSettings.shared
    private let store = ClipboardStore.shared
    private lazy var panel = PanelController()
    private var settingsWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()

        store.trim()
        store.start()

        panel.onChoose = { [weak self] id, plain in self?.paste(id, plain: plain, delay: 0.15) }
        panel.onPasteText = { [weak self] text in self?.pasteText(text, delay: 0.15) }
        GlobalHotKey.shared.onPress = { [weak self] in self?.panel.toggle() }
        GlobalHotKey.shared.register(settings.hotKeyPreset)

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateIcon()
                self.store.trim()
                GlobalHotKey.shared.register(self.settings.hotKeyPreset)
            }
            .store(in: &bag)

        if settings.autoPaste && !Paster.isTrusted { Paster.requestPermission() }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let base = NSImage(systemSymbolName: settings.iconName, accessibilityDescription: "Clipboard")
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard")!
        if settings.useCustomColor {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [NSColor(settings.iconColor)])
            let img = base.withSymbolConfiguration(cfg) ?? base
            img.isTemplate = false
            button.image = img
        } else {
            base.isTemplate = true
            button.image = base
        }
    }

    // MARK: Menu (rebuilt every time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let pinned = store.pinned
        let history = store.history
        let size = max(1, settings.groupSize)
        let total = settings.maxItems

        if settings.autoPaste && !Paster.isTrusted {
            let warn = NSMenuItem(title: "⚠️ Auto-paste off — click to grant permission",
                                  action: #selector(fixPermission), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        var headerText = history.isEmpty ? "Nothing copied yet — press ⌘C anywhere"
                                         : "\(history.count) of \(total) items"
        if !pinned.isEmpty { headerText += "  ·  \(pinned.count) pinned" }
        let header = NSMenuItem(title: headerText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Pinned items sit right in the main menu
        if !pinned.isEmpty {
            for item in pinned { menu.addItem(menuItem(for: item, number: nil)) }
            menu.addItem(.separator())
        }

        // History in groups: 1–10, 11–20, …
        var start = 0
        while start < total {
            let end = min(start + size, total)
            let group = NSMenuItem(title: "\(start + 1)–\(end)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            if start < history.count {
                for i in start..<min(end, history.count) {
                    sub.addItem(menuItem(for: history[i], number: i + 1))
                }
            } else {
                group.isEnabled = false
            }
            group.submenu = sub
            menu.addItem(group)
            start = end
        }

        menu.addItem(.separator())

        let searchTitle = settings.hotKeyPreset == .off ? "Search…" : "Search…   \(settings.hotKeyPreset.label)"
        let search = NSMenuItem(title: searchTitle, action: #selector(openSearch), keyEquivalent: "")
        search.target = self
        menu.addItem(search)

        let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !history.isEmpty
        menu.addItem(clear)

        let config = NSMenuItem(title: "Configure…", action: #selector(openSettings), keyEquivalent: ",")
        config.target = self
        menu.addItem(config)

        menu.addItem(.separator())
        let hint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hint.attributedTitle = NSAttributedString(
            string: "Click paste   ⇧ plain text   ⌘ pin / unpin   ⌥ delete",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        hint.isEnabled = false
        menu.addItem(hint)

        let quit = NSMenuItem(title: "Quit CarbonCC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func menuItem(for item: ClipItem, number: Int?) -> NSMenuItem {
        let mi = NSMenuItem(title: "", action: #selector(pick(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = item.id
        mi.attributedTitle = menuTitle(for: item, number: number)
        let tip = item.kind == .image ? (item.ocrText.flatMap { $0.isEmpty ? nil : $0 } ?? item.text) : item.text
        let origin = [item.sourceApp, relativeTime(item.date)].compactMap { $0 }.joined(separator: " · ")
        mi.toolTip = origin + "\n\n" + String(tip.prefix(600))
        mi.image = store.thumbnail(for: item, size: item.kind == .image ? 28 : 16)
        // Items 1–10 get number keys: open the menu and press 1…9, 0
        if let n = number, n <= 10 {
            mi.keyEquivalent = n == 10 ? "0" : "\(n)"
            mi.keyEquivalentModifierMask = []
        }
        return mi
    }

    private func menuTitle(for item: ClipItem, number: Int?) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let numFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .semibold)
        let prefix = number.map { "\($0).  " } ?? "📌  "
        let result = NSMutableAttributedString(
            string: prefix,
            attributes: [.font: numFont, .foregroundColor: settings.accentNSColor])
        result.append(NSAttributedString(
            string: previewText(item.displayText, limit: settings.previewLength),
            attributes: [.font: font]))
        return result
    }

    // MARK: Actions

    @objc private func pick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) { store.delete(id); return }
        if flags.contains(.command) { store.togglePin(id); return }
        let plain = settings.plainTextByDefault != flags.contains(.shift)
        paste(id, plain: plain, delay: 0.25)
    }

    private func paste(_ id: UUID, plain: Bool, delay: Double) {
        guard store.use(id, plain: plain, moveToTop: settings.moveToTopOnPaste) else { return }
        autoPaste(after: delay)
    }

    private func pasteText(_ text: String, delay: Double) {
        store.writePlainText(text)
        autoPaste(after: delay)
    }

    private func autoPaste(after delay: Double) {
        guard settings.autoPaste else { return }
        guard Paster.isTrusted else {
            showPermissionAlert()
            return
        }
        // Give the menu/panel time to close so focus is back in your text field.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Paster.pasteIntoFrontApp()
        }
    }

    @objc private func openSearch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.panel.show() }
    }

    @objc private func fixPermission() {
        Paster.requestPermission()
        Paster.openAccessibilitySettings()
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "CarbonCC needs Accessibility permission to paste"
        alert.informativeText = """
        The item is copied — press ⌘V to paste it for now.

        To paste automatically: open Accessibility settings and turn CarbonCC ON. \
        If CarbonCC is already listed, remove it with “–” and add it again.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            fixPermission()
        }
    }

    @objc private func clearHistory() {
        store.clearHistory()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: hosting)
            w.title = "CarbonCC Settings"
            w.styleMask.remove(.resizable)
            w.styleMask.remove(.miniaturizable)
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Migration from the pre-release name ("ClipBar")

enum LegacyMigration {
    static func run() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = base.appendingPathComponent("ClipBar")
        let newDir = base.appendingPathComponent("CarbonCC")
        if fm.fileExists(atPath: oldDir.path) && !fm.fileExists(atPath: newDir.path) {
            try? fm.copyItem(at: oldDir, to: newDir)
        }

        let d = UserDefaults.standard
        if !d.bool(forKey: "legacyMigrated") {
            if let old = d.persistentDomain(forName: "local.clipbar.app") {
                for (key, value) in old where d.object(forKey: key) == nil {
                    d.set(value, forKey: key)
                }
            }
            d.set(true, forKey: "legacyMigrated")
        }
    }
}

// MARK: - Entry point

LegacyMigration.run() // must run before settings and history load

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
