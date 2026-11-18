@testable import DockerfileClaimKit
import DockerignoreClaimKit
import Testing

@Suite("Dockerfile model")
struct ModelTests {
    func lookup(_ values: [String: VariableValue]) -> Substitution {
        Substitution { values[$0] ?? .unset }
    }

    @Test("Variables expand the way Docker's word processing does")
    func substitution() {
        let words = lookup(["A": .text("x"), "E": .text(""), "U": .unknown])
        #expect(words.word("$A/${A}y") == "x/xy")
        #expect(words.word("${A:-d} ${E:-d} ${N:-d} ${E-d} ${N-d}") == "x d d  d")
        #expect(words.word("${A:+p} ${E:+p} ${A+p} ${E+p} ${N+p}") == "p  p p ")
        #expect(words.word("'$A' \"$A\" \\$A $ $1 \"a\\\"b\\$c\\\\d\\e\"") == "$A x $A $ $1 a\"b$c\\d\\e")
        #expect(words.word("$U") == nil)
        #expect(words.word("${U:-d}") == nil)
        #expect(words.word("\"$U\"") == nil)
        #expect(words.word("${A#x}") == nil)
        #expect(words.word("${A:}") == nil)
        #expect(words.word("${A") == nil)
        #expect(words.word("a$") == "a$")
        #expect(words.words("a  'b c' d") == ["a", "b c", "d"])
        #expect(words.word("") == "")
        #expect(Substitution.rawWords("a \"b c\" 'd e' f\\ g") == ["a", "\"b c\"", "'d e'", "f\\ g"])
        #expect(Substitution.references(in: "$A ${B} '$C' \\$D \"$E\" $1 ${") == ["A", "B", "E"])
    }

    @Test("Go's filepath.Match, one segment at a time")
    func goMatch() {
        #expect(GoMatch.matches("*.txt", "a.txt"))
        #expect(!GoMatch.matches("*.txt", "a.md"))
        #expect(GoMatch.matches("?.txt", "a.txt") && !GoMatch.matches("?.txt", "ab.txt"))
        #expect(GoMatch.matches("[a-c].txt", "b.txt") && !GoMatch.matches("[a-c].txt", "d.txt"))
        #expect(GoMatch.matches("[^a].txt", "b.txt") && !GoMatch.matches("[^a].txt", "a.txt"))
        #expect(GoMatch.matches("[\\]].txt", "].txt"))
        #expect(GoMatch.matches("a\\*b", "a*b") && !GoMatch.matches("a\\*b", "axb"))
        #expect(!GoMatch.matches("a\\", "a"))
        #expect(!GoMatch.matches("[a", "a") && !GoMatch.matches("[a-", "a") && !GoMatch.matches("[\\", "a"))
        #expect(!GoMatch.matches("[a]", "") && !GoMatch.matches("?", ""))
    }

    @Test("The parser joins lines, drops comments and skips heredocs")
    func parser() {
        let file = Dockerfile("# syntax=docker/dockerfile:1\nFROM alpine\n\n# note\nRUN echo a \\\n  b\nRUN <<EOF\necho hi\nEOF\ncopy a /b\nRUN x \\")
        #expect(file.instructions.map(\.keyword) == ["FROM", "RUN", "RUN", "COPY", "RUN"])
        #expect(file.instructions[1].arguments == "echo a b")
        #expect(file.instructions[2].hasHeredoc && file.instructions[3].lineNumber == 10)
        #expect(file.instructions[0].text == "FROM alpine")
        #expect(DockerfileInstruction(keyword: "RUN", arguments: "", lineNumber: 1, hasHeredoc: false).text == "RUN")
        #expect(Dockerfile("# escape=`\nFROM scratch\nCOPY a `\n  /b/").instructions[1].arguments == "a /b/")
        #expect(Dockerfile("# escape=\\\nFROM scratch").escape == "\\")
        #expect(Dockerfile.heredocTerminator("<<") == nil)
        #expect(Dockerfile.looksLikeDockerfile("ARG V=1\nFROM alpine:$V\nRUN x"))
        #expect(!Dockerfile.looksLikeDockerfile("SELECT * FROM users"))
        #expect(!Dockerfile.looksLikeDockerfile("FROM a\nfoo\nbar\nbaz"))
        #expect(!Dockerfile.looksLikeDockerfile(""))
    }

    @Test("Paths are cleaned the way Go cleans them")
    func paths() {
        #expect(ImagePath.clean("/a/./b/../c//d/") == "/a/c/d")
        #expect(ImagePath.clean("/../a") == "/a")
        #expect(ImagePath.resolve("b", against: "/a") == "/a/b")
        #expect(ImagePath.join("/", "a") == "/a" && ImagePath.join("/a", "") == "/a")
        #expect(ImagePath.ancestors("/a/b/c") == ["/", "/a", "/a/b"])
        #expect(ImagePath.relative("./src/") == "src")
        #expect(SourceMatch.match("../x", "x") == nil)
        #expect(SourceMatch.match("src", "srcx/a") == nil)
        #expect(SourceMatch.match("*.js", "a/b.js") == nil)
    }

    func placements(_ file: String, _ path: String, ignore: String? = nil) -> PlacementResult {
        DockerfileModel(Dockerfile(file), dockerignore: ignore.map(DockerignoreRules.init)).placements(of: path)
    }

    @Test("An image base leaves the working directory and existing directories open")
    func openBase() {
        let relative = placements("FROM node:20\nCOPY a.txt app/", "a.txt").placements
        #expect(relative == [Placement(path: "/app/a.txt", lineNumber: 2, caveats: [.baseImageWorkdir])])
        let named = placements("FROM node:20\nCOPY a.txt /app", "a.txt").placements
        #expect(named.map(\.path) == ["/app", "/app/a.txt"])
        #expect(named.map(\.caveats) == [[.renamedUnlessDirectory("/app")], [.insideIfDirectory("/app")]])
        #expect(placements("FROM node:20\nCOPY nginx.conf /etc/nginx/default.conf", "nginx.conf").placements
            == [Placement(path: "/etc/nginx/default.conf", lineNumber: 2, caveats: [])])
        #expect(placements("FROM node:20\nCOPY Makefile /src/Makefile", "Makefile").paths == ["/src/Makefile"])
        let rewritten = placements("FROM scratch\nCOPY src /app\nCOPY a.txt /app", "a.txt").paths
        #expect(rewritten == ["/app", "/app/a.txt"])
        #expect(placements("FROM node:20\nWORKDIR app\nWORKDIR /srv\nCOPY a.txt .", "a.txt").paths == ["/srv/a.txt"])
        #expect(placements("FROM node:20\nWORKDIR $HOME\nCOPY a.txt x/", "a.txt").placements[0].caveats
            == [.baseImageWorkdir])
    }

    @Test("Unknown values and unmodelled forms are reported, not guessed")
    func unknowns() {
        #expect(placements("FROM scratch\nARG D\nCOPY a.txt /$D/", "a.txt").unknown != nil)
        #expect(placements("FROM scratch\nCOPY --parents a.txt /x/", "a.txt").unknown != nil)
        #expect(placements("FROM scratch\nADD a.tar.gz /x/", "a.tar.gz").unknown != nil)
        #expect(placements("FROM scratch\nCOPY a.txt /x/\nRUN mv /x/a.txt /y", "a.txt").unknown != nil)
        #expect(placements("FROM scratch\nCOPY <<EOF /x\nhi\nEOF", "a.txt").placements.isEmpty)
        #expect(placements("FROM scratch\nCOPY a.txt", "a.txt").placements.isEmpty)
        #expect(placements("FROM scratch\nCOPY --from=nowhere /a /b/", "a").placements.isEmpty)
        #expect(placements("FROM scratch\nCOPY --from=$S /a /b/", "a").placements.isEmpty)
        #expect(placements("FROM scratch\nCOPY a.txt b.txt /x", "a.txt").placements[0].caveats == [.classicStops])
        #expect(placements("FROM scratch\nCOPY src/**/a.js /x/", "src/d/a.js").placements[0].caveats == [.doubleStar])
        #expect(placements("ARG B=scratch\nFROM ${B}\nCOPY a.txt /x", "a.txt").paths == ["/x"])
        #expect(placements("", "a.txt").paths.isEmpty)
    }

    @Test("A stage built on another keeps its values and files; ARG values stay behind")
    func stages() {
        let file = "FROM scratch AS base\nARG A=1\nENV E=2\nFROM base\nCOPY a.txt /$A$E/"
        #expect(placements(file, "a.txt").paths == ["/2/a.txt"])
        let model = DockerfileModel(Dockerfile(file))
        #expect(model.declaredAnywhere["A"] == .text("1") && model.declaredAnywhere["E"] == .text("2"))
        #expect(model.placements(of: "a.txt", reading: .otherStagesInScope).paths == ["/12/a.txt"])
        let stages = Stage.split(Dockerfile("FROM node AS a\nFROM a AS b\nFROM b")).stages
        #expect(stages[2].ancestors(in: stages).map(\.index) == [1, 0])
        #expect(stages[2].isOpen(in: stages) && !Stage.split(Dockerfile("FROM scratch")).stages[0].isOpen(in: []))
        #expect(Declarations.env("", Substitution { _ in .unset }).isEmpty)
        #expect(Declarations.env("A=$U B", Substitution { _ in .unknown }).map(\.1) == [.unknown])
        #expect(Declarations.env("A $U", Substitution { _ in .unknown }).map(\.1) == [.unknown])
        #expect(Declarations.args("A=$U", Substitution { _ in .unknown }).map(\.1) == [.unknown])
        #expect(Declarations.names(DockerfileInstruction(keyword: "RUN", arguments: "x", lineNumber: 1,
                                                         hasHeredoc: false)).isEmpty)
    }
}
