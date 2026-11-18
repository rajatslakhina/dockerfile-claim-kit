import Foundation

/// What a stage is built on.
enum StageBase: Sendable, Hashable {
    case scratch
    /// An earlier stage of the same Dockerfile, by index.
    case stage(Int)
    /// An image this model cannot look inside.
    case image(String)
}

/// One `FROM` and the instructions after it.
struct Stage: Sendable, Hashable {
    let index: Int
    /// The `AS` name, lowercased.
    let name: String?
    let base: StageBase
    let from: DockerfileInstruction
    var body: [DockerfileInstruction] = []

    /// The stages a Dockerfile declares, and the `ARG` values declared before the first `FROM`.
    static func split(_ dockerfile: Dockerfile) -> (stages: [Stage], globals: [String: VariableValue]) {
        var stages: [Stage] = []
        var globals: [String: VariableValue] = [:]
        for instruction in dockerfile.instructions {
            if instruction.keyword == "FROM" {
                let substitution = Substitution(escape: dockerfile.escape) { globals[$0] ?? .unset }
                stages.append(Stage.from(instruction, index: stages.count, earlier: stages, substitution))
            } else if stages.isEmpty {
                guard instruction.keyword == "ARG" else { continue }
                let substitution = Substitution(escape: dockerfile.escape) { globals[$0] ?? .unset }
                for (name, value) in Declarations.args(instruction.arguments, substitution) {
                    globals[name] = value ?? .unknown
                }
            } else {
                stages[stages.count - 1].body.append(instruction)
            }
        }
        return (stages, globals)
    }

    static func from(_ instruction: DockerfileInstruction, index: Int, earlier: [Stage],
                     _ substitution: Substitution) -> Stage {
        let words = Substitution.rawWords(instruction.arguments).filter { !$0.hasPrefix("--") }
        let image = words.first.flatMap(substitution.word) ?? ""
        let name = words.count >= 3 && words[1].lowercased() == "as" ? words[2].lowercased() : nil
        let base: StageBase
        if image.lowercased() == "scratch" {
            base = .scratch
        } else if let match = earlier.last(where: { $0.name == image.lowercased() }) {
            base = .stage(match.index)
        } else {
            base = .image(image)
        }
        return Stage(index: index, name: name, base: base, from: instruction)
    }

    /// The stages this one is built on, nearest first.
    func ancestors(in stages: [Stage]) -> [Stage] {
        guard case .stage(let index) = base else { return [] }
        return [stages[index]] + stages[index].ancestors(in: stages)
    }

    /// Whether the stage starts from an image this model cannot see.
    func isOpen(in stages: [Stage]) -> Bool {
        let root = ancestors(in: stages).last ?? self
        if case .image = root.base { return true }
        return false
    }
}

/// `ARG` and `ENV` declarations.
enum Declarations {
    /// `ARG NAME`, `ARG NAME=default`, several per line; the default expanded.
    static func args(_ arguments: String, _ substitution: Substitution) -> [(String, VariableValue?)] {
        Substitution.rawWords(arguments).map { word in
            guard let equals = word.firstIndex(of: "=") else { return (word, nil) }
            let value = substitution.word(String(word[word.index(after: equals)...]))
            return (String(word[..<equals]), value.map(VariableValue.text) ?? .unknown)
        }
    }

    /// `ENV NAME=value ...`, or the older `ENV NAME value with spaces`; every value is expanded with the variables
    /// as they were before the instruction.
    static func env(_ arguments: String, _ substitution: Substitution) -> [(String, VariableValue)] {
        let words = Substitution.rawWords(arguments)
        guard let first = words.first else { return [] }
        guard first.contains("=") else {
            let rest = arguments.trimmed.dropFirst(first.count).trimmed
            return [(first, substitution.word(rest).map(VariableValue.text) ?? .unknown)]
        }
        return words.compactMap { word in
            guard let equals = word.firstIndex(of: "=") else { return nil }
            let value = substitution.word(String(word[word.index(after: equals)...]))
            return (String(word[..<equals]), value.map(VariableValue.text) ?? .unknown)
        }
    }

    /// The names an instruction declares.
    static func names(_ instruction: DockerfileInstruction) -> [String] {
        let substitution = Substitution { _ in .unset }
        switch instruction.keyword {
        case "ARG": return args(instruction.arguments, substitution).map(\.0)
        case "ENV": return env(instruction.arguments, substitution).map(\.0)
        default: return []
        }
    }
}

/// Absolute image paths.
enum ImagePath {
    /// `path` made absolute against `directory` and cleaned the way Go's `filepath.Clean` does.
    static func resolve(_ path: String, against directory: String) -> String {
        clean(path.hasPrefix("/") ? path : directory + "/" + path)
    }

    static func clean(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func join(_ directory: String, _ name: String) -> String {
        if name.isEmpty { return directory }
        return directory == "/" ? "/" + name : directory + "/" + name
    }

    /// Every directory above `path`: `/a/b/c` gives `/`, `/a`, `/a/b`.
    static func ancestors(_ path: String) -> [String] {
        let parts = path.split(separator: "/").dropLast()
        return parts.indices.reduce(into: ["/"]) { result, index in
            result.append("/" + parts[...index].joined(separator: "/"))
        }
    }

    /// The last part of a path: `src/index.js` gives `index.js`, `src/` gives `src`.
    static func lastName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return String(trimmed.reversed().prefix { $0 != "/" }.reversed())
    }

    /// A path in the build context (or in a stage, for `COPY --from`): no `./`, no leading or trailing `/`.
    static func relative(_ path: String) -> String {
        String(clean(path).dropFirst())
    }
}
