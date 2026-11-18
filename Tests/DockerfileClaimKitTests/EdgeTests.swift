@testable import DockerfileClaimKit
import Testing

/// Branches the main suites do not reach on their own.
@Suite("Edges")
struct EdgeTests {
    @Test("Small helpers")
    func helpers() {
        #expect(ImagePath.lastName("src/index.js") == "index.js" && ImagePath.lastName("src/") == "src")
        #expect(Substitution { _ in .unset }.word("a\\") == "a")
        #expect(DockerfileFinding.condition(.classicBuilderStops).contains("classic builder stops"))
        #expect(Words.contains("a -v b", "-v") && !Words.contains("pipeline", "pip") && Words.contains("pip", "pip"))
        #expect(Words.contains("x env:", "env:") && !Words.contains("xenv:", "env:"))
        #expect(GoMatch.matches("[a-]", "-") && GoMatch.matches("[^a-c]", "d") && GoMatch.matches("[\\a-c]", "b"))
        #expect(AnswerBlocks.split("```\nFROM a").first?.kind == .code(""))
        #expect(StatementReader.variable(["V_2"], after: "ARG") == "V_2")
        #expect(PlacementReader(dockerfile: nil, source: .sentence, dockerignore: nil)
            .claims(in: "`COPY a.txt /x/` puts `a.txt` at `/x/a.txt`.").count == 1)
    }

    @Test("Stage splitting edge cases")
    func stages() {
        let split = Stage.split(Dockerfile("MAINTAINER me\nARG X\nARG Y=$X$Z\nFROM $NOPE\nFROM"))
        #expect(split.globals["X"] == .unknown && split.globals["Y"] == .unknown)
        #expect(split.stages.map(\.base) == [.image(""), .image("")])
        let defaults = Stage.split(Dockerfile("ARG A=1\nARG B=$A$C\nFROM scratch")).globals
        #expect(defaults["B"] == .text("1"))
        let model = DockerfileModel(Dockerfile("FROM scratch AS a\nENV E=1\nENV F=$E$G\nARG H=$E"))
        #expect(model.declaredAnywhere["F"] == .text("1") && model.declaredAnywhere["H"] == .text("1"))
    }

    @Test("Sentence-only statements judged with no Dockerfile")
    func noDockerfile() {
        let report = check("In a Dockerfile, an `ARG VERSION` declared before `FROM` is available in every stage. "
                           + "`ARG` values are available at runtime. `ENV APP_ENV` values carry over into the final stage. "
                           + "RUN cd stays for later instructions. COPY copies the folder itself.")
        #expect(slips(report) == [.argBeforeFrom, .argIsBuildOnly, .runCdDoesNotPersist])
        #expect(report.findings.contains { $0.outcome == .caveat(.onlyIfBuiltFrom) })
        #expect(report.findings.first { $0.claim.kind == .runCd }?.claim.subject == "")
    }

    @Test("Placement edges")
    func placements() {
        #expect(outcome("You get `/app/src/src`.", file: "FROM scratch\nCOPY src /app/src") == .wrong(.copiesDirectoryItself))
        #expect(outcome("`a.txt` lands at `/opt/a.txt`.", file: "FROM scratch\nCOPY . /app")
            == .unchecked("Docker puts it at `/app/a.txt`, and no known misreading leads to `/opt/a.txt`"))
        let two = check(block("FROM alpine\nRUN cd /a\nRUN echo $V $V\nCOPY x y /z"))
        #expect(two.findings.map(\.claim.subject) == ["RUN cd /a", "COPY x y /z"])
    }
}
