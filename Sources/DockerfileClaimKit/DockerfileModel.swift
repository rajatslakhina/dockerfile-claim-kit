import DockerignoreClaimKit
import Foundation

/// A Dockerfile's stages, read well enough to say where a file from the build context ends up in the final image.
public struct DockerfileModel: Sendable {
    public let dockerfile: Dockerfile
    /// The build context's .dockerignore, when the answer shows one.
    public let dockerignore: DockerignoreRules?
    let stages: [Stage]
    let globals: [String: VariableValue]

    public init(_ dockerfile: Dockerfile, dockerignore: DockerignoreRules? = nil) {
        self.dockerfile = dockerfile
        self.dockerignore = dockerignore
        (stages, globals) = Stage.split(dockerfile)
    }

    /// Where `path` (relative to the build context) ends up in the final stage.
    public func placements(of path: String) -> PlacementResult {
        placements(of: path, reading: nil)
    }

    func placements(of path: String, reading: Misreading?) -> PlacementResult {
        var walk = Walk(model: self, reading: reading, path: ImagePath.relative(path))
        return walk.run()
    }

    /// Every value any stage declares, for the misreading that lets them leak between stages.
    var declaredAnywhere: [String: VariableValue] {
        var values = globals
        for stage in stages {
            let substitution = Substitution(escape: dockerfile.escape) { values[$0] ?? .unset }
            for instruction in stage.body where instruction.keyword == "ENV" {
                for (name, value) in Declarations.env(instruction.arguments, substitution) { values[name] = value }
            }
            for instruction in stage.body where instruction.keyword == "ARG" {
                for (name, value) in Declarations.args(instruction.arguments, substitution) where value != nil {
                    values[name] = value
                }
            }
        }
        return values
    }
}

/// What a stage has seen so far.
struct StageState {
    var env: [String: VariableValue] = [:]
    var args: [String: VariableValue] = [:]
    /// `nil` when the base image may have set it.
    var workdir: String? = "/"
    var isOpen = false
    var directories: Set<String> = ["/"]
    /// Destinations written without a trailing `/`: each is a file or a directory, depending on what was copied.
    var written: Set<String> = []
    var placements: [Placement] = []

    /// Whether `path` is a directory: `nil` when the model cannot tell.
    func isDirectory(_ path: String) -> Bool? {
        if directories.contains(path) { return true }
        return written.contains(path) || isOpen ? nil : false
    }
}

/// One pass over the stages, following one path.
struct Walk {
    let model: DockerfileModel
    let reading: Misreading?
    let path: String
    var finished: [StageState] = []
    var excludedBy: DockerignorePattern?
    var unknown: String?

    init(model: DockerfileModel, reading: Misreading?, path: String) {
        self.model = model
        self.reading = reading
        self.path = path
    }

    mutating func run() -> PlacementResult {
        let leaked = reading == .otherStagesInScope ? model.declaredAnywhere : [:]
        for stage in model.stages {
            var state = start(stage)
            for instruction in stage.body {
                let lookup: (String) -> VariableValue = { [state] name in
                    state.env[name] ?? state.args[name] ?? leaked[name] ?? (state.isOpen ? .unknown : .unset)
                }
                apply(instruction, Substitution(escape: model.dockerfile.escape, lookup: lookup), &state)
            }
            finished.append(state)
        }
        return PlacementResult(placements: finished.last?.placements ?? [], excludedBy: excludedBy, unknown: unknown)
    }

    func start(_ stage: Stage) -> StageState {
        var state = StageState()
        switch stage.base {
        case .scratch:
            break
        case .stage(let index):
            state = finished[index]
            state.args = [:]
        case .image:
            state.workdir = nil
            state.isOpen = true
        }
        if reading == .globalArgsInScope { state.args = model.globals }
        return state
    }

    mutating func apply(_ instruction: DockerfileInstruction, _ substitution: Substitution, _ state: inout StageState) {
        switch instruction.keyword {
        case "ARG":
            for (name, value) in Declarations.args(instruction.arguments, substitution) {
                state.args[name] = value ?? model.globals[name] ?? .unknown
            }
        case "ENV":
            for (name, value) in Declarations.env(instruction.arguments, substitution) { state.env[name] = value }
        case "WORKDIR":
            let target = substitution.word(instruction.arguments)
            let base = state.workdir ?? (target?.hasPrefix("/") == true ? "/" : nil)
            guard let target, let base else {
                state.workdir = nil
                return
            }
            let resolved = ImagePath.resolve(target, against: base)
            state.directories.formUnion(ImagePath.ancestors(resolved) + [resolved])
            state.workdir = resolved
        case "COPY", "ADD":
            copy(instruction, substitution, &state)
        case "RUN" where Words.containsAny(instruction.arguments, ["mv", "cp", "rsync", "rm"]):
            unknown = unknown ?? "line \(instruction.lineNumber) runs a command that may move or remove files"
        default:
            break
        }
    }
}
