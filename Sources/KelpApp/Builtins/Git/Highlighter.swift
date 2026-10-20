import AppKit
import EditorKit

/// Small regex highlighter for diffs and previews. The editor uses tree-sitter; this only needs to be cheap.
enum Highlighter {
    static let keywords: [String: [String]] = {
        let c = ["if", "else", "for", "while", "return", "break", "continue", "switch", "case", "default", "struct", "class", "enum", "static", "const", "void", "int", "char", "bool", "true", "false", "null", "nil", "new", "this", "self", "import", "include"]
        return [
            "swift": ["func", "let", "var", "guard", "async", "await", "protocol", "extension", "public", "private", "internal", "final", "init", "try", "throws", "in", "where", "some", "actor"] + c,
            "ts": ["function", "const", "let", "var", "async", "await", "export", "import", "from", "interface", "type", "extends", "implements", "undefined", "typeof"] + c,
            "js": ["function", "const", "let", "var", "async", "await", "export", "import", "from", "undefined", "typeof"] + c,
            "py": ["def", "class", "import", "from", "as", "with", "lambda", "yield", "None", "True", "False", "elif", "except", "try", "finally", "raise", "pass", "async", "await", "not", "and", "or", "is", "in"] + c,
            "go": ["func", "package", "import", "var", "type", "interface", "range", "go", "defer", "chan", "map", "select", "fallthrough"] + c,
            "rs": ["fn", "let", "mut", "impl", "trait", "pub", "use", "mod", "match", "loop", "where", "async", "await", "Self", "crate", "move", "ref", "unsafe"] + c,
            "json": ["true", "false", "null"], "yaml": ["true", "false", "null"]
        ]
    }()
    static let alias = ["tsx": "ts", "jsx": "js", "mjs": "js", "yml": "yaml", "py": "py"]

    @MainActor static func attributed(_ s: String, ext: String, font: NSFont) -> NSAttributedString {
        let a = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let lang = alias[ext] ?? ext
        guard let kw = keywords[lang] else { return a }
        func paint(_ pattern: String, _ color: NSColor) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) { a.addAttribute(.foregroundColor, value: color, range: m.range) }
        }
        // The editor theme's colors, so a diff reads like the file it changes.
        let c = CodeEditor.tokenColors
        paint(#"\b(\#(kw.joined(separator: "|")))\b"#, c.keyword)
        paint(#"\b\d+(\.\d+)?\b"#, c.number)
        paint(#""(\\.|[^"\\])*"|'(\\.|[^'\\])*'"#, c.string)
        paint(lang == "py" || lang == "yaml" ? #"#.*$"# : #"//.*$"#, c.comment)
        return a
    }
}
