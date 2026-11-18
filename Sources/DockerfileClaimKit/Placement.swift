import DockerignoreClaimKit

/// Something that must hold for a file to land where the model says.
public enum PlacementCaveat: Sendable, Hashable {
    /// The destination has no trailing `/`, and the file lands inside it only if the base image or an earlier step
    /// already made it a directory.
    case insideIfDirectory(String)
    /// The destination has no trailing `/`, and the file is renamed to it only if nothing made it a directory.
    case renamedUnlessDirectory(String)
    /// A relative destination in a stage whose base image may set its own `WORKDIR`.
    case baseImageWorkdir
    /// A pattern copied to a path without a trailing `/`: that path is the file only when the pattern matches one
    /// file; more matches stop the classic builder.
    case globMatchesOne
    /// Several sources and a destination without a trailing `/`: the classic builder stops; BuildKit was not checked.
    case classicStops
    /// `**` in a source: the classic builder reads it as `*` (one level); BuildKit was not checked.
    case doubleStar
}

/// Where a file from the build context ends up in the image.
public struct Placement: Sendable, Hashable {
    /// The absolute path in the final stage.
    public let path: String
    /// The `COPY` or `ADD` line that writes it there (the last one, for a file copied between stages).
    public let lineNumber: Int
    /// What must hold for it to land there; empty when nothing does.
    public let caveats: [PlacementCaveat]
}

/// Every place one file ends up, or why the model cannot say.
public struct PlacementResult: Sendable, Hashable {
    public let placements: [Placement]
    /// The .dockerignore line that keeps the file out of the build context.
    public let excludedBy: DockerignorePattern?
    /// Why the model could not follow the file, when something in the Dockerfile was not modelled.
    public let unknown: String?

    public var paths: [String] {
        placements.map(\.path)
    }
}

/// A way of misreading Docker's rules, used to name the slip behind a wrong claim.
enum Misreading: CaseIterable, Sendable {
    /// `COPY src /app` read as making `/app/src`.
    case copiesDirectory
    /// `COPY src/*.js /app/` read as keeping the matched file's folders.
    case globKeepsPath
    /// A relative destination read from `/` rather than from the `WORKDIR`.
    case workdirIgnored
    /// `COPY a.txt /app` read as `/app/a.txt` when nothing made `/app` a directory.
    case destinationIsDirectory
    /// The .dockerignore not applied.
    case ignoresDockerignore
    /// `ARG` values declared before the first `FROM` read as visible in every stage.
    case globalArgsInScope
    /// `ENV` and `ARG` values of other stages read as visible.
    case otherStagesInScope
}

/// How one `COPY` source matches a path.
enum SourceMatch: Equatable {
    /// The path is the source itself (or matched it by pattern); its name.
    case file(String)
    /// The path is inside a directory the source names; the directory's own name (`nil` for the whole context) and
    /// the rest of the path below it.
    case directory(String?, String)

    static func match(_ source: String, _ path: String) -> SourceMatch? {
        // A source that climbs with `..` is outside the build context (the classic builder stops); not modelled.
        guard !source.split(separator: "/").contains("..") else { return nil }
        let source = ImagePath.relative(source)
        let parts = path.split(separator: "/").map(String.init)
        if source.isEmpty { return .directory(nil, path) }
        guard GoMatch.hasWildcard(source) else {
            if source == path { return .file(ImagePath.lastName(path)) }
            guard path.hasPrefix(source + "/") else { return nil }
            return .directory(ImagePath.lastName(source), String(path.dropFirst(source.count + 1)))
        }
        let patterns = source.split(separator: "/").map(String.init)
        guard parts.count >= patterns.count,
              zip(patterns, parts).allSatisfy({ GoMatch.matches($0, $1) }) else { return nil }
        if parts.count == patterns.count { return .file(parts[parts.count - 1]) }
        return .directory(parts[patterns.count - 1], parts.dropFirst(patterns.count).joined(separator: "/"))
    }
}
