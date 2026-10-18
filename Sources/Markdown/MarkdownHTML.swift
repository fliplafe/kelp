import Foundation

/// Dependency-free GitHub-flavoured Markdown → HTML.
/// Raw HTML is always escaped (safety over fidelity); block elements carry `data-line` (1-based source line).
public enum MarkdownHTML {
    public static func render(_ md: String) -> String {
        let src = md.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { Line(s: detab(String($1)), n: $0 + 1) }
        let r = Renderer()
        r.collectRefs(lines)
        return r.blocks(lines)
    }

    /// Full HTML document around `body`. `baseURL` (the document's URL) resolves relative links and images.
    /// `dark: true` forces the dark palette; otherwise `prefers-color-scheme` decides.
    public static func page(body: String, baseURL: URL?, dark: Bool) -> String {
        let base = baseURL.map { "<base href=\"\(esc($0.absoluteString))\">\n" } ?? ""
        return """
        <!doctype html>
        <html\(dark ? " class=\"dark\"" : "")>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="\(dark ? "dark" : "light dark")">
        \(base)<style>\(css)</style>
        </head>
        <body><article class="markdown-body">
        \(body)
        </article></body>
        </html>
        """
    }

    static let darkVars = "--fg:#f5f5f7;--muted:#a1a1a6;--bg:#1e1e1e;--border:#3d3d40;--subtle:#2a2a2d;--code:rgba(255,255,255,.09);--link:#4ea1ff;"
    static let css = """
    :root{--fg:#1d1d1f;--muted:#6e6e73;--bg:#fff;--border:#d8d8dc;--subtle:#f5f5f7;--code:rgba(0,0,0,.055);--link:#0066cc;}
    @media (prefers-color-scheme:dark){:root{\(darkVars)}}
    :root.dark{\(darkVars)}
    *{box-sizing:border-box}
    html{background:var(--bg);color:var(--fg);-webkit-text-size-adjust:100%}
    body{margin:0;font:16px/1.6 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased}
    .markdown-body{max-width:860px;margin:0 auto;padding:32px 16px 64px;overflow-wrap:break-word}
    .markdown-body>:first-child{margin-top:0}
    h1,h2,h3,h4,h5,h6{margin:1.5em 0 .6em;font-weight:600;line-height:1.25}
    h1{font-size:2em;padding-bottom:.3em;border-bottom:1px solid var(--border)}
    h2{font-size:1.5em;padding-bottom:.3em;border-bottom:1px solid var(--border)}
    h3{font-size:1.25em}h4{font-size:1em}h5{font-size:.875em}h6{font-size:.85em;color:var(--muted)}
    p,blockquote,ul,ol,table,pre{margin:0 0 16px}
    a{color:var(--link);text-decoration:none}a:hover{text-decoration:underline}
    strong{font-weight:600}del{color:var(--muted)}
    hr{height:1px;border:0;background:var(--border);margin:24px 0}
    blockquote{padding:0 1em;color:var(--muted);border-left:.25em solid var(--border)}
    blockquote>:last-child{margin-bottom:0}
    ul,ol{padding-left:2em}
    li+li{margin-top:.25em}
    li>ul,li>ol{margin:.25em 0 0}
    li>p{margin:.5em 0}
    .task-list-item{list-style:none}
    .task-list-item input{margin:0 .4em .2em -1.5em;vertical-align:middle}
    code,pre{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace;font-size:85%}
    code{padding:.2em .4em;border-radius:6px;background:var(--code)}
    pre{padding:16px;overflow:auto;line-height:1.45;border-radius:8px;background:var(--subtle)}
    pre code{padding:0;background:none;font-size:100%}
    table{border-collapse:collapse;display:block;width:max-content;max-width:100%;overflow:auto}
    th,td{padding:6px 13px;border:1px solid var(--border)}
    th{font-weight:600}
    tbody tr:nth-child(2n){background:var(--subtle)}
    img{max-width:100%}
    """

    static func esc(_ s: String) -> String {
        var o = ""
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            default: o.append(c)
            }
        }
        return o
    }

    /// Expands leading tabs to 4-column stops; tabs elsewhere are kept.
    static func detab(_ s: String) -> String {
        guard s.contains("\t") else { return s }
        var o = "", col = 0, leading = true
        for c in s {
            if leading, c == "\t" { let n = 4 - col % 4; o += String(repeating: " ", count: n); col += n; continue }
            if c != " " { leading = false }
            o.append(c); col += 1
        }
        return o
    }
}

struct Line {
    var s: String
    let n: Int
    var blank: Bool { s.allSatisfy(\.isWhitespace) }
    var indent: Int { s.prefix { $0 == " " }.count }
    func dropping(_ k: Int) -> Line { Line(s: String(s.dropFirst(min(k, indent))), n: n) }
}

private struct Marker {
    let indent: Int, kind: Character, ordered: Bool, start: Int, content: Int, rest: String
}

private struct Delim {
    let ch: Character, orig: Int
    var count: Int, open: Bool, close: Bool
    var pre: [String] = [], post: [String] = []
}

private enum Node { case html(String), delim(Delim) }

final class Renderer {
    var refs: [String: (url: String, title: String?)] = [:]
    var slugs: [String: Int] = [:]
    typealias M = MarkdownHTML

    // MARK: blocks

    func collectRefs(_ ls: [Line]) {
        var fenceCh: Character?
        for l in ls {
            let s = String(l.s.drop { $0 == " " || $0 == ">" })
            if let f = fence(s) {
                if fenceCh == nil { fenceCh = f.ch } else if f.ch == fenceCh, f.info.isEmpty { fenceCh = nil }
            } else if fenceCh == nil, let d = def(s), refs[d.label] == nil {
                refs[d.label] = (d.url, d.title)
            }
        }
    }

    func blocks(_ ls: [Line], tight: Bool = false) -> String {
        var out: [String] = [], i = 0
        while i < ls.count {
            let l = ls[i], ind = l.indent
            if l.blank { i += 1; continue }
            if ind >= 4 {
                var body: [String] = [], j = i
                while j < ls.count, ls[j].blank || ls[j].indent >= 4 { body.append(String(ls[j].s.dropFirst(4))); j += 1 }
                while body.last?.allSatisfy(\.isWhitespace) == true { body.removeLast() }
                out.append("<pre data-line=\"\(l.n)\"><code>\(M.esc(body.joined(separator: "\n")))\n</code></pre>")
                i = j; continue
            }
            let s = String(l.s.dropFirst(ind))
            if let f = fence(s) {
                var body: [String] = [], j = i + 1
                while j < ls.count {
                    let x = ls[j]
                    if x.indent < 4, let c = fence(String(x.s.dropFirst(x.indent))), c.ch == f.ch, c.len >= f.len, c.info.isEmpty { j += 1; break }
                    body.append(x.dropping(ind).s); j += 1
                }
                let lang = f.info.split(separator: " ").first.map { " class=\"language-\(M.esc(String($0)))\"" } ?? ""
                let code = body.isEmpty ? "" : M.esc(body.joined(separator: "\n")) + "\n"
                out.append("<pre data-line=\"\(l.n)\"><code\(lang)>\(code)</code></pre>")
                i = j; continue
            }
            if let h = atx(s) { out.append(heading(h.0, h.1, l.n)); i += 1; continue }
            if isHR(s) { out.append("<hr data-line=\"\(l.n)\">"); i += 1; continue }
            if s.hasPrefix(">") {
                var inner: [Line] = [], j = i
                while j < ls.count {
                    let x = ls[j], xs = x.s.dropFirst(min(x.indent, 3))
                    if x.indent < 4, xs.hasPrefix(">") {
                        var rest = xs.dropFirst()
                        if rest.first == " " { rest = rest.dropFirst() }
                        inner.append(Line(s: String(rest), n: x.n))
                    } else if !x.blank, inner.last?.blank == false, !interrupts(x.s) {
                        inner.append(x) // lazy continuation
                    } else { break }
                    j += 1
                }
                out.append("<blockquote data-line=\"\(l.n)\">\n\(blocks(inner))\n</blockquote>")
                i = j; continue
            }
            if let m = marker(l.s) { let (html, j) = list(ls, i, m); out.append(html); i = j; continue }
            if isTable(ls, i) { let (html, j) = table(ls, i); out.append(html); i = j; continue }
            if def(s) != nil { i += 1; continue }

            var text: [String] = [], j = i, setext = 0
            while j < ls.count {
                let x = ls[j]
                if x.blank { break }
                if j > i {
                    let t = x.s.trimmingCharacters(in: .whitespaces)
                    if x.indent < 4, let c = t.first, c == "=" || c == "-", t.allSatisfy({ $0 == c }) { setext = c == "=" ? 1 : 2; j += 1; break }
                    if interrupts(x.s) || isTable(ls, j) { break }
                }
                text.append(String(x.s.drop { $0 == " " })); j += 1
            }
            let raw = text.joined(separator: "\n").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if setext > 0 { out.append(heading(setext, raw, l.n)) } else {
                let body = inline(raw)
                if !body.isEmpty { out.append(tight ? body : "<p data-line=\"\(l.n)\">\(body)</p>") }
            }
            i = j
        }
        return out.joined(separator: "\n")
    }

    private func heading(_ level: Int, _ raw: String, _ n: Int) -> String {
        let html = inline(raw)
        var base = ""
        for c in stripTags(html).replacing(/&#?\w+;/, with: "").lowercased() {
            if c.isLetter || c.isNumber || c == "-" || c == "_" { base.append(c) } else if c == " " { base.append("-") }
        }
        let k = slugs[base, default: 0]
        slugs[base] = k + 1
        let id = k == 0 ? base : "\(base)-\(k)"
        return "<h\(level) id=\"\(M.esc(id))\" data-line=\"\(n)\">\(html)</h\(level)>"
    }

    private func list(_ ls: [Line], _ i: Int, _ m0: Marker) -> (String, Int) {
        var items: [(n: Int, body: [Line])] = [], j = i, cur = m0, loose = false
        while true {
            let n = ls[j].n
            var body = [Line(s: cur.rest, n: n)]
            j += 1
            while j < ls.count {
                let x = ls[j]
                if x.blank { body.append(Line(s: "", n: x.n)) }
                else if x.indent >= cur.content { body.append(x.dropping(cur.content)) }
                else if marker(x.s) == nil, body.last?.blank == false, !interrupts(x.s) { body.append(x) } // lazy
                else { break }
                j += 1
            }
            var trailing = 0
            while body.count > 1, body.last?.blank == true { body.removeLast(); trailing += 1 }
            // Limit: blank line followed by an unindented line inside an item counts as loose; fenced code with blank lines can false-positive.
            if zip(body, body.dropFirst()).contains(where: { $0.blank && !$1.blank && $1.indent == 0 }) { loose = true }
            items.append((n, body))
            guard j < ls.count, let nm = marker(ls[j].s), nm.kind == m0.kind,
                  !isHR(String(ls[j].s.dropFirst(ls[j].indent))) else { break }
            if trailing > 0 { loose = true }
            cur = nm
        }
        let tag = m0.ordered ? "ol" : "ul"
        let start = m0.ordered && m0.start != 1 ? " start=\"\(m0.start)\"" : ""
        var html = "<\(tag) data-line=\"\(ls[i].n)\"\(start)>\n"
        for var it in items {
            var box = ""
            let first = it.body[0].s
            if first.hasPrefix("[ ]") || first.hasPrefix("[x]") || first.hasPrefix("[X]"), first.count == 3 || first.dropFirst(3).first == " " {
                box = "<input type=\"checkbox\" disabled\(first.hasPrefix("[ ]") ? "" : " checked")> "
                it.body[0].s = String(first.dropFirst(4))
            }
            var inner = blocks(it.body, tight: !loose)
            if !box.isEmpty {
                if inner.hasPrefix("<p"), let gt = inner.firstIndex(of: ">") { inner.insert(contentsOf: box, at: inner.index(after: gt)) } else { inner = box + inner }
            }
            html += "<li data-line=\"\(it.n)\"\(box.isEmpty ? "" : " class=\"task-list-item\"")>\(inner)</li>\n"
        }
        return (html + "</\(tag)>", j)
    }

    private func cells(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = [], cur = "", prev: Character = " "
        for c in t {
            if c == "|", prev != "\\" { out.append(cur); cur = "" } else if c == "|" { cur.removeLast(); cur.append(c) } else { cur.append(c) }
            prev = c
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func aligns(_ s: String) -> [String]? {
        guard s.contains("|") else { return nil }
        var out: [String] = []
        for c in cells(s) {
            var d = Substring(c)
            if d.first == ":" { d = d.dropFirst() }
            if d.last == ":" { d = d.dropLast() }
            guard !d.isEmpty, d.allSatisfy({ $0 == "-" }) else { return nil }
            out.append(c.hasPrefix(":") && c.hasSuffix(":") ? "center" : c.hasSuffix(":") ? "right" : c.hasPrefix(":") ? "left" : "")
        }
        return out
    }

    private func isTable(_ ls: [Line], _ i: Int) -> Bool {
        guard i + 1 < ls.count, ls[i].indent < 4, ls[i].s.contains("|"), let a = aligns(ls[i + 1].s) else { return false }
        return a.count == cells(ls[i].s).count
    }

    private func table(_ ls: [Line], _ i: Int) -> (String, Int) {
        let al = aligns(ls[i + 1].s) ?? []
        func row(_ l: Line, _ tag: String) -> String {
            let cs = cells(l.s)
            let tds = al.indices.map { k in
                let style = al[k].isEmpty ? "" : " style=\"text-align:\(al[k])\""
                return "<\(tag)\(style)>\(k < cs.count ? inline(cs[k]) : "")</\(tag)>"
            }
            return "<tr data-line=\"\(l.n)\">\(tds.joined())</tr>"
        }
        var html = "<table data-line=\"\(ls[i].n)\">\n<thead>\n\(row(ls[i], "th"))\n</thead>\n"
        var j = i + 2, body: [String] = []
        while j < ls.count, !ls[j].blank, ls[j].s.contains("|"), !interrupts(ls[j].s) { body.append(row(ls[j], "td")); j += 1 }
        if !body.isEmpty { html += "<tbody>\n\(body.joined(separator: "\n"))\n</tbody>\n" }
        return (html + "</table>", j)
    }

    private func fence(_ s: String) -> (ch: Character, len: Int, info: String)? {
        guard let c = s.first, c == "`" || c == "~" else { return nil }
        let len = s.prefix { $0 == c }.count
        let info = s.dropFirst(len).trimmingCharacters(in: .whitespaces)
        guard len >= 3, c == "~" || !info.contains("`") else { return nil }
        return (c, len, info)
    }

    private func atx(_ s: String) -> (Int, String)? {
        let level = s.prefix { $0 == "#" }.count
        let rest = s.dropFirst(level)
        guard (1...6).contains(level), rest.isEmpty || rest.first == " " else { return nil }
        var t = rest.trimmingCharacters(in: .whitespaces)
        if let k = t.lastIndex(where: { $0 != "#" }) {
            if t[k] == " " { t = String(t[...k]).trimmingCharacters(in: .whitespaces) }
        } else { t = "" }
        return (level, t)
    }

    private func isHR(_ s: String) -> Bool {
        guard let c = s.first, "-*_".contains(c) else { return false }
        return s.allSatisfy { $0 == c || $0 == " " || $0 == "\t" } && s.filter { $0 == c }.count >= 3
    }

    private func marker(_ t: String) -> Marker? {
        let ind = t.prefix { $0 == " " }.count
        guard ind < 4 else { return nil }
        let s = Array(t.dropFirst(ind))
        var k = 0, ordered = false, start = 0
        guard let c0 = s.first else { return nil }
        var kind = c0
        if "-*+".contains(c0) { k = 1 } else {
            while k < s.count, k < 9, s[k].isASCII, s[k].isNumber { k += 1 }
            guard k > 0, k < s.count, s[k] == "." || s[k] == ")", let v = Int(String(s[0..<k])) else { return nil }
            kind = s[k]; start = v; ordered = true; k += 1
        }
        guard k == s.count || s[k] == " " else { return nil }
        let sp = s[k...].prefix { $0 == " " }.count
        let rest = String(s[(k + sp)...])
        if rest.isEmpty || sp > 4 {
            return Marker(indent: ind, kind: kind, ordered: ordered, start: start, content: ind + k + 1, rest: rest.isEmpty ? "" : String(s[min(k + 1, s.count)...]))
        }
        return Marker(indent: ind, kind: kind, ordered: ordered, start: start, content: ind + k + sp, rest: rest)
    }

    /// Lines that end a paragraph (and so can't be lazy continuations).
    private func interrupts(_ t: String) -> Bool {
        let ind = t.prefix { $0 == " " }.count
        guard ind < 4 else { return false }
        let s = String(t.dropFirst(ind))
        if fence(s) != nil || atx(s) != nil || isHR(s) || s.hasPrefix(">") { return true }
        if let m = marker(t), !m.rest.isEmpty, !m.ordered || m.start == 1 { return true }
        return false
    }

    private func def(_ s: String) -> (label: String, url: String, title: String?)? {
        guard s.hasPrefix("["), s.contains("]:"), let m = s.wholeMatch(of: /\[([^\]]+)\]:\s*<?([^\s>]+)>?(?:\s+["'(](.*)["')])?\s*/) else { return nil }
        return (norm(String(m.1)), String(m.2), m.3.map(String.init))
    }

    private func norm(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    // MARK: inline

    func inline(_ s: String, links: Bool = true) -> String {
        let c = Array(s)
        var nodes: [Node] = [], buf = "", i = 0
        func flush() { if !buf.isEmpty { nodes.append(.html(buf)); buf = "" } }
        while i < c.count {
            let ch = c[i]
            switch ch {
            case "\\":
                if i + 1 < c.count, c[i + 1] == "\n" { buf += "<br>\n"; i += 2 }
                else if i + 1 < c.count, isASCIIPunct(c[i + 1]) { buf += M.esc(String(c[i + 1])); i += 2 }
                else { buf += "\\"; i += 1 }
            case "`":
                var n = 0
                while i + n < c.count, c[i + n] == "`" { n += 1 }
                var k = i + n, close: Int?
                while k < c.count {
                    guard c[k] == "`" else { k += 1; continue }
                    var m = 0
                    while k + m < c.count, c[k + m] == "`" { m += 1 }
                    if m == n { close = k; break }
                    k += m
                }
                if let f = close {
                    var code = String(c[(i + n)..<f]).replacingOccurrences(of: "\n", with: " ")
                    if code.count >= 2, code.first == " ", code.last == " ", !code.allSatisfy({ $0 == " " }) { code = String(code.dropFirst().dropLast()) }
                    buf += "<code>\(M.esc(code))</code>"; i = f + n
                } else { buf += String(repeating: "`", count: n); i += n }
            case "*", "_", "~":
                var e = i
                while e < c.count, c[e] == ch { e += 1 }
                let run = e - i
                if ch == "~", run > 2 { buf += String(repeating: "~", count: run); i = e; continue }
                let prev: Character = i > 0 ? c[i - 1] : " ", next: Character = e < c.count ? c[e] : " "
                let pw = prev.isWhitespace, nw = next.isWhitespace, pp = isPunct(prev), np = isPunct(next)
                let left = !nw && (!np || pw || pp), right = !pw && (!pp || nw || np)
                flush()
                nodes.append(.delim(Delim(ch: ch, orig: run, count: run,
                                          open: ch == "_" ? left && (!right || pp) : left,
                                          close: ch == "_" ? right && (!left || np) : right)))
                i = e
            case "!" where links && i + 1 < c.count && c[i + 1] == "[":
                if let r = link(c, i, image: true) { buf += r.0; i = r.1 } else { buf += "!"; i += 1 }
            case "[" where links:
                if let r = link(c, i, image: false) { buf += r.0; i = r.1 } else { buf += "["; i += 1 }
            case "<":
                if i + 3 < c.count, c[i + 1] == "!", c[i + 2] == "-", c[i + 3] == "-",
                   let r = String(c[i...]).range(of: "-->") {
                    i += String(c[i...])[..<r.upperBound].count; continue // drop HTML comments
                }
                if links, let close = c[(i + 1)...].firstIndex(of: ">") {
                    let inner = String(c[(i + 1)..<close])
                    if !inner.contains(where: { $0.isWhitespace || $0 == "<" }) {
                        if inner.contains(":"), inner.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]{1,31}:.+/) != nil {
                            buf += "<a href=\"\(M.esc(safe(inner)))\">\(M.esc(inner))</a>"; i = close + 1; continue
                        }
                        if inner.contains("@"), inner.wholeMatch(of: /[^@\s]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)+/) != nil {
                            buf += "<a href=\"mailto:\(M.esc(inner))\">\(M.esc(inner))</a>"; i = close + 1; continue
                        }
                    }
                }
                buf += "&lt;"; i += 1
            case "&":
                var k = i + 1
                while k < c.count, k - i < 33, c[k].isASCII, c[k].isLetter || c[k].isNumber || c[k] == "#" { k += 1 }
                if k < c.count, k > i + 1, c[k] == ";" { buf += String(c[i...k]); i = k + 1 } else { buf += "&amp;"; i += 1 }
            case "\n":
                let hard = buf.hasSuffix("  ")
                while buf.last == " " { buf.removeLast() }
                buf += hard ? "<br>\n" : "\n"; i += 1
            case "h", "w":
                var plen = 0
                if links, i == 0 || c[i - 1].isWhitespace || "(*_~\"'".contains(c[i - 1]) {
                    let head = String(c[i..<min(c.count, i + 8)]).lowercased()
                    plen = head.hasPrefix("https://") ? 8 : head.hasPrefix("http://") ? 7 : head.hasPrefix("www.") ? 4 : 0
                }
                guard plen > 0 else { buf.append(ch); i += 1; continue }
                var e = i
                while e < c.count, !c[e].isWhitespace, !"<>\"`".contains(c[e]) { e += 1 }
                while e > i {
                    let last = c[e - 1]
                    if "?!.,:*_~'\";".contains(last) { e -= 1; continue }
                    if last == ")" {
                        let u = c[i..<e]
                        if u.filter({ $0 == "(" }).count < u.filter({ $0 == ")" }).count { e -= 1; continue }
                    }
                    break
                }
                guard e - i > plen else { buf.append(ch); i += 1; continue }
                let url = String(c[i..<e])
                buf += "<a href=\"\(M.esc(plen == 4 ? "http://" + url : url))\">\(M.esc(url))</a>"; i = e
            case ">": buf += "&gt;"; i += 1
            case "\"": buf += "&quot;"; i += 1
            default: buf.append(ch); i += 1
            }
        }
        flush()
        emphasis(&nodes)
        return nodes.map {
            switch $0 {
            case .html(let h): return h
            case .delim(let d): return d.post.joined() + String(repeating: d.ch, count: d.count) + d.pre.joined()
            }
        }.joined()
    }

    /// CommonMark "process emphasis", minus the openers_bottom optimisation (O(n²) on pathological input).
    private func emphasis(_ nodes: inout [Node]) {
        var i = 0
        while i < nodes.count {
            guard case .delim(var c) = nodes[i], c.close, c.count > 0 else { i += 1; continue }
            var found: Int?
            for j in stride(from: i - 1, through: 0, by: -1) {
                guard case .delim(let o) = nodes[j], o.ch == c.ch, o.open, o.count > 0 else { continue }
                if c.ch == "~" { if o.count == c.count { found = j; break } else { continue } }
                if (o.close || c.open), (o.orig + c.orig) % 3 == 0, !(o.orig % 3 == 0 && c.orig % 3 == 0) { continue }
                found = j; break
            }
            guard let j = found, case .delim(var o) = nodes[j] else { i += 1; continue }
            let n = c.ch == "~" ? c.count : (o.count >= 2 && c.count >= 2 ? 2 : 1)
            let tag = c.ch == "~" ? "del" : n == 2 ? "strong" : "em"
            o.count -= n; c.count -= n
            o.pre.insert("<\(tag)>", at: 0); c.post.append("</\(tag)>")
            nodes[j] = .delim(o); nodes[i] = .delim(c)
            for k in (j + 1)..<i { if case .delim(var d) = nodes[k] { d.open = false; d.close = false; nodes[k] = .delim(d) } }
            if c.count == 0 { i += 1 }
        }
    }

    private func link(_ c: [Character], _ i: Int, image: Bool) -> (String, Int)? {
        let b = image ? i + 1 : i
        var depth = 0, k = b, close: Int?
        while k < c.count {
            if c[k] == "\\" { k += 2; continue }
            if c[k] == "[" { depth += 1 } else if c[k] == "]" { depth -= 1; if depth == 0 { close = k; break } }
            k += 1
        }
        guard let cl = close else { return nil }
        let text = String(c[(b + 1)..<cl])
        var dest: String?, title: String?, end = cl + 1
        if end < c.count, c[end] == "(", let d = destination(c, end + 1) {
            dest = d.0; title = d.1; end = d.2
        } else {
            var label = text, after = end
            if end < c.count, c[end] == "[", let m = c[(end + 1)...].firstIndex(of: "]") {
                let l = String(c[(end + 1)..<m])
                if !l.isEmpty { label = l }
                after = m + 1
            }
            if let r = refs[norm(label)] { dest = r.url; title = r.title; end = after }
        }
        guard let d = dest else { return nil }
        let t = title.map { " title=\"\(M.esc($0))\"" } ?? ""
        let inner = inline(text, links: false)
        if image { return ("<img src=\"\(M.esc(safe(d, image: true)))\" alt=\"\(stripTags(inner))\"\(t)>", end) }
        return ("<a href=\"\(M.esc(safe(d)))\"\(t)>\(inner)</a>", end)
    }

    private func destination(_ c: [Character], _ start: Int) -> (String, String?, Int)? {
        var k = start, d = ""
        func ws() { while k < c.count, c[k] == " " || c[k] == "\n" { k += 1 } }
        ws()
        if k < c.count, c[k] == "<" {
            k += 1
            while k < c.count, c[k] != ">", c[k] != "\n" { d.append(c[k]); k += 1 }
            guard k < c.count, c[k] == ">" else { return nil }
            k += 1
        } else {
            var depth = 0
            while k < c.count, !c[k].isWhitespace {
                if c[k] == "\\", k + 1 < c.count, isASCIIPunct(c[k + 1]) { d.append(c[k + 1]); k += 2; continue }
                if c[k] == "(" { depth += 1 } else if c[k] == ")" { if depth == 0 { break }; depth -= 1 }
                d.append(c[k]); k += 1
            }
        }
        ws()
        var title: String?
        let quotes: [Character: Character] = ["\"": "\"", "'": "'", "(": ")"]
        if k < c.count, let q = quotes[c[k]] {
            var t = ""
            k += 1
            while k < c.count, c[k] != q {
                if c[k] == "\\", k + 1 < c.count { t.append(c[k + 1]); k += 2; continue }
                t.append(c[k]); k += 1
            }
            guard k < c.count else { return nil }
            k += 1; title = t; ws()
        }
        guard k < c.count, c[k] == ")" else { return nil }
        return (d.replacingOccurrences(of: " ", with: "%20"), title, k + 1)
    }

    /// Neutralises script-capable URL schemes.
    private func safe(_ u: String, image: Bool = false) -> String {
        let l = u.lowercased().filter { !$0.isWhitespace && !($0.asciiValue.map { $0 < 32 } ?? false) }
        if l.hasPrefix("javascript:") || l.hasPrefix("vbscript:") || (l.hasPrefix("data:") && !(image && l.hasPrefix("data:image/"))) { return "#" }
        return u
    }

    private func stripTags(_ h: String) -> String {
        var o = "", tag = false
        for c in h { if c == "<" { tag = true } else if c == ">" { tag = false } else if !tag { o.append(c) } }
        return o
    }

    private func isASCIIPunct(_ c: Character) -> Bool { c.isASCII && (c.isPunctuation || c.isSymbol) }
    private func isPunct(_ c: Character) -> Bool { c.isPunctuation || c.isSymbol }
}
