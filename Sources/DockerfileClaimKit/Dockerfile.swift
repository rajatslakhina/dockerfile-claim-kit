import Foundation

/// One instruction of a Dockerfile, with its continuation lines joined.
public struct DockerfileInstruction: Sendable, Hashable {
    /// The instruction's name in capitals: `FROM`, `COPY`, `RUN`, ...
    public let keyword: String
    /// Everything after the name, continuation lines joined.
    public let arguments: String
    /// The line the instruction starts on, counting from 1.
    public let lineNumber: Int
    /// Whether the instruction carries a heredoc (`RUN <<EOF`); its body is skipped and not modelled.
    public let hasHeredoc: Bool

    public var text: String {
        arguments.isEmpty ? keyword : keyword + " " + arguments
    }
}

/// A Dockerfile read the way Docker's parser reads it: comment lines dropped, continuation lines joined, the
/// `# escape=` directive honoured.
public struct Dockerfile: Sendable, Hashable {
    static let keywords: Set<String> = ["FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD", "COPY",
                                        "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL",
                                        "HEALTHCHECK", "SHELL"]

    public let text: String
    public let instructions: [DockerfileInstruction]
    /// The character that continues a line: `\` unless the file starts with `# escape=` and a backtick.
    public let escape: Character

    public init(_ text: String) {
        self.text = text
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let escape = Self.escapeDirective(lines)
        self.escape = escape
        var instructions: [DockerfileInstruction] = []
        var index = 0
        while index < lines.count {
            let number = index + 1
            var joined = lines[index].trimmed
            index += 1
            if joined.isEmpty || joined.hasPrefix("#") { continue }
            while joined.last == escape, index < lines.count {
                joined.removeLast()
                let next = lines[index]
                index += 1
                let trimmedNext = next.trimmed
                if trimmedNext.isEmpty || trimmedNext.hasPrefix("#") { joined.append(escape); continue }
                joined += next.trimmingCharacters(in: .whitespaces)
            }
            let keyword = String(joined.prefix { !$0.isWhitespace }).uppercased()
            let arguments = String(joined.drop { !$0.isWhitespace }).trimmed
            let terminator = Self.heredocTerminator(arguments)
            if let terminator {
                while index < lines.count, lines[index].trimmed != terminator { index += 1 }
                index += 1
            }
            instructions.append(DockerfileInstruction(keyword: keyword, arguments: arguments, lineNumber: number,
                                                      hasHeredoc: terminator != nil))
        }
        self.instructions = instructions
    }

    /// Whether a code block reads as a Dockerfile: it starts with `FROM` (or `ARG` lines and then `FROM`) and most
    /// of its lines are Dockerfile instructions.
    public static func looksLikeDockerfile(_ text: String) -> Bool {
        let keywords = Dockerfile(text).instructions.map(\.keyword)
        guard let first = keywords.first(where: { $0 != "ARG" }), first == "FROM" else { return false }
        return keywords.filter(Self.keywords.contains).count * 2 >= keywords.count
    }

    /// `# escape=\`` among the parser directives at the top of the file switches the continuation character.
    static func escapeDirective(_ lines: [String]) -> Character {
        for line in lines {
            let trimmed = line.trimmed
            guard trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { break }
            let key = trimmed[trimmed.index(after: trimmed.startIndex)..<equals].trimmed.lowercased()
            let value = trimmed[trimmed.index(after: equals)...].trimmed
            if key == "escape", value == "`" { return "`" }
        }
        return "\\"
    }

    /// The word that ends a heredoc opened by `<<EOF`, `<<-EOF` or `<<"EOF"`.
    static func heredocTerminator(_ arguments: String) -> String? {
        guard let range = arguments.range(of: "<<") else { return nil }
        let rest = arguments[range.upperBound...].drop { "-\"'".contains($0) }
        let word = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return word.isEmpty ? nil : String(word)
    }
}
