/// A variable's value while a Dockerfile is read.
enum VariableValue: Sendable, Hashable {
    case text(String)
    /// Not set: expands to nothing.
    case unset
    /// Set somewhere this model cannot see: a `--build-arg`, or the base image's own `ENV`.
    case unknown
}

/// Docker's word processing for Dockerfile instructions: `$NAME`, `${NAME}`, `${NAME:-word}`, `${NAME:+word}`,
/// `${NAME-word}`, `${NAME+word}`, quotes and the escape character. `nil` means the result depends on a value this
/// model cannot see, or on a form it does not model (`${NAME#pattern}` and the like).
struct Substitution {
    let lookup: (String) -> VariableValue
    let escape: Character

    init(escape: Character = "\\", lookup: @escaping (String) -> VariableValue) {
        self.escape = escape
        self.lookup = lookup
    }

    /// The text as one word, quotes removed and variables expanded.
    func word(_ text: String) -> String? {
        guard let words = words(text, splitting: false) else { return nil }
        return words.first ?? ""
    }

    /// The text split into words at unquoted whitespace, each expanded.
    func words(_ text: String, splitting: Bool = true) -> [String]? {
        var reader = Reader(Array(text))
        var words: [String] = []
        var current = ""
        var started = false
        while let character = reader.next() {
            if splitting, character.isWhitespace {
                if started { words.append(current) }
                current = ""
                started = false
                continue
            }
            started = true
            guard let piece = piece(character, &reader) else { return nil }
            current += piece
        }
        if started { words.append(current) }
        return words
    }

    /// What one character outside double quotes (and what it opens) adds to the word; `nil` when it is unknown.
    func piece(_ character: Character, _ reader: inout Reader) -> String? {
        switch character {
        case escape:
            return reader.next().map(String.init) ?? ""
        case "'":
            defer { _ = reader.next() }
            return reader.take { $0 != "'" }
        case "\"":
            return doubleQuoted(&reader)
        case "$":
            return variable(&reader)
        default:
            return String(character)
        }
    }

    func doubleQuoted(_ reader: inout Reader) -> String? {
        var result = ""
        while let character = reader.next(), character != "\"" {
            if character == escape, let next = reader.peek(), "\"$".contains(next) || next == escape {
                _ = reader.next()
                result.append(next)
            } else if character == "$" {
                guard let value = variable(&reader) else { return nil }
                result += value
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// The value of the variable starting after a `$`; a `$` not followed by a name stays as it is.
    func variable(_ reader: inout Reader) -> String? {
        guard let next = reader.peek() else { return "$" }
        if next == "{" {
            _ = reader.next()
            return braced(&reader)
        }
        guard next.isLetter || next == "_" else { return "$" }
        return value(of: reader.take { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    func braced(_ reader: inout Reader) -> String? {
        let name = reader.take { $0.isLetter || $0.isNumber || $0 == "_" }
        var modifier = ""
        if reader.peek() == ":" {
            _ = reader.next()
            modifier = ":"
        }
        guard let mark = reader.next() else { return nil }
        if mark == "}" { return modifier.isEmpty ? value(of: name) : nil }
        guard "-+".contains(mark) else { return nil }
        modifier.append(mark)
        let word = reader.take { $0 != "}" }
        _ = reader.next()
        let current = lookup(name)
        if current == .unknown { return nil }
        let isSet = current != .unset
        let isEmpty = current == .unset || current == .text("")
        let useWord = switch modifier {
        case ":-": isEmpty
        case "-": !isSet
        case ":+": !isEmpty
        default: isSet
        }
        guard useWord else { return modifier.hasSuffix("-") ? value(of: name) : "" }
        return Substitution(escape: escape, lookup: lookup).word(word)
    }

    func value(of name: String) -> String? {
        switch lookup(name) {
        case .text(let value): value
        case .unset: ""
        case .unknown: nil
        }
    }

    /// The text split at unquoted whitespace, quotes and escapes kept as written.
    static func rawWords(_ text: String, escape: Character = "\\") -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var reader = Reader(Array(text))
        while let character = reader.next() {
            if quote == nil, character.isWhitespace {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            current.append(character)
            if character == escape, let next = reader.next() {
                current.append(next)
            } else if character == quote {
                quote = nil
            } else if quote == nil, character == "\"" || character == "'" {
                quote = character
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The names a piece of text refers to with `$NAME` or `${NAME...}`, outside single quotes and escapes.
    static func references(in text: String, escape: Character = "\\") -> [String] {
        var reader = Reader(Array(text))
        var names: [String] = []
        var inDouble = false
        while let character = reader.next() {
            if character == escape {
                _ = reader.next()
            } else if character == "\"" {
                inDouble.toggle()
            } else if character == "'", !inDouble {
                _ = reader.take { $0 != "'" }
                _ = reader.next()
            } else if character == "$" {
                if reader.peek() == "{" { _ = reader.next() }
                let name = reader.take { $0.isLetter || $0.isNumber || $0 == "_" }
                if let first = name.first, first.isLetter || first == "_" { names.append(name) }
            }
        }
        return names
    }
}

/// Reads characters one at a time.
struct Reader {
    let characters: [Character]
    var position = 0

    init(_ characters: [Character]) {
        self.characters = characters
    }

    func peek() -> Character? {
        position < characters.count ? characters[position] : nil
    }

    mutating func next() -> Character? {
        defer { position += 1 }
        return peek()
    }

    /// The characters while `condition` holds, consumed.
    mutating func take(while condition: (Character) -> Bool) -> String {
        var result = ""
        while let character = peek(), condition(character) {
            result.append(character)
            position += 1
        }
        return result
    }
}
