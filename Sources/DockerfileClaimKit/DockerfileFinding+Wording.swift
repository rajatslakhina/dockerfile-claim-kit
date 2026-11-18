extension DockerfileFinding {
    /// One sentence for the reader: what holds, what to check, or what is wrong and what to write instead.
    public var explanation: String {
        let said = claim.explanation
        switch outcome {
        case .exact:
            return "It holds that \(said)."
        case .caveat(.classicBuilderStops):
            return "`\(claim.subject)` stops the classic builder: several sources need a destination ending in `/`"
                + instead + "; BuildKit was not checked."
        case .caveat(let caveat):
            return "It holds that \(said), " + Self.condition(caveat) + "."
        case .wrong(let slip?):
            return "It does not hold that \(said): " + Self.reason(slip, claim) + where_ + instead + "."
        case .wrong(nil):
            return "It does not hold that \(said)" + where_ + "."
        case .unchecked(let reason):
            return "Could not check that \(said): \(reason)."
        }
    }

    /// "; Docker puts it at `/app/index.js`"
    var where_: String {
        guard claim.kind == .placement, !actual.isEmpty else { return "" }
        let paths = actual.map { "`\($0)`" }.joined(separator: " and ")
        return actual.allSatisfy { $0.contains(DockerfileEvaluator.child) } ? "" : "; Docker puts it at \(paths)"
    }

    /// "; write `WORKDIR /app` instead"
    var instead: String {
        fix.map { "; write `\($0)` instead" } ?? ""
    }

    static func condition(_ caveat: Caveat) -> String {
        switch caveat {
        case .placement(let placement):
            condition(placement)
        case .classicBuilderStops:
            condition(.classicStops)
        case .onlyIfBuiltFrom:
            "but only for a stage built `FROM` the stage that sets them; a stage built from an image starts with "
                + "that image's values"
        }
    }

    static func condition(_ caveat: PlacementCaveat) -> String {
        switch caveat {
        case .insideIfDirectory(let path):
            "but only if `\(path)` is already a directory (in the base image or from an earlier step); otherwise "
                + "the file is renamed to `\(path)`. End the destination with `/` to be sure"
        case .renamedUnlessDirectory(let path):
            "but only if nothing has made `\(path)` a directory; if the base image has one, the file lands inside "
                + "it. Name the full file path to be sure"
        case .baseImageWorkdir:
            "but the destination is relative and the base image may set its own `WORKDIR`; use an absolute path "
                + "or set `WORKDIR` first"
        case .globMatchesOne:
            "but only while the pattern matches one file; with more, the classic builder stops. End the "
                + "destination with `/`"
        case .classicStops:
            "but the classic builder stops on that line: several sources need a destination ending in `/`; "
                + "BuildKit was not checked"
        case .doubleStar:
            "as the classic builder reads it: `**` matches one level, like `*`; BuildKit was not checked"
        }
    }

    static func reason(_ slip: Slip, _ claim: DockerfileClaim) -> String {
        switch slip {
        case .copiesDirectoryItself: "`COPY` of a directory copies what is inside it, not the directory itself"
        case .globKeepsPath:
            "each file a pattern matches lands in the destination by its own name, without its folders"
        case .workdirIgnored: "a relative destination is relative to the `WORKDIR`, not to `/`"
        case .destinationNotDirectory:
            "with no trailing `/` and no directory at the destination, the file is renamed to the destination"
        case .excludedByDockerignore: "the .dockerignore keeps it out of the build context, so `COPY` never sees it"
        case .destinationNeedsSlash:
            "with several sources the destination must end in `/`, or the classic builder stops"
        default: ruleReason(slip)
        }
    }

    /// The slips about scope and the shell.
    static func ruleReason(_ slip: Slip) -> String {
        switch slip {
        case .runCdDoesNotPersist: "each `RUN` starts a new shell, so `cd` ends with it; `WORKDIR` is what lasts"
        case .argBeforeFrom:
            "an `ARG` declared before `FROM` is visible only to `FROM` lines until the stage declares it again"
        case .stageStartsFresh:
            "a stage starts from its base: `ARG` values never cross into another stage, and `ENV` values only through "
                + "`FROM`"
        case .argIsBuildOnly: "an `ARG` exists only while the image builds; copy it into an `ENV` to keep it"
        case .workdirCreatesDirectory: "`WORKDIR` creates the directory when it does not exist"
        default: "the exec (JSON) form runs no shell, so `$` names are passed on as written"
        }
    }
}
