/// Reads what a sentence says about where a file ends up: "`src/index.js` lands at `/app/index.js`", "you get
/// `/app/src/index.js`".
struct PlacementReader {
    /// The Dockerfile the sentence is about: the answer's, unless the sentence quotes a `COPY` line of its own.
    let dockerfile: Dockerfile?
    let source: DockerfileClaim.Source
    let dockerignore: String?

    func claims(in sentence: String) -> [DockerfileClaim] {
        guard !sentence.hasSuffix("?") else { return [] }
        let pieces = Sentences.pieces(sentence)
        let own = pieces.first { $0.isCode && ["COPY ", "ADD "].contains(where: $0.text.trimmed.hasPrefix) }?
            .text.trimmed
        // A quoted line the answer's Dockerfile does not have stands alone, on a base image the model cannot see.
        let quoted = own.flatMap { line in Self.contains(dockerfile, line) ? nil : line }
        guard let file = quoted.map({ Dockerfile("FROM base-image\n" + $0) }) ?? dockerfile else { return [] }
        let origin = quoted == nil ? source : .sentence
        let sources = Set(DockerfileEvaluator.sources(DockerfileModel(file)))
        var claims: [DockerfileClaim] = []
        var pending: (index: Int, path: String)?
        var resultSaid = false
        for index in pieces.indices {
            let piece = pieces[index]
            guard piece.isCode else {
                resultSaid = resultSaid || Words.containsAny(piece.text.folded, Lexicon.resultVerbs)
                continue
            }
            let text = piece.text.trimmed
            let lead = index > 0 ? pieces[index - 1].text.folded : ""
            if text != own, Self.isContextPath(text) || sources.contains(text) {
                pending = Self.isContrasted(lead) ? nil : (index, text)
                continue
            }
            guard Self.isImagePath(text) else {
                pending = nil  // another code span (a command, a name) ends the pairing
                continue
            }
            guard !Self.isContrasted(lead) else { continue }
            let before = pieces[..<index].filter { !$0.isCode }.map(\.text.folded).joined(separator: " ")
            if let (start, path) = pending, Words.containsAny(before, Lexicon.placementVerbs) {
                pending = nil
                let between = pieces[(start + 1)..<index].map(\.text.folded).joined(separator: " ")
                guard !Words.containsAny(between, Lexicon.negations),
                      !Lexicon.clauseBreaks.contains(where: between.contains),
                      let target = Self.target(text, after: lead, source: path) else { continue }
                claims.append(claim(path, target, sentence, file, origin))
            } else if resultSaid, !Words.containsAny(lead, Lexicon.negations), !Words.contains(sentence, "WORKDIR") {
                // A sentence about `WORKDIR` names the directory it makes, not where a file lands.
                claims.append(claim("", ImagePath.clean(text), sentence, file, origin))
            }
        }
        return claims
    }

    func claim(_ subject: String, _ target: String, _ sentence: String, _ file: Dockerfile,
               _ origin: DockerfileClaim.Source) -> DockerfileClaim {
        DockerfileClaim(kind: .placement, subject: subject, target: target, assertion: .landsAt, sentence: sentence,
                        source: origin, dockerfile: file, dockerignore: origin == .sentence ? nil : dockerignore)
    }

    static func contains(_ dockerfile: Dockerfile?, _ line: String) -> Bool {
        let wanted = Dockerfile(line).instructions.first?.text
        return dockerfile?.instructions.contains { $0.text == wanted } ?? false
    }

    /// The image path a sentence means: "in `/app`" puts a file inside it; "at `/app/`" names the directory.
    static func target(_ text: String, after lead: String, source: String) -> String? {
        let preposition = String(lead.trimmed.reversed().prefix { $0 != " " }.reversed())
        let name = ImagePath.lastName(source)
        let path = ImagePath.clean(text)
        guard ["in", "into", "inside", "under", "within"].contains(preposition) else {
            if isDirectory(source) { return path }
            if text.hasSuffix("/") { return ImagePath.join(path, name) }
            // "`package.json` goes to `/app`" may mean into it or renamed to it: not judged.
            let last = ImagePath.lastName(path)
            return last.contains(".") || last == name ? path : nil
        }
        guard !isDirectory(source) else { return nil }
        return path.hasSuffix("/" + name) ? path : ImagePath.join(path, name)
    }

    /// Whether a build-context path names a directory: a trailing `/`, `.`, or a last part with no extension
    /// that is not a well-known file name.
    static func isDirectory(_ path: String) -> Bool {
        if path.hasSuffix("/") || path == "." { return true }
        let last = ImagePath.lastName(path)
        return !last.contains(".") && !Lexicon.extensionless.contains(last)
    }

    static func isImagePath(_ text: String) -> Bool {
        text.hasPrefix("/") && text.count > 1 && !text.hasPrefix("//") && !text.contains(where: \.isWhitespace)
            && !text.contains("://") && !text.contains("$")
    }

    /// A relative path with a folder or an extension: `src/index.js`, `package.json`, `src/`.
    static func isContextPath(_ text: String) -> Bool {
        guard !text.hasPrefix("-"), !text.hasPrefix("/"), text.contains(where: { $0.isLetter || $0.isNumber }),
              text.allSatisfy({ $0.isLetter || $0.isNumber || "._-/@+".contains($0) }) else { return false }
        return text.contains("/") || text.contains(".")
    }

    /// Introduced as the thing not meant: "not `/app/src`", "rather than `/app/src/index.js`".
    static func isContrasted(_ lead: String) -> Bool {
        let words = lead.trimmed.split(separator: " ").suffix(3).joined(separator: " ")
        return Lexicon.contrasts.contains { words == $0 || words.hasSuffix(" " + $0) }
    }
}
