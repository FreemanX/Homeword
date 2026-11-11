// Python semantics the policy depends on, so ghostd behaves exactly like the Python policy it replaced: strings are sequences of
// Unicode code points (not Swift's grapheme clusters), Python's character classes (isalpha, isspace, ...), split/strip, and
// json.dumps byte for byte (profile names and stored results are SHA-1 hashes of it), round-half-even, percentiles.
import CryptoKit
import Foundation

typealias Scalars = [Unicode.Scalar]

extension String {
    var sc: Scalars { Array(unicodeScalars) }
    init<C: Collection>(scalars: C) where C.Element == Unicode.Scalar {
        var s = String()
        s.unicodeScalars.append(contentsOf: scalars)
        self = s
    }
    /// len() in Python: code points.
    var pyLen: Int { unicodeScalars.count }
}

extension Unicode.Scalar {
    /// str.isalpha: categories Lu, Ll, Lt, Lm, Lo.
    var pyAlpha: Bool {
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }
    /// str.isspace: Python's whitespace (bidirectional WS/B/S or category Zs).
    var pySpace: Bool {
        switch value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }
    /// str.isnumeric (also covers isdigit and isdecimal).
    var pyNumeric: Bool { properties.numericType != nil }
    var pyAlnum: Bool { pyAlpha || pyNumeric }
    /// \w in Python's re (str patterns): alphanumeric or underscore.
    var pyWord: Bool { pyAlnum || self == "_" }
    var pyUpper: Bool { properties.isUppercase }
    var pyLower: Bool { properties.isLowercase }
}

/// str.split() without arguments: runs of whitespace separate, no empty pieces.
func pySplit(_ s: String) -> [String] {
    var out: [String] = [], cur: Scalars = []
    for c in s.unicodeScalars {
        if c.pySpace {
            if !cur.isEmpty { out.append(String(scalars: cur)); cur = [] }
        } else { cur.append(c) }
    }
    if !cur.isEmpty { out.append(String(scalars: cur)) }
    return out
}

/// str.strip / lstrip / rstrip: `chars` nil = whitespace.
func pyStrip(_ s: String, _ chars: String? = nil, left: Bool = true, right: Bool = true) -> String {
    let set = chars.map { Set($0.unicodeScalars) }
    let strip: (Unicode.Scalar) -> Bool = { c in set.map { $0.contains(c) } ?? c.pySpace }
    let a = s.sc
    var i = 0, j = a.count
    if left { while i < j && strip(a[i]) { i += 1 } }
    if right { while j > i && strip(a[j - 1]) { j -= 1 } }
    return String(scalars: a[i..<j])
}
func pyLStrip(_ s: String, _ chars: String? = nil) -> String { pyStrip(s, chars, right: false) }
func pyRStrip(_ s: String, _ chars: String? = nil) -> String { pyStrip(s, chars, left: false) }

/// `needle in hay` and str.startswith, by code points (Swift's String compares canonical equivalents as equal).
func pyContains(_ hay: String, _ needle: String) -> Bool { pyFind(hay.sc, needle.sc) != nil }
func pyFind(_ hay: Scalars, _ needle: Scalars) -> Int? {
    if needle.isEmpty { return 0 }
    if needle.count > hay.count { return nil }
    for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
        if Array(hay[i..<(i + needle.count)]) == needle { return i }
    }
    return nil
}
func pyStarts(_ s: String, _ prefix: String) -> Bool { s.unicodeScalars.starts(with: prefix.unicodeScalars) }
func pyEq(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }
func pyLess(_ a: String, _ b: String) -> Bool { a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) }
func pyCount(_ s: String, _ c: Unicode.Scalar) -> Int { s.unicodeScalars.reduce(0) { $0 + ($1 == c ? 1 : 0) } }

/// round() to an int: half to even.
func pyRound(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }
/// round(x, n): correctly rounded on the binary value, as Python does.
func pyRound(_ x: Double, _ n: Int) -> Double { Double(String(format: "%.\(n)f", x)) ?? x }

func pct(_ xs: [Double], _ p: Double) -> Double? {
    let s = xs.sorted()
    guard !s.isEmpty else { return nil }
    return s[min(s.count - 1, pyRound(p / 100 * Double(s.count - 1)))]
}

func sha1Hex(_ s: String) -> String { Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

/// time.strftime("%Y-%m-%dT%H:%M:%S") in local time.
func localStamp(_ d: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return f.string(from: d)
}

// MARK: JSON values, as Python's json module sees them

/// A JSON boolean (JSONSerialization gives NSNumbers; Swift Bools bridge to the same class).
func isBool(_ v: Any?) -> Bool {
    guard let n = v as? NSNumber else { return false }
    return CFGetTypeID(n) == CFBooleanGetTypeID()
}
/// A JSON integer (not a bool, not a float): isinstance(v, int) without bools.
func intValue(_ v: Any?) -> Int? {
    guard let n = v as? NSNumber, !isBool(n) else { return nil }
    let t = String(cString: n.objCType)
    return ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(t) ? n.intValue : nil
}
func num(_ v: Any?) -> Double? { (v as? NSNumber).flatMap { isBool($0) ? nil : $0.doubleValue } }
func truthy(_ v: Any?) -> Bool {
    switch v {
    case nil, is NSNull: return false
    case let s as String: return !s.isEmpty
    case let a as [Any]: return !a.isEmpty
    case let d as [String: Any]: return !d.isEmpty
    case let n as NSNumber: return n.doubleValue != 0
    default: return true
    }
}

/// json.dumps(v, sort_keys=sortKeys, ensure_ascii=ascii): default separators ", " and ": ".
func pyDumps(_ v: Any?, sortKeys: Bool = true, ascii: Bool = true) -> String {
    var out = ""
    dump(v, &out, sortKeys, ascii)
    return out
}

private func dump(_ v: Any?, _ out: inout String, _ sortKeys: Bool, _ ascii: Bool) {
    switch v {
    case nil, is NSNull: out += "null"
    case let s as String: dumpString(s, &out, ascii)
    case let n as NSNumber:
        if isBool(n) { out += n.boolValue ? "true" : "false" }
        else if let i = intValue(n) { out += String(i) }
        else { out += pyFloatRepr(n.doubleValue) }
    case let a as [Any]:
        out += "["
        for (i, x) in a.enumerated() { if i > 0 { out += ", " }; dump(x, &out, sortKeys, ascii) }
        out += "]"
    case let d as [String: Any]:
        out += "{"
        let keys = sortKeys ? d.keys.sorted(by: pyLess) : Array(d.keys)
        for (i, k) in keys.enumerated() {
            if i > 0 { out += ", " }
            dumpString(k, &out, ascii)
            out += ": "
            dump(d[k], &out, sortKeys, ascii)
        }
        out += "}"
    default: dumpString("\(v!)", &out, ascii)
    }
}

private func dumpString(_ s: String, _ out: inout String, _ ascii: Bool) {
    out += "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if c.value < 0x20 || (ascii && c.value > 0x7E) {
                if c.value > 0xFFFF {                         // a surrogate pair, as Python writes it
                    let v = c.value - 0x10000
                    out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                } else {
                    out += String(format: "\\u%04x", c.value)
                }
            } else {
                out.unicodeScalars.append(c)
            }
        }
    }
    out += "\""
}

/// repr(float): the shortest repr, with Python's exponent rules.
func pyFloatRepr(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
    if d == d.rounded() && abs(d) < 1e16 { return String(format: "%.1f", d) }
    let s = "\(d)"                                            // Swift: shortest round-trip digits
    guard let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return s }
    let mant = String(s[..<e]), exp = Int(s[s.index(after: e)...]) ?? 0
    if exp >= -4 && exp < 16 { return String(Double(s) ?? d) }
    return mant + "e" + (exp < 0 ? "-" : "+") + String(format: "%02d", abs(exp))
}

/// JSON text for HTTP answers and files (key order and spacing do not matter there).
func jsonData(_ v: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
}
func jsonObject(_ d: Data) -> Any? { try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) }
func readJSON(_ path: String) -> Any? { FileManager.default.contents(atPath: path).flatMap(jsonObject) }

/// json.dump(data, f, indent=2, ensure_ascii=False) through a temporary file and a rename (mkstemp files are 0600).
func writeJSONFile(_ path: String, _ data: Any) throws {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var tmpl = Array((dir + "/.tmp-XXXXXX").utf8CString)
    let fd = mkstemp(&tmpl)
    guard fd >= 0 else { throw NSError(domain: "ghostd", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot write in \(dir)"]) }
    let tmp = String(cString: tmpl)
    let text = (try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    _ = text.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    close(fd)
    guard rename(tmp, path) == 0 else { unlink(tmp); throw NSError(domain: "ghostd", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot write \(path)"]) }
}

func perfMs(since t: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 }
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
