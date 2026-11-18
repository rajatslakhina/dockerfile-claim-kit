import Foundation

/// What a statement says, before it becomes a claim.
struct Statement {
    let kind: DockerfileClaim.Kind
    let subject: String
    let assertion: DockerfileClaim.Assertion

    init(_ kind: DockerfileClaim.Kind, _ subject: String, _ assertion: DockerfileClaim.Assertion) {
        self.kind = kind
        self.subject = subject
        self.assertion = assertion
    }
}

/// Reads general statements about Dockerfile rules: `RUN cd`, `ARG` before `FROM`, values across stages, `ARG` at
/// run time, `WORKDIR` and directories, and `COPY` of a directory.
enum StatementReader {
    static func claims(in sentence: String, dockerfile: Dockerfile = Dockerfile("")) -> [DockerfileClaim] {
        guard !sentence.hasSuffix("?") else { return [] }
        let plain = sentence.folded.replacingOccurrences(of: "`", with: "")
        let spans = Sentences.pieces(sentence).filter(\.isCode).map { $0.text.trimmed }
        let found: [Statement?] = [
            runCd(sentence, plain, spans), argBeforeFrom(sentence, plain, spans), stageScope(sentence, plain, spans),
            argAtRuntime(sentence, plain, spans), workdir(sentence, plain), directoryCopy(sentence, plain, spans)
        ]
        return found.compactMap { $0 }.map {
            DockerfileClaim(kind: $0.kind, subject: $0.subject, assertion: $0.assertion, sentence: sentence,
                            dockerfile: dockerfile)
        }
    }

    static func negated(_ plain: String) -> Bool {
        Words.containsAny(plain, ["not", "never", "cannot"]) || plain.contains("n't")
    }

    /// The variable a sentence names: `ARG VERSION`, `$VERSION`, `${VERSION}` or a bare `VERSION` span.
    static func variable(_ spans: [String], after keyword: String) -> String? {
        for span in spans {
            let words = span.split(separator: " ").map(String.init)
            if words.count >= 2, words[0] == keyword {
                return String(words[1].prefix { $0 != "=" })
            }
            let name = span.trimmingCharacters(in: CharacterSet(charactersIn: "${}"))
            if !name.isEmpty, name.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }),
               name.first?.isLetter == true, !Lexicon.keywords.contains(name) {
                return name
            }
        }
        return nil
    }

    static func runCd(_ sentence: String, _ plain: String,
                      _ spans: [String]) -> Statement? {
        guard sentence.contains("RUN cd") else { return nil }
        let lead = plain.components(separatedBy: "run cd")[0]
        guard !Words.containsAny(lead, Lexicon.contrasts) else { return nil }
        let directory = spans.first { $0.hasPrefix("RUN cd ") }.map { String($0.dropFirst(7)).trimmed } ?? ""
        let subject = String(directory.prefix { !$0.isWhitespace })
        if Words.containsAny(plain, Lexicon.lastsOneRun) { return Statement(.runCd, subject, .doesNotPersist) }
        return Words.containsAny(plain, Lexicon.later) ? Statement(.runCd, subject, .persists) : nil
    }

    static func argBeforeFrom(_ sentence: String, _ plain: String,
                              _ spans: [String]) -> Statement? {
        guard Words.contains(sentence, "ARG"), Words.contains(sentence, "FROM"),
              Words.containsAny(plain, Lexicon.before) else { return nil }
        let subject = variable(spans, after: "ARG") ?? "ARG"
        if Words.containsAny(plain, Lexicon.outOfStage) { return Statement(.argBeforeFrom, subject, .notAvailable) }
        guard Words.containsAny(plain, Lexicon.usable), Words.containsAny(plain, Lexicon.inStage) else { return nil }
        return Statement(.argBeforeFrom, subject, .available)
    }

    static func stageScope(_ sentence: String, _ plain: String,
                           _ spans: [String]) -> Statement? {
        let keyword = Words.contains(sentence, "ARG") ? "ARG" : "ENV"
        guard Words.contains(sentence, keyword), !Words.containsAny(plain, Lexicon.before),
              Words.containsAny(plain, Lexicon.stageWords), Words.containsAny(plain, Lexicon.carry) else { return nil }
        let subject = variable(spans, after: keyword).map { keyword + " " + $0 } ?? keyword
        let stays = negated(plain) || Words.containsAny(plain, Lexicon.staysInStage)
        return Statement(.stageScope, subject, stays ? .notAvailable : .available)
    }

    static func argAtRuntime(_ sentence: String, _ plain: String,
                             _ spans: [String]) -> Statement? {
        guard Words.contains(sentence, "ARG"), Words.containsAny(plain, Lexicon.runtime) else { return nil }
        let subject = variable(spans, after: "ARG") ?? "ARG"
        if Words.containsAny(plain, Lexicon.buildOnly) || negated(plain) {
            return Statement(.argAtRuntime, subject, .notAvailable)
        }
        guard Words.containsAny(plain, Lexicon.usable), !Words.contains(sentence, "ENV") else { return nil }
        return Statement(.argAtRuntime, subject, .available)
    }

    static func workdir(_ sentence: String,
                        _ plain: String) -> Statement? {
        guard Words.contains(sentence, "WORKDIR") else { return nil }
        if Words.containsAny(plain, Lexicon.createsAnyway) { return Statement(.workdirCreates, "WORKDIR", .creates) }
        if Words.containsAny(plain, Lexicon.mustExist) { return Statement(.workdirCreates, "WORKDIR", .mustExist) }
        return Words.containsAny(plain, Lexicon.creates) ? Statement(.workdirCreates, "WORKDIR", .creates) : nil
    }

    static func directoryCopy(_ sentence: String, _ plain: String,
                              _ spans: [String]) -> Statement? {
        // Judged only against a quoted `COPY` of a named directory whose destination does not already end in that
        // name: "`COPY src /app/src` copies the folder itself to `/app/src`" is right about what it does.
        guard Words.containsAny(plain, Lexicon.folders), let subject = spans.first(where: { $0.hasPrefix("COPY ") })
        else { return nil }
        let tokens = CopyArguments(String(subject.dropFirst(5))).tokens
        guard tokens.count == 2, tokens[0] != ".", PlacementReader.isDirectory(tokens[0]),
              ImagePath.lastName(tokens[1]) != ImagePath.lastName(tokens[0]) else { return nil }
        if Words.containsAny(plain, Lexicon.notTheFolder) { return Statement(.directoryCopy, subject, .copiesContents) }
        if Words.containsAny(plain, Lexicon.notOnlyContents) {
            return Statement(.directoryCopy, subject, .copiesDirectory)
        }
        if Words.containsAny(plain, Lexicon.contents) { return Statement(.directoryCopy, subject, .copiesContents) }
        return Words.containsAny(plain, Lexicon.itself) ? Statement(.directoryCopy, subject, .copiesDirectory) : nil
    }
}
