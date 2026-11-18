import DockerignoreClaimKit

/// Judges claims with the Dockerfile model.
struct DockerfileEvaluator {
    static let child = "__dockerfile_claim_child__"

    let policy: DockerfilePolicy

    func judge(_ claim: DockerfileClaim) -> DockerfileFinding {
        let finding: DockerfileFinding
        if let problem = claim.problem {
            finding = line(claim, problem)
        } else if claim.kind == .placement {
            finding = placement(claim)
        } else {
            finding = statement(claim)
        }
        guard !policy.reportsCaveats, finding.severity == .caution else { return finding }
        return DockerfileFinding(claim: claim, outcome: .exact, actual: finding.actual)
    }

    // MARK: Placements

    func model(_ claim: DockerfileClaim) -> DockerfileModel {
        DockerfileModel(claim.dockerfile, dockerignore: claim.dockerignore.map(DockerignoreRules.init))
    }

    /// Where a path ends up; a directory is followed through a file inside it.
    static func locate(_ model: DockerfileModel, _ path: String, directory: Bool,
                       _ reading: Misreading?) -> PlacementResult {
        guard directory else { return model.placements(of: path, reading: reading) }
        let result = model.placements(of: ImagePath.relative(path) + "/" + child, reading: reading)
        let placements = result.placements.map {
            Placement(path: String($0.path.dropLast(child.count + 1)), lineNumber: $0.lineNumber, caveats: $0.caveats)
        }
        return PlacementResult(placements: placements, excludedBy: result.excludedBy, unknown: result.unknown)
    }

    func placement(_ claim: DockerfileClaim) -> DockerfileFinding {
        let model = model(claim)
        let target = claim.target
        guard !claim.subject.isEmpty else { return destinationOnly(claim, model, target) }
        let directory = PlacementReader.isDirectory(claim.subject)
        let result = Self.locate(model, claim.subject, directory: directory, nil)
        if let hit = result.placements.first(where: { $0.path == target }) {
            return DockerfileFinding(claim: claim, outcome: outcome(hit.caveats), actual: result.paths)
        }
        for reading in Misreading.allCases
        where Self.locate(model, claim.subject, directory: directory, reading).paths.contains(target) {
            let slip = Self.slip(reading)
            let fix = slip == .destinationNotDirectory ? ImagePath.ancestors(target).last.map { $0 + "/" } : nil
            return DockerfileFinding(claim: claim, outcome: .wrong(slip), actual: result.paths, fix: fix)
        }
        if let unknown = result.unknown { return DockerfileFinding(claim: claim, outcome: .unchecked(unknown)) }
        guard !result.placements.isEmpty || result.excludedBy != nil else {
            return DockerfileFinding(claim: claim, outcome: .unchecked("no COPY or ADD line copies `\(claim.subject)`"))
        }
        // No known misreading leads there: the sentence may mean something else by the path.
        let reason = "Docker puts it at " + result.paths.map { "`\($0)`" }.joined(separator: " and ")
            + ", and no known misreading leads to `\(target)`"
        return DockerfileFinding(claim: claim, outcome: .unchecked(reason), actual: result.paths)
    }

    /// A sentence that names only the image path ("you get `/app/src/index.js`"): the file it must come from is
    /// worked out from each `COPY` source.
    func destinationOnly(_ claim: DockerfileClaim, _ model: DockerfileModel, _ target: String) -> DockerfileFinding {
        for source in Self.sources(model).reversed() {
            let directory = PlacementReader.isDirectory(source)
            for found in Self.locate(model, source, directory: directory, nil).placements {
                if found.path == target { return DockerfileFinding(claim: claim, outcome: outcome(found.caveats)) }
                let prefix = found.path == "/" ? "/" : found.path + "/"
                guard directory, target.hasPrefix(prefix) else { continue }
                let below = String(target.dropFirst(prefix.count))
                let name = ImagePath.lastName(source)
                let parts = below.split(separator: "/", maxSplits: 1).map(String.init)
                let doubled = ImagePath.relative(source) + "/" + name
                // Unless the sentence itself names a build-context path such as `src/src/...`.
                if parts.first == name, !claim.sentence.contains("`" + doubled) {
                    let actual = ImagePath.join(found.path, parts.count > 1 ? parts[1] : "")
                    return DockerfileFinding(claim: claim, outcome: .wrong(.copiesDirectoryItself), actual: [actual])
                }
                return DockerfileFinding(claim: claim, outcome: outcome(found.caveats))
            }
        }
        return DockerfileFinding(claim: claim, outcome: .unchecked("no COPY or ADD line writes to `\(target)`"))
    }

    /// The plain sources (no pattern, variable or `..`) of the final stage's `COPY` and `ADD` lines, and of the
    /// stages it is built on.
    static func sources(_ model: DockerfileModel) -> [String] {
        guard let last = model.stages.last else { return [] }
        let chain = (last.ancestors(in: model.stages).reversed() + [last]).flatMap(\.body)
        return chain.filter { ["COPY", "ADD"].contains($0.keyword) }.flatMap { instruction -> [String] in
            let arguments = CopyArguments(instruction.arguments)
            guard arguments.flags["from"] == nil else { return [] }
            return arguments.tokens.dropLast().filter { !GoMatch.hasWildcard($0) && !$0.contains("$") }
        }
    }

    static func slip(_ reading: Misreading) -> DockerfileFinding.Slip {
        switch reading {
        case .copiesDirectory: .copiesDirectoryItself
        case .globKeepsPath: .globKeepsPath
        case .workdirIgnored: .workdirIgnored
        case .destinationIsDirectory: .destinationNotDirectory
        case .ignoresDockerignore: .excludedByDockerignore
        case .globalArgsInScope: .argBeforeFrom
        case .otherStagesInScope: .stageStartsFresh
        }
    }

    /// What a placement's caveats come to under the policy's builder.
    func outcome(_ caveats: [PlacementCaveat]) -> DockerfileFinding.Outcome {
        if caveats.contains(.classicStops) {
            switch policy.builder {
            case .classic?: return .wrong(.destinationNeedsSlash)
            case .buildKit?: return .unchecked("BuildKit's handling of several sources was not checked")
            case nil: return .caveat(.placement(.classicStops))
            }
        }
        let remaining = caveats.filter { $0 != .doubleStar || policy.builder != .classic }
        return remaining.first.map { .caveat(.placement($0)) } ?? .exact
    }
}
