@testable import DockerfileClaimKit
import Testing

@Suite("Reading answers")
struct ReaderTests {
    @Test("Dockerfiles are found by tag or by shape")
    func blocks() {
        #expect(DockerfileClaimReader.isAboutDockerfile(block("FROM alpine", tag: "")))
        #expect(DockerfileClaimReader.isAboutDockerfile("Use a Containerfile."))
        #expect(!DockerfileClaimReader.isAboutDockerfile(block("FROM alpine", tag: "sql")))
        #expect(!DockerfileClaimReader.isAboutDockerfile("Plain prose."))
        let blocks = AnswerBlocks.split(block("FROM a", tag: "docker") + "\n\ntext\n\n" + block("FROM b", tag: "containerfile"))
        #expect(DockerfileBlock.find(in: blocks).map(\.number) == [1, 2])
        let ignoreTagged = AnswerBlocks.split(block("x", tag: "dockerignore"))
        #expect(DockerfileBlock.dockerignore(in: ignoreTagged) == "x")
        let ignoreNamed = AnswerBlocks.split("Your .dockerignore:\n\n" + block("node_modules", tag: ""))
        #expect(DockerfileBlock.dockerignore(in: ignoreNamed) == "node_modules")
        let unnamed = AnswerBlocks.split("Some file:\n\n" + block("node_modules", tag: ""))
        #expect(DockerfileBlock.dockerignore(in: unnamed) == nil)
        #expect(DockerfileBlock.dockerignore(in: AnswerBlocks.split(block("FROM a"))) == nil)
    }

    @Test("A sentence is read against the nearest Dockerfile before it, else the first after it")
    func nearest() {
        let answer = "`a.txt` ends up at `/one/a.txt`.\n\n" + block("FROM scratch\nCOPY a.txt /one/") + "\n\n"
            + block("FROM scratch\nCOPY a.txt /two/") + "\n\n`a.txt` ends up at `/two/a.txt`."
        let report = check(answer)
        #expect(report.verdict == .verified && report.findings.map(\.claim.source) == [.dockerfile(1), .dockerfile(2)])
    }

    @Test("Placement sentence shapes")
    func shapes() {
        let reader = PlacementReader(dockerfile: Dockerfile(nodeFile), source: .dockerfile(1), dockerignore: nil)
        let targets = { (sentence: String) in reader.claims(in: sentence).map(\.target) }
        #expect(targets("`src/a.js` lands in `/app/src/`.") == ["/app/src/a.js"])
        #expect(targets("`src/a.js` lands in `/app/src/a.js`.") == ["/app/src/a.js"])
        #expect(targets("`src/a.js` is copied to `/app/src/`.") == ["/app/src/a.js"])
        #expect(targets("`src` is copied into `/app`.").isEmpty)
        #expect(targets("`src/a.js` is not copied to `/app/src/a.js`.").isEmpty)
        #expect(targets("`src/a.js` lands at `/app/src/a.js`, not `/app/src/src/a.js`.") == ["/app/src/a.js"])
        #expect(targets("Rather than `src/a.js`, `lib/b.js` goes to `/app/b.js`.") == ["/app/b.js"])
        #expect(targets("Does `src/a.js` land at `/app/a.js`?").isEmpty)
        #expect(targets("You don't get `/app/src/src/a.js`.").isEmpty)
        #expect(targets("`src/a.js` sits next to `/app`.").isEmpty)
        #expect(targets("`package.json` goes to `/app/package.json`.") == ["/app/package.json"])
        #expect(targets("Now `src/a.js` and then `/app/x` follow.").isEmpty)
        #expect(targets("Paths like `//net` or `/a b` or `/$X` are skipped; `-v` too.").isEmpty)
        #expect(PlacementReader.isDirectory("Makefile") == false && PlacementReader.isDirectory("src/") == true)
        #expect(PlacementReader.isDirectory(".") && PlacementReader.isDirectory("lib"))
        #expect(PlacementReader(dockerfile: nil, source: .sentence, dockerignore: nil).claims(in: "`a.txt` is at `/a`.").isEmpty)
    }

    @Test("Statement shapes that make no claim")
    func quietStatements() {
        let quiet = [
            "Instead of `RUN cd /app`, use `WORKDIR /app` so later instructions run there.",
            "`RUN cd /app && make` builds in `/app`.",
            "An `ARG` before `FROM` sets the base image tag.",
            "Is an `ARG` before `FROM` available in the stage?",
            "`WORKDIR /app` sets the working directory.",
            "`COPY src /app` copies the folder into `/app`.",
            "An `ARG` and an `ENV` are both available at runtime.",
            "`ENV` values in the base image are inherited."
        ]
        for sentence in quiet {
            #expect(StatementReader.claims(in: sentence).isEmpty, "\(sentence)")
        }
        #expect(StatementReader.variable(["ARG"], after: "ARG") == nil)
        #expect(StatementReader.variable(["${HOME}"], after: "ARG") == "HOME")
        #expect(StatementReader.claims(in: "`COPY src /app` does not copy the folder itself, only its files.").map(\.assertion) == [.copiesContents])
        #expect(StatementReader.claims(in: "`COPY src /app` copies not just the contents of the folder.").map(\.assertion) == [.copiesDirectory])
        #expect(StatementReader.claims(in: "`WORKDIR` makes the directory, it does not need to exist.").map(\.assertion) == [.creates])
    }

    @Test("Claims restated by a line are kept once")
    func deduplicated() {
        let line = DockerfileClaim(kind: .runCd, subject: "/a", assertion: .persists, sentence: "", isExplicit: false)
        let said = DockerfileClaim(kind: .runCd, subject: "/a", assertion: .persists, sentence: "x")
        #expect(DockerfileClaimReader.deduplicated([line, said, said]) == [said])
        #expect(DockerfileClaimReader(checksLines: false).claims(in: block("FROM a\nRUN cd /x\nRUN y")).isEmpty)
    }
}
