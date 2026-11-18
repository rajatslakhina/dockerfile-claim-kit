/// A Dockerfile shown in an answer.
struct DockerfileBlock {
    /// Counting from 1, in the order the answer shows them.
    let number: Int
    /// The block's index among the answer's blocks.
    let position: Int
    let dockerfile: Dockerfile

    static func isDockerfile(_ block: AnswerBlock) -> Bool {
        guard case .code(let tag) = block.kind else { return false }
        if ["dockerfile", "containerfile", "docker"].contains(tag) { return true }
        return tag.isEmpty && Dockerfile.looksLikeDockerfile(block.lines.joined(separator: "\n"))
    }

    static func find(in blocks: [AnswerBlock]) -> [DockerfileBlock] {
        blocks.enumerated().filter { isDockerfile($0.element) }.enumerated().map { number, item in
            DockerfileBlock(number: number + 1, position: item.offset,
                            dockerfile: Dockerfile(item.element.lines.joined(separator: "\n")))
        }
    }

    /// The answer's .dockerignore: a block tagged `dockerignore`, or a plain block right after prose that names it.
    static func dockerignore(in blocks: [AnswerBlock]) -> String? {
        for (index, block) in blocks.enumerated() {
            guard case .code(let tag) = block.kind, !isDockerfile(block) else { continue }
            let named = index > 0 && blocks[index - 1].lines.joined(separator: " ").folded.contains(".dockerignore")
            if tag == "dockerignore" || (["", "text", "gitignore"].contains(tag) && named) {
                return block.lines.joined(separator: "\n")
            }
        }
        return nil
    }
}

/// The last Dockerfile (and .dockerignore) a conversation showed.
struct Earlier: Sendable {
    let dockerfile: Dockerfile
    let dockerignore: String?
}

/// Finds everything an answer says about how Docker reads a Dockerfile: in its prose, and in the Dockerfiles it shows.
public struct DockerfileClaimReader: Sendable {
    /// Whether the lines of the answer's Dockerfiles count as claims of their own.
    public let checksLines: Bool

    public init(checksLines: Bool = true) {
        self.checksLines = checksLines
    }

    /// Whether the text talks about a Dockerfile: it names one, or shows one.
    public static func isAboutDockerfile(_ text: String) -> Bool {
        let folded = text.folded
        return folded.contains("dockerfile") || folded.contains("containerfile")
            || AnswerBlocks.split(text).contains(where: DockerfileBlock.isDockerfile)
    }

    /// The claims in an answer. `context` is other text from the conversation (the question it answers). Nothing is
    /// read unless one of them talks about a Dockerfile.
    public func claims(in text: String, context: String = "") -> [DockerfileClaim] {
        guard Self.isAboutDockerfile(text) || Self.isAboutDockerfile(context) else { return [] }
        return allClaims(in: text, context: context)
    }

    /// `earlier` is a Dockerfile from an earlier turn of the conversation, used when this answer shows none.
    func allClaims(in text: String, context: String, earlier: Earlier? = nil) -> [DockerfileClaim] {
        let blocks = AnswerBlocks.split(text)
        let shown = DockerfileBlock.find(in: blocks)
        let remembered = earlier.map { [DockerfileBlock(number: 0, position: -1, dockerfile: $0.dockerfile)] } ?? []
        let files = shown.isEmpty ? remembered : shown
        let ignore = DockerfileBlock.dockerignore(in: blocks) ?? earlier?.dockerignore
        let neighbours = Lexicon.neighbours.contains { (text + "\n" + context).folded.contains($0) }
        var claims: [DockerfileClaim] = []
        if checksLines {
            claims += shown.flatMap { LineChecks.claims(in: $0.dockerfile, block: $0.number, dockerignore: ignore) }
        }
        for (position, block) in blocks.enumerated() where block.kind == .prose {
            let file = files.last { $0.position < position } ?? files.first
            let source = file.map { DockerfileClaim.Source.dockerfile($0.number) } ?? .sentence
            let reader = PlacementReader(dockerfile: file?.dockerfile, source: source, dockerignore: ignore)
            for sentence in Sentences.split(block.lines) where Self.isOurs(sentence, neighbours) {
                claims += StatementReader.claims(in: sentence, dockerfile: file?.dockerfile ?? Dockerfile(""))
                claims += reader.claims(in: sentence)
            }
        }
        return Self.deduplicated(claims)
    }

    /// A sentence about a .dockerignore, another copy tool or another file is left alone; when the conversation
    /// also talks about such files, only sentences that name the Dockerfile or one of its instructions are read.
    static func isOurs(_ sentence: String, _ neighbours: Bool) -> Bool {
        let folded = sentence.folded
        if folded.contains("dockerignore") || Words.containsAny(folded, Lexicon.otherTools) { return false }
        return !neighbours || folded.contains("dockerfile") || Words.containsAny(sentence, Lexicon.keywords)
    }

    /// One claim per kind, subject, target and assertion; a sentence restating what a line implies replaces it.
    static func deduplicated(_ claims: [DockerfileClaim]) -> [DockerfileClaim] {
        let stated = Set(claims.filter(\.isExplicit).map(\.key))
        var seen: Set<String> = []
        return claims.filter { ($0.isExplicit || !stated.contains($0.key)) && seen.insert($0.key).inserted }
    }
}
