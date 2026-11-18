import Foundation

/// A `COPY` or `ADD` line's flags and words.
struct CopyArguments {
    var flags: [String: String] = [:]
    /// The sources and the destination, as written (or the elements of the JSON form).
    var tokens: [String] = []
    var isJSON = false

    init(_ arguments: String) {
        var rest = arguments.trimmed
        var words = Substitution.rawWords(rest)
        while let first = words.first, first.hasPrefix("--") {
            let flag = first.dropFirst(2)
            let value = flag.drop { $0 != "=" }.dropFirst()
            flags[flag.prefix { $0 != "=" }.lowercased()] = String(value)
            words.removeFirst()
            rest = rest.dropFirst(first.count).trimmed
        }
        if rest.hasPrefix("["), let array = try? JSONDecoder().decode([String].self, from: Data(rest.utf8)) {
            tokens = array
            isJSON = true
        } else {
            tokens = words
        }
    }

    /// The tokens with variables expanded; `nil` when one depends on a value set at build time.
    func expanded(_ substitution: Substitution) -> [String]? {
        var words: [String] = []
        for token in tokens {
            guard let word = substitution.word(token) else { return nil }
            words.append(word)
        }
        return words
    }
}

extension Walk {
    static let archives = [".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".tar.zst"]

    mutating func copy(_ instruction: DockerfileInstruction, _ substitution: Substitution, _ state: inout StageState) {
        guard !instruction.hasHeredoc else { return }
        let arguments = CopyArguments(instruction.arguments)
        guard arguments.tokens.count >= 2 else { return }
        guard let words = arguments.expanded(substitution), let written = words.last else {
            unknown = unknown ?? "line \(instruction.lineNumber) depends on a value set at build time"
            return
        }
        let sources = Array(words.dropLast())
        // `.` and `..` name directories, but only a trailing `/` lets several sources through the classic builder.
        let slash = written.hasSuffix("/")
        let directorySyntax = slash || written == "." || written == ".."
        let (destination, caveats) = resolve(written, state.workdir)
        let isDirectory = directorySyntax ? true : state.isDirectory(destination)
        state.directories.formUnion(ImagePath.ancestors(destination) + (directorySyntax ? [destination] : []))
        if !directorySyntax { state.written.insert(destination) }
        for (query, inherited) in inputs(arguments, substitution) {
            for source in sources {
                guard let match = SourceMatch.match(source, query) else { continue }
                if let reason = unmodelled(instruction, arguments, source) {
                    unknown = unknown ?? reason
                    continue
                }
                let shape = CopyShape(source: source, destination: destination, isDirectory: isDirectory,
                                      several: sources.count > 1, slash: slash)
                for (target, extra) in targets(match, shape, query: query) {
                    let all = inherited + caveats + extra + (source.contains("**") ? [.doubleStar] : [])
                    state.placements.append(Placement(path: target, lineNumber: instruction.lineNumber, caveats: all))
                }
            }
        }
    }

    /// The destination made absolute: against the `WORKDIR`, or against `/` with a caveat when the base image may
    /// have set one.
    func resolve(_ written: String, _ workdir: String?) -> (String, [PlacementCaveat]) {
        guard !written.hasPrefix("/"), reading != .workdirIgnored else {
            return (ImagePath.resolve(written, against: "/"), [])
        }
        guard let workdir else { return (ImagePath.resolve(written, against: "/"), [.baseImageWorkdir]) }
        return (ImagePath.resolve(written, against: workdir), [])
    }

    /// The paths a `COPY` reads: the followed path from the build context, or wherever an earlier stage put it.
    mutating func inputs(_ arguments: CopyArguments, _ substitution: Substitution) -> [(String, [PlacementCaveat])] {
        guard let from = arguments.flags["from"] else {
            if reading != .ignoresDockerignore, let verdict = model.dockerignore?.verdict(for: path),
               verdict.isExcluded {
                excludedBy = verdict.decidingPattern
                return []
            }
            return [(path, [])]
        }
        guard let name = substitution.word(from)?.lowercased(),
              let index = Int(name) ?? model.stages.firstIndex(where: { $0.name == name }),
              index < finished.count else { return [] }
        return finished[index].placements.map { (ImagePath.relative($0.path), $0.caveats) }
    }

    func unmodelled(_ instruction: DockerfileInstruction, _ arguments: CopyArguments, _ source: String) -> String? {
        if arguments.flags["parents"] != nil || arguments.flags["exclude"] != nil {
            return "line \(instruction.lineNumber) uses --parents or --exclude, which are not modelled"
        }
        if instruction.keyword == "ADD", Self.archives.contains(where: source.lowercased().hasSuffix) {
            return "line \(instruction.lineNumber) adds an archive, which ADD unpacks; not modelled"
        }
        return nil
    }

    func targets(_ match: SourceMatch, _ shape: CopyShape, query: String) -> [(String, [PlacementCaveat])] {
        let isPattern = GoMatch.hasWildcard(shape.source)
        if reading == .globKeepsPath, isPattern { return [(ImagePath.join(shape.destination, query), [])] }
        switch match {
        case .directory(let name, let rest):
            let base = reading == .copiesDirectory
                ? ImagePath.join(shape.destination, name ?? "") : shape.destination
            return [(ImagePath.join(base, rest), [])]
        case .file(let name):
            let inside = ImagePath.join(shape.destination, name)
            if shape.several, !shape.slash { return [(inside, [.classicStops])] }
            let glob: [PlacementCaveat] = isPattern && !shape.slash ? [.globMatchesOne] : []
            switch shape.isDirectory {
            case true?:
                return [(inside, glob)]
            case false?:
                return [(reading == .destinationIsDirectory ? inside : shape.destination, glob)]
            case nil:
                // A destination named like a file (`default.conf`, or the source's own name) is taken as one.
                let last = ImagePath.lastName(shape.destination)
                if last.contains(".") || last == name { return [(shape.destination, glob)] }
                return [(shape.destination, glob + [.renamedUnlessDirectory(shape.destination)]),
                        (inside, glob + [.insideIfDirectory(shape.destination)])]
            }
        }
    }
}

/// What a `COPY` line looks like once expanded.
struct CopyShape {
    let source: String
    let destination: String
    let isDirectory: Bool?
    let several: Bool
    let slash: Bool
}
