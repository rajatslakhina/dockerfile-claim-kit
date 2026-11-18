@testable import DockerfileClaimKit
import Testing

@Suite("Judging claims")
struct EvaluatorTests {
    @Test("Each slip behind a wrong placement is named", arguments: [
        ("FROM scratch\nCOPY src /app", "`src/index.js` ends up at `/app/src/index.js`.", .copiesDirectoryItself),
        ("FROM scratch\nCOPY src/*.js /app/", "`src/a.js` is copied to `/app/src/a.js`.", .globKeepsPath),
        ("FROM scratch\nWORKDIR /srv\nCOPY a.txt app/", "`a.txt` lands at `/app/a.txt`.", .workdirIgnored),
        ("FROM scratch\nCOPY a.txt /app", "`a.txt` goes to `/app/a.txt`.", .destinationNotDirectory),
        ("ARG D=pre\nFROM scratch\nCOPY a.txt /$D/", "`a.txt` lands at `/pre/a.txt`.", .argBeforeFrom),
        ("FROM scratch AS b\nENV D=e\nFROM scratch\nCOPY a.txt /$D/", "`a.txt` lands at `/e/a.txt`.",
         .stageStartsFresh)
    ] as [(String, String, DockerfileFinding.Slip)])
    func placementSlips(_ file: String, _ sentence: String, _ slip: DockerfileFinding.Slip) {
        #expect(outcome(sentence, file: file) == .wrong(slip))
    }

    @Test("A file the .dockerignore leaves out is never copied")
    func dockerignore() {
        let answer = block("FROM scratch\nCOPY . /app/") + "\n\nAdd a `.dockerignore`:\n\n```\n**/*.log\n```\n\n"
            + "With that Dockerfile, `logs/a.log` ends up at `/app/logs/a.log`."
        let finding = check(answer).findings.first { $0.claim.isExplicit }
        #expect(finding?.outcome == .wrong(.excludedByDockerignore))
        #expect(finding?.explanation.contains("keeps it out of the build context") == true)
    }

    @Test("Placements that hold, hold with a caveat, or cannot be checked")
    func placementOutcomes() {
        #expect(outcome("`src/index.js` ends up at `/app/src/index.js`.") == .exact)
        #expect(outcome("`package.json` is copied into `/app`.") == .exact)
        #expect(outcome("`src/` lands at `/app/src`.") == .exact)
        #expect(outcome("`COPY a.txt /data` puts `a.txt` at `/data/a.txt`.")
            == .caveat(.placement(.insideIfDirectory("/data"))))
        #expect(outcome("`README.md` ends up at `/app/README.md`.")
            == .unchecked("no COPY or ADD line copies `README.md`"))
        #expect(outcome("`src/a.js` lands at `/opt/a.js`.") == .unchecked(
            "Docker puts it at `/app/src/a.js`, and no known misreading leads to `/opt/a.js`"))
        #expect(outcome("`src/a.js` lands at `/a.js`.", file: "FROM scratch\nARG D\nCOPY src /$D/") != nil)
        #expect(outcome("`a.txt` is at `/y/a.txt`.", file: "FROM scratch\nCOPY a.txt /x/\nRUN mv /x/a.txt /y")
            == .unchecked("line 3 runs a command that may move or remove files"))
        #expect(outcome("`a.txt` lands at `/x/a.txt`.", file: "FROM scratch\nCOPY a.txt b.txt /x")
            == .caveat(.placement(.classicStops)))
        #expect(outcome("`a.txt` lands at `/x/a.txt`.", file: "FROM scratch\nCOPY a.txt b.txt /x", policy: .classic)
            == .wrong(.destinationNeedsSlash))
        #expect(outcome("`a.txt` lands at `/x/a.txt`.", file: "FROM scratch\nCOPY a.txt b.txt /x", policy: .buildKit)
            == .unchecked("BuildKit's handling of several sources was not checked"))
        let deep = "FROM scratch\nCOPY src/**/a.js /x/"
        #expect(outcome("`src/d/a.js` lands at `/x/a.js`.", file: deep) == .caveat(.placement(.doubleStar)))
        #expect(outcome("`src/d/a.js` lands at `/x/a.js`.", file: deep, policy: .classic) == .exact)
        #expect(outcome("`COPY a.txt /data` puts `a.txt` at `/data/a.txt`.", policy: .lenient) == .exact)
    }

    @Test("A sentence that names only the image path is traced back to a COPY source")
    func destinationOnly() {
        #expect(outcome("With `COPY src /app/src` you get `/app/src/src/index.js`.") == .wrong(.copiesDirectoryItself))
        #expect(outcome("This gives you `/app/src/index.js`.") == .exact)
        #expect(outcome("You end up with `/app/package.json`.") == .exact)
        #expect(outcome("You get `/opt/x.js`.") == .unchecked("no COPY or ADD line writes to `/opt/x.js`"))
        #expect(outcome("You get `/srv/a.js`.", file: "FROM scratch\nCOPY . /srv") == .exact)
        #expect(outcome("You get `/app/a.txt`.", file: "FROM node\nCOPY a.txt /app") != nil)
        #expect(outcome("You get `/app`.", file: "FROM scratch\nCOPY a.txt /app") == .exact)
        #expect(outcome("Since `src/src/a.js` exists, you get `/app/src/a.js`.",
                        file: "FROM scratch\nCOPY src /app") == .exact)
        let found = check(block("FROM scratch\nCOPY src /app") + "\n\nYou get `/app/src/a.js`.").findings[0]
        #expect(found.actual == ["/app/a.js"])
        #expect(DockerfileEvaluator.sources(DockerfileModel(Dockerfile(""))).isEmpty)
    }

    @Test("Statements about Dockerfile rules", arguments: [
        ("`COPY src /app` copies the folder itself.", .wrong(.copiesDirectoryItself)),
        ("`COPY src /app` copies the contents of the folder.", .exact),
        ("`RUN cd /app` makes the following commands run in `/app`.", .wrong(.runCdDoesNotPersist)),
        ("`RUN cd /app` only applies to that `RUN`.", .exact),
        ("An `ARG VERSION` declared before `FROM` is available in every stage.", .wrong(.argBeforeFrom)),
        ("An `ARG` before `FROM` is not available inside the stage unless you redeclare it.", .exact),
        ("`ARG` values carry over into the final stage.", .wrong(.stageStartsFresh)),
        ("`ENV` values carry over into the final stage.", .caveat(.onlyIfBuiltFrom)),
        ("`ENV` values set in the build stage do not carry into the final stage.", .exact),
        ("`ARG` values are available at runtime.", .wrong(.argIsBuildOnly)),
        ("`ARG` values exist only during the build, not at runtime.", .exact),
        ("`WORKDIR` creates the directory if it is missing.", .exact),
        ("`WORKDIR` fails if the directory does not exist yet.", .wrong(.workdirCreatesDirectory))
    ] as [(String, DockerfileFinding.Outcome)])
    func statements(_ sentence: String, _ expected: DockerfileFinding.Outcome) {
        #expect(outcome(sentence) == expected)
    }

    @Test("Statements read against the answer's Dockerfile")
    func statementsAgainstFile() {
        let redeclared = "ARG VERSION=1\nFROM alpine\nARG VERSION\nRUN echo $VERSION"
        #expect(outcome("The `VERSION` ARG before `FROM` is available in `RUN`.", file: redeclared) == .exact)
        let chained = "FROM node AS build\nENV NODE_ENV=production\nFROM build\nCMD node a.js"
        #expect(outcome("`ENV NODE_ENV` from the build stage is still set in the final stage.", file: chained) == .exact)
        let fresh = "FROM node AS build\nENV NODE_ENV=production\nFROM node\nCMD node a.js"
        #expect(outcome("`ENV NODE_ENV` from the build stage is still set in the final stage.", file: fresh)
            == .wrong(.stageStartsFresh))
        let kept = "FROM node\nARG PORT=80\nENV PORT=$PORT\nCMD node a.js"
        #expect(outcome("The `PORT` ARG is available to your app at runtime.", file: kept) == .exact)
        #expect(outcome("The `PORT` ARG is available to your app at runtime.") == .wrong(.argIsBuildOnly))
        let fix = check(block(nodeFile) + "\n\nThe `PORT` ARG is available to your app at runtime.").findings[0].fix
        #expect(fix == "ENV PORT=$PORT")
        #expect(check("`RUN cd app` stays for later instructions in the Dockerfile.").findings[0].fix == "WORKDIR")
    }

    @Test("Dockerfile lines that do not do what they say", arguments: [
        ("FROM alpine\nRUN cd /app\nRUN make", DockerfileFinding.Outcome.wrong(.runCdDoesNotPersist), "WORKDIR /app"),
        ("ARG V=1\nFROM alpine\nRUN echo $V", .wrong(.argBeforeFrom), "ARG V"),
        ("FROM alpine AS a\nENV P=1\nFROM alpine\nRUN echo $P", .wrong(.stageStartsFresh), nil),
        ("FROM alpine\nARG P=1\nCMD echo $P", .wrong(.argIsBuildOnly), "ENV P=$P"),
        ("FROM alpine\nENV P=1\nCMD [\"echo\", \"$P\"]", .wrong(.execFormNoShell), "CMD [\"sh\", \"-c\", \"echo $P\"]"),
        ("FROM alpine\nCOPY a b /x", .caveat(.classicBuilderStops), "/x/")
    ] as [(String, DockerfileFinding.Outcome, String?)])
    func lines(_ file: String, _ expected: DockerfileFinding.Outcome, _ fix: String?) {
        let finding = check(block(file)).findings.first
        #expect(finding?.outcome == expected)
        #expect(finding?.fix == fix)
    }

    @Test("A line that stops only the classic builder depends on the policy")
    func linePolicy() {
        let file = block("FROM alpine\nCOPY a b .")
        #expect(check(file, policy: .classic).findings[0].outcome == .wrong(.destinationNeedsSlash))
        #expect(check(file, policy: .buildKit).verdict == .unchecked)
        #expect(check(file, policy: .lenient).verdict == .noClaims)
        #expect(check(file).findings[0].explanation.hasPrefix("`COPY a b .` stops the classic builder"))
    }

    @Test("Lines that work make no finding")
    func cleanLines() {
        let file = """
        ARG V=1
        FROM alpine:$V AS build
        ARG V
        ENV P=8080
        WORKDIR /app
        COPY a b ./
        COPY a b $DEST
        RUN cd /app && make
        RUN for F in a b; do echo $F; done
        RUN X=1 && echo $X
        RUN echo $UNDECLARED '$P'
        RUN ["sh", "-c", "echo $P"]
        CMD ["/bin/bash", "-c", "echo $V"]
        ENTRYPOINT echo $P
        RUN cd /tmp
        """
        #expect(check(block(file)).verdict == .noClaims)
    }
}
