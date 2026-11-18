/// One thing an answer says about how Docker reads a Dockerfile.
public struct DockerfileClaim: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// Where a file from the build context ends up in the image.
        case placement
        /// What `COPY` does with a directory: copies the directory, or only what is inside it.
        case directoryCopy
        /// Whether `RUN cd` changes the directory for later instructions.
        case runCd
        /// Whether an `ARG` declared before the first `FROM` can be used inside a stage.
        case argBeforeFrom
        /// Whether `ENV` or `ARG` values carry from one stage into another.
        case stageScope
        /// Whether an `ARG` value is still there when the container runs.
        case argAtRuntime
        /// Whether `WORKDIR` creates a directory that does not exist.
        case workdirCreates
        /// A line of the answer's Dockerfile, which says by being there that it does what it is written to do.
        case line
    }

    public enum Assertion: String, Sendable, Hashable, CaseIterable {
        case landsAt
        case copiesDirectory
        case copiesContents
        case persists
        case doesNotPersist
        case available
        case notAvailable
        case creates
        case mustExist
        case worksAsWritten
    }

    public enum Source: Sendable, Hashable {
        /// A sentence of the answer's prose.
        case sentence
        /// The answer's n-th Dockerfile (counting from 1).
        case dockerfile(Int)
    }

    public let kind: Kind
    /// For a placement, the build-context path (empty when the sentence names only the image path); for a line, the
    /// instruction; otherwise the variable or instruction the sentence names.
    public let subject: String
    /// For a placement, the image path the claim says the file ends up at; empty otherwise.
    public let target: String
    public let assertion: Assertion
    public let sentence: String
    /// Said in words, rather than implied by a Dockerfile line.
    public let isExplicit: Bool
    public let source: Source
    /// The Dockerfile the claim is judged against (empty when the answer shows none and the sentence quotes none).
    let dockerfile: Dockerfile
    let dockerignore: String?
    let problem: LineProblem?

    init(kind: Kind, subject: String, target: String = "", assertion: Assertion, sentence: String,
         isExplicit: Bool = true, source: Source = .sentence, dockerfile: Dockerfile = Dockerfile(""),
         dockerignore: String? = nil, problem: LineProblem? = nil) {
        self.kind = kind
        self.subject = subject
        self.target = target
        self.assertion = assertion
        self.sentence = sentence
        self.isExplicit = isExplicit
        self.source = source
        self.dockerfile = dockerfile
        self.dockerignore = dockerignore
        self.problem = problem
    }

    /// Identifies the same claim across rewrites of an answer.
    var key: String {
        "\(kind)|\(subject)|\(target)|\(assertion)|" + String(describing: problem)
    }

    /// The claim in words.
    public var explanation: String {
        switch (kind, assertion) {
        case (.placement, _): "`\(subject.isEmpty ? "a file" : subject)` ends up at `\(target)`"
        case (.line, _): "`\(subject)` works as written"
        case (.directoryCopy, .copiesDirectory): "`COPY` of a directory copies the directory itself"
        case (.directoryCopy, _): "`COPY` of a directory copies what is inside it"
        case (.runCd, .persists): "`RUN cd` changes the directory for later instructions"
        case (.runCd, _): "`RUN cd` lasts only for its own `RUN`"
        case (.argBeforeFrom, .available): "an `ARG` declared before `FROM` can be used in the stage"
        case (.argBeforeFrom, _): "an `ARG` declared before `FROM` must be declared again inside the stage"
        case (.stageScope, .available): "`\(subject)` values carry into a later stage"
        case (.stageScope, _): "`\(subject)` values stay in their own stage"
        case (.argAtRuntime, .available): "an `ARG` value is there when the container runs"
        case (.argAtRuntime, _): "an `ARG` value exists only while the image builds"
        case (.workdirCreates, .creates): "`WORKDIR` creates a missing directory"
        case (.workdirCreates, _): "`WORKDIR` needs the directory to exist already"
        }
    }
}

/// Something a Dockerfile line does that its author most likely did not mean.
enum LineProblem: Sendable, Hashable {
    /// Several sources and a destination without a trailing `/`; the destination as it should be written.
    case severalSourcesNeedSlash(String)
    /// `RUN cd <directory>` on its own, with later instructions in the same stage.
    case runCdAlone(String)
    /// A variable declared by an `ARG` before the first `FROM`, used inside a stage that never redeclares it.
    case globalArgOutOfScope(String)
    /// A variable set only in another stage (`ARG` values never cross; `ENV` values only through `FROM`).
    case otherStageValue(String)
    /// A stage `ARG` used by a shell-form `CMD` or `ENTRYPOINT`, which runs when the container starts.
    case argGoneAtRuntime(String)
    /// `$NAME` in the exec (JSON) form of `CMD`, `ENTRYPOINT` or `RUN`, which runs no shell to expand it; the
    /// shell form that would.
    case execFormNoShell(String, fix: String)
}
