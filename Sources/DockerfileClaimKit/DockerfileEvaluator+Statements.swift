extension DockerfileEvaluator {
    func statement(_ claim: DockerfileClaim) -> DockerfileFinding {
        let name = String(claim.subject.reversed().prefix { $0 != " " }.reversed())
        switch (claim.kind, claim.assertion) {
        case (.directoryCopy, .copiesDirectory):
            return DockerfileFinding(claim: claim, outcome: .wrong(.copiesDirectoryItself))
        case (.runCd, .persists):
            let fix = claim.subject.hasPrefix("/") ? "WORKDIR \(claim.subject)" : "WORKDIR"
            return DockerfileFinding(claim: claim, outcome: .wrong(.runCdDoesNotPersist), fix: fix)
        case (.argBeforeFrom, .available) where !redeclared(claim, name):
            return DockerfileFinding(claim: claim, outcome: .wrong(.argBeforeFrom), fix: named(name, "ARG \(name)"))
        case (.stageScope, .available):
            return stageScope(claim, name)
        case (.argAtRuntime, .available) where !keptByEnv(claim, name):
            return DockerfileFinding(claim: claim, outcome: .wrong(.argIsBuildOnly),
                                     fix: named(name, "ENV \(name)=$\(name)"))
        case (.workdirCreates, .mustExist):
            return DockerfileFinding(claim: claim, outcome: .wrong(.workdirCreatesDirectory))
        default:
            return DockerfileFinding(claim: claim, outcome: .exact)
        }
    }

    /// A fix that needs the variable's name, when the sentence named one.
    func named(_ name: String, _ fix: String) -> String? {
        name == "ARG" ? nil : fix
    }

    /// `ENV` values reach a stage built `FROM` the one that sets them; `ARG` values never do.
    func stageScope(_ claim: DockerfileClaim, _ name: String) -> DockerfileFinding {
        guard !claim.subject.hasPrefix("ARG") else {
            return DockerfileFinding(claim: claim, outcome: .wrong(.stageStartsFresh))
        }
        let stages = Stage.split(claim.dockerfile).stages
        guard let last = stages.last, claim.subject != "ENV" else {
            return DockerfileFinding(claim: claim, outcome: .caveat(.onlyIfBuiltFrom))
        }
        let inherited = last.ancestors(in: stages).contains { stage in
            stage.body.contains { $0.keyword == "ENV" && Declarations.names($0).contains(name) }
        }
        return DockerfileFinding(claim: claim, outcome: inherited ? .exact : .wrong(.stageStartsFresh))
    }

    /// Whether the final stage declares the `ARG` again.
    func redeclared(_ claim: DockerfileClaim, _ name: String) -> Bool {
        let body = Stage.split(claim.dockerfile).stages.last.map(\.body) ?? []
        return body.contains { $0.keyword == "ARG" && Declarations.names($0).contains(name) }
    }

    /// Whether an `ENV` line copies the `ARG` into the image's environment.
    func keptByEnv(_ claim: DockerfileClaim, _ name: String) -> Bool {
        claim.dockerfile.instructions.contains {
            $0.keyword == "ENV" && Substitution.references(in: $0.arguments).contains(name)
        }
    }

    func line(_ claim: DockerfileClaim, _ problem: LineProblem) -> DockerfileFinding {
        switch problem {
        case .severalSourcesNeedSlash(let destination):
            let outcome: DockerfileFinding.Outcome = switch policy.builder {
            case .classic?: .wrong(.destinationNeedsSlash)
            case .buildKit?: .unchecked("BuildKit's handling of several sources was not checked")
            case nil: .caveat(.classicBuilderStops)
            }
            return DockerfileFinding(claim: claim, outcome: outcome, fix: destination)
        case .runCdAlone(let directory):
            return DockerfileFinding(claim: claim, outcome: .wrong(.runCdDoesNotPersist), fix: "WORKDIR \(directory)")
        case .globalArgOutOfScope(let name):
            return DockerfileFinding(claim: claim, outcome: .wrong(.argBeforeFrom), fix: "ARG \(name)")
        case .otherStageValue:
            return DockerfileFinding(claim: claim, outcome: .wrong(.stageStartsFresh))
        case .argGoneAtRuntime(let name):
            return DockerfileFinding(claim: claim, outcome: .wrong(.argIsBuildOnly), fix: "ENV \(name)=$\(name)")
        case .execFormNoShell(_, let fix):
            return DockerfileFinding(claim: claim, outcome: .wrong(.execFormNoShell), fix: fix)
        }
    }
}
