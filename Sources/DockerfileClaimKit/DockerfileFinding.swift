import DockerignoreClaimKit

/// What a claim about a Dockerfile turned out to be once Docker's rules were applied.
public struct DockerfileFinding: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        case exact
        /// Holds, with something a reader should know.
        case caveat(Caveat)
        case wrong(Slip?)
        /// Could not be checked, and why.
        case unchecked(String)
    }

    public enum Caveat: Sendable, Hashable {
        /// Holds only if something the answer does not say is true (see `PlacementCaveat`).
        case placement(PlacementCaveat)
        /// `ENV` values reach a later stage only when it is built `FROM` the stage that sets them.
        case onlyIfBuiltFrom
        /// The classic builder stops on this line; BuildKit was not checked.
        case classicBuilderStops
    }

    /// A recognisable mistake behind a wrong claim.
    public enum Slip: String, Sendable, Hashable, CaseIterable {
        /// `COPY src /app` read as making `/app/src`: Docker copies what is inside the directory.
        case copiesDirectoryItself
        /// `COPY src/*.js /app/` read as keeping folders: each match lands in the destination by its name.
        case globKeepsPath
        /// A relative destination read from `/`: it is relative to the `WORKDIR`.
        case workdirIgnored
        /// `COPY a.txt /app` read as `/app/a.txt`: with no trailing `/` and no such directory, the file becomes
        /// `/app`.
        case destinationNotDirectory
        /// A file the .dockerignore keeps out of the build context read as copied.
        case excludedByDockerignore
        /// `RUN cd` read as lasting: each `RUN` starts a new shell; `WORKDIR` is what lasts.
        case runCdDoesNotPersist
        /// An `ARG` declared before the first `FROM` read as visible in the stage: only `FROM` lines see it until the
        /// stage declares it again.
        case argBeforeFrom
        /// A value from another stage read as visible: a stage starts from its base, `ARG` values never cross, and
        /// `ENV` values cross only through `FROM`.
        case stageStartsFresh
        /// An `ARG` read as present in the running container: it exists only while the image builds.
        case argIsBuildOnly
        /// `WORKDIR` read as needing an existing directory: it creates it.
        case workdirCreatesDirectory
        /// Several sources copied to a destination without a trailing `/`: the classic builder stops.
        case destinationNeedsSlash
        /// `$NAME` in the exec (JSON) form: no shell runs, so it is passed on as the literal text.
        case execFormNoShell
    }

    public enum Severity: Int, Sendable, Hashable, Comparable {
        case holds
        case unchecked
        case caution
        case wrong

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let claim: DockerfileClaim
    public let outcome: Outcome
    /// Where Docker actually puts the file (for a placement claim).
    public let actual: [String]
    /// A line or path that does what the claim expected, where there is an obvious one.
    public let fix: String?
    /// Flagged in an earlier review of the same conversation (set by `DockerfileLedger`).
    public internal(set) var isRepeated = false

    init(claim: DockerfileClaim, outcome: Outcome, actual: [String] = [], fix: String? = nil) {
        self.claim = claim
        self.outcome = outcome
        self.actual = actual
        self.fix = fix
    }

    public var severity: Severity {
        switch outcome {
        case .exact: .holds
        case .unchecked: .unchecked
        case .caveat: .caution
        case .wrong: .wrong
        }
    }

    var key: String {
        claim.key
    }
}

/// How strictly claims are judged.
public struct DockerfilePolicy: Sendable, Hashable {
    /// Whether the answer's Dockerfile lines count as claims of their own.
    public var checksLines: Bool
    /// The builder the reader uses, when known; `nil` makes anything the two builders may do differently a caveat.
    public var builder: DockerBuilder?
    /// Whether a claim that holds only under an unstated setup is reported (as a caveat) rather than passed.
    public var reportsCaveats: Bool

    public init(checksLines: Bool = true, builder: DockerBuilder? = nil, reportsCaveats: Bool = true) {
        self.checksLines = checksLines
        self.builder = builder
        self.reportsCaveats = reportsCaveats
    }

    public static let standard = DockerfilePolicy()
    public static let lenient = DockerfilePolicy(checksLines: false, reportsCaveats: false)
    public static let classic = DockerfilePolicy(builder: .classic)
    public static let buildKit = DockerfilePolicy(builder: .buildKit)
}
