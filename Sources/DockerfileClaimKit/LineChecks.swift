import Foundation

/// Lines of a Dockerfile that do not do what they are written to do, found without running anything.
enum LineChecks {
    static let shells: Set<String> = ["sh", "bash", "ash", "dash", "zsh", "pwsh", "powershell", "cmd"]
    static let laterWork: Set<String> = ["RUN", "COPY", "ADD", "CMD", "ENTRYPOINT"]
    /// Set in every container whatever the Dockerfile says, so using them in any stage is fine.
    static let provided: Set<String> = ["PATH", "HOME", "HOSTNAME", "TERM", "PWD", "USER", "SHELL", "LANG", "TZ"]
    static let expanding: Set<String> = ["RUN", "COPY", "ADD", "ENV", "WORKDIR", "CMD", "ENTRYPOINT", "LABEL", "USER",
                                         "EXPOSE", "VOLUME", "ARG"]

    static func claims(in dockerfile: Dockerfile, block: Int, dockerignore: String? = nil) -> [DockerfileClaim] {
        let (stages, globals) = Stage.split(dockerfile)
        var problems: [(DockerfileInstruction, LineProblem)] = []
        for stage in stages {
            problems += copyProblems(stage) + runCdProblems(stage) + execProblems(stage)
            problems += scopeProblems(stage, stages, Set(globals.keys))
        }
        return problems.sorted { $0.0.lineNumber < $1.0.lineNumber }.map { instruction, problem in
            DockerfileClaim(kind: .line, subject: instruction.text, assertion: .worksAsWritten,
                            sentence: instruction.text, isExplicit: false, source: .dockerfile(block),
                            dockerfile: dockerfile, dockerignore: dockerignore, problem: problem)
        }
    }

    static func copyProblems(_ stage: Stage) -> [(DockerfileInstruction, LineProblem)] {
        stage.body.compactMap { instruction in
            guard ["COPY", "ADD"].contains(instruction.keyword), !instruction.hasHeredoc else { return nil }
            let tokens = CopyArguments(instruction.arguments).tokens
            guard tokens.count > 2, let last = tokens.last else { return nil }
            let destination = last.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            // A destination held in a variable may end in `/` once expanded; not judged.
            guard !destination.hasSuffix("/"), !destination.contains("$") else { return nil }
            return (instruction, .severalSourcesNeedSlash(destination + "/"))
        }
    }

    static func runCdProblems(_ stage: Stage) -> [(DockerfileInstruction, LineProblem)] {
        stage.body.enumerated().compactMap { offset, instruction in
            // A `cd` that ends a `RUN` (alone, or after `&&` or `;`) changes nothing that runs after it.
            guard instruction.keyword == "RUN" else { return nil }
            let last = instruction.arguments.reversed().prefix { $0 != ";" && $0 != "&" }.reversed()
            let words = String(last).split(whereSeparator: \.isWhitespace)
            guard words.count == 2, words[0] == "cd",
                  stage.body[(offset + 1)...].contains(where: { laterWork.contains($0.keyword) }) else { return nil }
            return (instruction, .runCdAlone(String(words[1])))
        }
    }

    static func execProblems(_ stage: Stage) -> [(DockerfileInstruction, LineProblem)] {
        stage.body.compactMap { instruction in
            guard ["RUN", "CMD", "ENTRYPOINT"].contains(instruction.keyword),
                  let elements = jsonForm(instruction.arguments), let first = elements.first,
                  !shells.contains(ImagePath.lastName(first)), !runsShell(elements),
                  let name = elements.lazy.flatMap({ Substitution.references(in: $0) }).first else { return nil }
            let command = elements.joined(separator: " ").replacingOccurrences(of: "\"", with: "\\\"")
            let fix = "\(instruction.keyword) [\"sh\", \"-c\", \"\(command)\"]"
            return (instruction, .execFormNoShell(name, fix: fix))
        }
    }

    /// `["tini", "--", "sh", "-c", "..."]`: a shell further along the command expands the names.
    static func runsShell(_ elements: [String]) -> Bool {
        zip(elements, elements.dropFirst()).contains { shells.contains(ImagePath.lastName($0)) && $1 == "-c" }
    }

    static func jsonForm(_ arguments: String) -> [String]? {
        guard arguments.hasPrefix("[") else { return nil }
        return try? JSONDecoder().decode([String].self, from: Data(arguments.utf8))
    }

    /// Variables a stage uses that it cannot see.
    static func scopeProblems(_ stage: Stage, _ stages: [Stage],
                              _ globals: Set<String>) -> [(DockerfileInstruction, LineProblem)] {
        let inherited = stage.ancestors(in: stages).flatMap { ancestor in
            ancestor.body.filter { $0.keyword == "ENV" }.flatMap(Declarations.names)
        }
        let elsewhere = Set(stages.filter { $0.index != stage.index }.flatMap { $0.body.flatMap(Declarations.names) })
        var visible = Set(inherited)
        var environment = Set(inherited)
        var problems: [(DockerfileInstruction, LineProblem)] = []
        for instruction in stage.body {
            let names = references(instruction)
            for name in names where !visible.contains(name) {
                if globals.contains(name) {
                    problems.append((instruction, .globalArgOutOfScope(name)))
                } else if elsewhere.contains(name) {
                    problems.append((instruction, .otherStageValue(name)))
                }
            }
            let shellForm = ["CMD", "ENTRYPOINT"].contains(instruction.keyword)
                && jsonForm(instruction.arguments) == nil
            for name in names where shellForm && visible.contains(name) && !environment.contains(name) {
                problems.append((instruction, .argGoneAtRuntime(name)))
            }
            visible.formUnion(Declarations.names(instruction))
            if instruction.keyword == "ENV" { environment.formUnion(Declarations.names(instruction)) }
        }
        return problems
    }

    /// The names an instruction expands, each once; a `RUN` command's own shell variables left out.
    static func references(_ instruction: DockerfileInstruction) -> [String] {
        guard expanding.contains(instruction.keyword) else { return [] }
        var names: [String] = []
        let declared = Set(Declarations.names(instruction))
        // `ENV PATH=/x:$PATH` extends a value; it does not need the stage to have declared it.
        for name in Substitution.references(in: instruction.arguments)
        where !names.contains(name) && !provided.contains(name) && !declared.contains(name) {
            let own = ["\(name)=", "for \(name) ", "read \(name)", "export \(name)"]
            if instruction.keyword == "RUN", own.contains(where: instruction.arguments.contains) { continue }
            names.append(name)
        }
        return names
    }
}
