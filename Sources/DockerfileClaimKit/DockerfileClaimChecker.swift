/// Reads what an answer says about a Dockerfile and checks every claim with Docker's own rules: the one call most
/// callers need.
public struct DockerfileClaimChecker: Sendable {
    public let policy: DockerfilePolicy
    public let reader: DockerfileClaimReader

    public init(policy: DockerfilePolicy = .standard) {
        self.policy = policy
        reader = DockerfileClaimReader(checksLines: policy.checksLines)
    }

    public func claims(in text: String, context: String = "") -> [DockerfileClaim] {
        reader.claims(in: text, context: context)
    }

    public func judge(_ claim: DockerfileClaim) -> DockerfileFinding {
        DockerfileEvaluator(policy: policy).judge(claim)
    }

    /// Every claim's finding. A Dockerfile line that works as written makes no finding of its own, so an answer with
    /// a long Dockerfile is not reported as a long list of claims that hold.
    public func check(_ text: String, context: String = "") -> DockerfileReport {
        report(claims(in: text, context: context))
    }

    func report(_ claims: [DockerfileClaim]) -> DockerfileReport {
        DockerfileReport(findings: claims.map(judge).filter { $0.claim.isExplicit || $0.severity != .holds })
    }
}

/// Checks a conversation's answers one after another and remembers what it flagged, so a wrong claim stated again
/// after a correction was asked for is marked as repeated rather than new.
public actor DockerfileLedger {
    public struct Statistics: Sendable, Hashable {
        public var reviews = 0
        public var claims = 0
        public var flagged = 0
        public var repeated = 0
    }

    public nonisolated let checker: DockerfileClaimChecker
    public private(set) var statistics = Statistics()
    private var flaggedKeys: Set<String> = []
    /// The last Dockerfile the conversation showed; later answers that quote none are read against it.
    private var earlier: Earlier?

    public init(checker: DockerfileClaimChecker = DockerfileClaimChecker()) {
        self.checker = checker
    }

    /// Checks one answer. `context` is the question it answers. A turn where neither talks about a Dockerfile makes
    /// no new claims; it keeps only those that repeat a claim flagged earlier in the conversation.
    public func review(_ text: String, context: String = "") -> DockerfileReport {
        let about = DockerfileClaimReader.isAboutDockerfile(text) || DockerfileClaimReader.isAboutDockerfile(context)
        let blocks = AnswerBlocks.split(text)
        if let shown = DockerfileBlock.find(in: blocks).last {
            earlier = Earlier(dockerfile: shown.dockerfile, dockerignore: DockerfileBlock.dockerignore(in: blocks))
        }
        let all = checker.reader.allClaims(in: text, context: context, earlier: earlier)
        var findings = checker.report(about ? all : all.filter { flaggedKeys.contains($0.key) }).findings
        var keys: Set<String> = []
        for index in findings.indices where findings[index].severity >= .caution {
            findings[index].isRepeated = flaggedKeys.contains(findings[index].key)
            keys.insert(findings[index].key)
        }
        flaggedKeys.formUnion(keys)
        let report = DockerfileReport(findings: findings)
        statistics.reviews += 1
        statistics.claims += findings.count
        statistics.flagged += report.flagged.count
        statistics.repeated += report.repeatedCount
        return report
    }

    /// Starts a new conversation: nothing flagged so far counts as a repeat.
    public func forget() {
        flaggedKeys.removeAll()
        earlier = nil
    }
}
