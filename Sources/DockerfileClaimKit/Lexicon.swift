/// Phrases that mark what a sentence says. Matched as words against the sentence lowercased, backticks removed.
enum Lexicon {
    static let keywords = ["COPY", "ADD", "RUN", "ARG", "ENV", "WORKDIR", "FROM"]
    /// Tools whose copy rules differ from `COPY`'s, and files with their own rules: a sentence about them is not
    /// about the Dockerfile.
    static let otherTools = ["docker cp", "cp -r", "cp -a", "`cp ", "rsync", "scp", "kubectl", "volume", "volumes",
                             "bind mount", "bind-mount", "compose", "-v", "github actions", "env:", "environment:"]
    static let neighbours = ["docker-compose", "compose.yaml", "compose.yml", "compose file", ".dockerignore",
                             "makefile", "workflow", ".gitlab-ci", "jenkinsfile", "helm chart", ".gitignore"]
    static let extensionless: Set<String> = ["Dockerfile", "Containerfile", "Makefile", "LICENSE", "README",
                                             "Gemfile", "Procfile", "Rakefile", "Jenkinsfile", "Brewfile"]

    static let placementVerbs = ["ends up", "end up", "lands", "land", "goes", "go", "is copied", "are copied",
                                 "gets copied", "get copied", "copied", "copies", "is placed", "are placed", "is put",
                                 "puts", "put", "places", "will be", "is at", "are at", "becomes", "become",
                                 "appears", "appear", "lives", "live", "shows up", "is written", "is saved",
                                 "is available", "sits", "is stored", "moves", "turns into"]
    static let resultVerbs = ["you get", "you'll get", "you will get", "gives you", "the image has",
                              "the image will have", "the image contains", "you end up with", "ends up with",
                              "you'll have", "you will have", "creates", "produces", "results in", "you'll see",
                              "you will see", "the container has", "you'd get", "you would get"]
    /// Between a file and a path, these start another clause: the path is about something else.
    static let clauseBreaks = [";", ",", ":", "(", " then ", " while ", " whereas "]
    static let negations = ["not", "never", "isn't", "aren't", "doesn't", "don't", "won't", "wouldn't", "can't",
                            "cannot", "nothing"]
    static let contrasts = ["instead of", "rather than", "unlike", "not", "avoid", "don't use", "do not use",
                            "as opposed to", "versus", "vs"]

    // `RUN cd`
    static let later = ["persists", "persist", "carries over", "carry over", "stays", "remains", "from then on",
                        "from there on", "for the next", "for later", "for all later", "for every later",
                        "for the rest", "for subsequent", "for the following", "so the next", "so later",
                        "so subsequent", "so every", "so all", "changes the directory for",
                        "sets the working directory",
                        "sets the directory", "later instructions run in", "subsequent instructions run in",
                        "the next instruction runs in", "later commands run in", "subsequent commands run in",
                        "the following commands run in", "every later", "all later"]
    static let lastsOneRun = ["does not", "doesn't", "won't", "will not", "not carry", "no effect", "only for that",
                              "only affects", "only applies", "only lasts", "only for the", "new shell", "fresh shell",
                              "own shell", "is lost", "is reset", "resets", "not persist", "not last", "again",
                              "starts in", "start in", "back in", "back to"]

    // `ARG` before `FROM`
    static let before = ["before", "above", "ahead of", "prior to", "preceding", "outside"]
    static let usable = ["available", "usable", "can use", "can be used", "visible", "in scope", "accessible",
                         "can reference", "can be referenced", "works", "applies", "is set"]
    static let inStage = ["in the stage", "inside the stage", "in every stage", "in all stages", "throughout",
                          "later instructions", "later in the", "after the from", "after from", "subsequent",
                          "in run", "in copy", "in env", "in the build", "build steps", "everywhere", "anywhere",
                          "in the rest", "below it", "below the", "in your run", "in a run", "in the run"]
    static let outOfStage = ["not available", "isn't available", "is not available", "not usable", "not visible",
                             "isn't visible", "out of scope", "goes out of scope", "won't be", "will not be",
                             "empty", "redeclare", "re-declare", "declare it again", "again after", "again inside",
                             "only in the from", "only for the from", "only the from", "only usable in",
                             "only available to", "only available in", "only in from", "only for from", "unset",
                             "not set", "isn't set", "cannot", "can't", "unless"]

    // Values across stages
    static let stageWords = ["previous stage", "earlier stage", "build stage", "builder stage", "first stage",
                             "other stage", "another stage", "next stage", "later stage", "final stage",
                             "runtime stage",
                             "between stages", "across stages", "one stage to", "each stage", "every stage",
                             "other stages", "later stages", "next stages", "the builder"]
    static let carry = ["carry", "carries", "carried", "inherit", "inherits", "inherited", "available in the",
                        "visible in the", "persist", "persists", "kept in", "passed to", "passes to", "flow",
                        "flows", "leak", "leaks", "still set", "still available", "also set", "also available",
                        "copied over", "carry over", "carries over"]
    static let staysInStage = ["never", "start fresh", "starts fresh", "reset", "resets",
                               "redeclare", "lost", "only within", "scoped to", "per stage", "per-stage",
                               "only in that stage", "unless", "only if", "only when", "only through"]

    // `ARG` when the container runs
    static let runtime = ["at runtime", "at run time", "when the container runs", "when the container starts",
                          "when you run the container", "running container", "to the application",
                          "to your application", "to your app", "to the app", "container's environment",
                          "in the container", "inside the container", "at container start", "process.env",
                          "os.environ", "docker run"]
    static let buildOnly = ["only at build", "only during the build", "only during build", "build-time only",
                            "build time only", "only exists during", "only available during", "only while",
                            "not available", "isn't available", "is not available", "aren't available",
                            "are not available", "not at runtime", "not in the running", "not in the container",
                            "doesn't persist", "does not persist", "don't persist", "do not persist", "won't be",
                            "will not be", "not kept", "isn't kept", "gone", "disappears", "need env", "needs env",
                            "use env", "copy it into", "promote it", "unless"]

    // `WORKDIR`
    static let createsAnyway = ["no need to mkdir", "don't need to mkdir", "doesn't need to exist",
                                "does not need to exist", "need not exist", "doesn't have to exist",
                                "does not have to exist", "no need to create", "don't need to create",
                                "doesn't need mkdir", "does not need mkdir", "don't need mkdir", "no need for mkdir",
                                "without mkdir", "won't fail", "will not fail", "doesn't fail", "does not fail",
                                "never fails"]
    static let mustExist = ["doesn't create", "does not create", "won't create", "will not create", "fails if",
                            "will fail if", "errors if", "error if", "must exist", "must already exist",
                            "has to exist", "needs to exist", "need to exist", "create it first",
                            "create the directory first", "mkdir it first", "mkdir the directory first",
                            "needs a mkdir", "need a mkdir"]
    static let creates = ["creates", "will create", "is created", "gets created", "makes the directory",
                          "makes it for you"]

    // `COPY` of a directory
    static let folders = ["folder", "directory", "dir"]
    static let notTheFolder = ["doesn't copy the", "does not copy the", "won't copy the", "never copies the",
                               "isn't copied", "is not copied", "not the folder itself", "not the directory itself",
                               "not the folder", "not the directory"]
    static let notOnlyContents = ["not just", "not only"]
    static let contents = ["contents", "content of", "what is inside", "what's inside", "everything inside",
                           "files inside"]
    static let itself = ["itself", "the folder too", "the directory too", "including the folder",
                         "including the directory", "keeps the folder", "keeps the directory",
                         "preserves the folder", "preserves the directory", "folder and its contents",
                         "directory and its contents", "folder along with", "directory along with"]
}
