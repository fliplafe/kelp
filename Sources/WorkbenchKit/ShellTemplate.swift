import Foundation
import Core

/// `${name}` placeholders in a shell command. `fill` never puts a value into the command's text: each one is assigned
/// to a shell variable first (as one single-quoted word, at the top level where that is always right) and the
/// placeholder becomes a reference to it, so a value with $(…), quotes or a newline stays data whatever surrounds it.
public enum ShellTemplate {
    /// `value(name)` nil: the placeholder stays as written (the shell's own `${HOME}`).
    public static func fill(_ template: String, _ value: (String) -> String?) -> String {
        var assign: [String] = [], out = "", rest = Substring(template), quotes = ShellQuotes()
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            out += rest[..<open.lowerBound]; quotes.read(rest[..<open.lowerBound])
            if let v = value(String(rest[open.upperBound..<close])) {
                let name = "KELP_V\(assign.count + 1)"
                assign.append("\(name)=\(IDE.shellWord(v))")
                out += quotes.reference(name); quotes.inserted()
            } else {
                out += rest[open.lowerBound...close]; quotes.read(rest[open.lowerBound...close])
            }
            rest = rest[rest.index(after: close)...]
        }
        return assign.isEmpty ? out + rest : assign.joined(separator: "; ") + "; " + out + rest
    }

    /// Plain text (a title, a prompt): values put in as they are.
    public static func substitute(_ template: String, _ value: (String) -> String) -> String {
        var out = "", rest = Substring(template)
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            out += rest[..<open.lowerBound] + value(String(rest[open.upperBound..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}

/// Where a shell would be at this point of a template (inside quotes, a comment, a here-document). Only decides how a
/// variable reference is written; a wrong guess garbles the text, it can't make a value run.
struct ShellQuotes {
    var inSingle = false, inDouble = false, inComment = false
    /// A here-document's end word once `<<WORD` was read; `expands`: unquoted WORD, so $(…) inside it runs.
    var pendingDoc: (word: String, expands: Bool)?, inDoc: (word: String, expands: Bool)?
    private var line = "", last: Character = "\n", outer: [(Bool, Bool)] = []

    mutating func read(_ s: Substring) {
        var escaped = false, i = s.startIndex
        while i < s.endIndex {
            let c = s[i]; defer { last = c; i = s.index(after: i) }
            if c == "\n" {
                if let d = inDoc, line.trimmingCharacters(in: .whitespaces) == d.word { inDoc = nil }
                else if inDoc == nil, let p = pendingDoc { inDoc = p; pendingDoc = nil }
                inComment = false; line = ""; escaped = false; continue
            }
            line.append(c)
            if inDoc != nil || inComment { continue }
            if escaped { escaped = false; continue }
            if c == "\\", !inSingle { escaped = true; continue }
            if c == "#", !inSingle, !inDouble, last == " " || last == "\t" || last == "\n" || last == ";" { inComment = true; continue }
            if c == "$", !inSingle, s[i...].dropFirst().first == "(" {   // $(…) starts unquoted, whatever is around it
                outer.append((inSingle, inDouble)); inDouble = false; i = s.index(after: i); continue
            }
            if c == ")", !inSingle, !inDouble, let o = outer.popLast() { (inSingle, inDouble) = o; continue }
            if c == "'", !inDouble { inSingle.toggle() } else if c == "\"", !inSingle { inDouble.toggle() }
            if c == "<", !inSingle, !inDouble, s[i...].hasPrefix("<<"), !s[i...].hasPrefix("<<<") {
                var rest = s[s.index(i, offsetBy: 2)...].drop { $0 == "-" || $0 == " " }
                let quoted = rest.first == "'" || rest.first == "\""
                if quoted { rest = rest.dropFirst() }
                let word = String(rest.prefix { !" \t\n'\";<>|&".contains($0) })
                if !word.isEmpty { pendingDoc = (word, !quoted) }
                i = s.index(after: i)   // the second <
            }
        }
    }

    /// `name`'s value as this spot needs it: bare it gets quotes, in '…' they close around it, in "…" or a here-document
    /// it goes in as is.
    func reference(_ name: String) -> String {
        if inDoc != nil || inComment || inDouble { return "${\(name)}" }
        return inSingle ? "'\"${\(name)}\"'" : "\"${\(name)}\""
    }

    mutating func inserted() { last = "x" }   // a value just went in: a # right after it doesn't start a comment
}
