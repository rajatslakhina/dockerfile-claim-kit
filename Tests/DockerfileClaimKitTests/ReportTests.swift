@testable import DockerfileClaimKit
import Testing

@Suite("Reports and the ledger")
struct ReportTests {
    @Test("Verdicts, notes, feedback and summaries")
    func reports() {
        let none = check("Hello.")
        #expect(none.verdict == .noClaims && none.note == nil && none.feedback == nil)
        #expect(none.summary == "no claims about a Dockerfile")
        let held = check(block(nodeFile) + "\n\n`src/index.js` ends up at `/app/src/index.js`.")
        #expect(held.verdict == .verified && held.summary == "1 claim checked, 1 hold" && held.flagged.isEmpty)
        #expect(held.findings[0].explanation == "It holds that `src/index.js` ends up at `/app/src/index.js`.")
        let unchecked = check(block(nodeFile) + "\n\nYou get `/opt/x`.")
        #expect(unchecked.verdict == .unchecked && unchecked.summary.contains("1 unchecked"))
        #expect(unchecked.findings[0].explanation.hasPrefix("Could not check that `a file` ends up at `/opt/x`"))
        let caution = check(block("FROM alpine\nCOPY a b /x"))
        #expect(caution.verdict == .caution && caution.summary.contains("1 to check"))
        let wrong = check(block("FROM alpine\nRUN cd /app\nRUN make") + "\n\n`RUN cd /app` persists for the next steps.")
        #expect(wrong.verdict == .wrong && wrong.summary == "2 claims checked, 0 hold, 2 wrong")
        #expect(wrong.note?.hasPrefix("Dockerfile check: It does not hold that `RUN cd /app` works as written") == true)
        #expect(wrong.feedback?.hasPrefix("Some of what your answer says about the Dockerfile does not hold:\n- ") == true)
        let unnamed = check(block("FROM scratch\nCOPY src /app") + "\n\n`src/a.js` lands at `/opt/a.js`.")
        #expect(unnamed.findings[0].explanation == "Could not check that `src/a.js` ends up at `/opt/a.js`: Docker puts "
            + "it at `/app/a.js`, and no known misreading leads to `/opt/a.js`.")
        let plain = DockerfileClaim(kind: .placement, subject: "a", target: "/b", assertion: .landsAt, sentence: "")
        #expect(DockerfileFinding(claim: plain, outcome: .wrong(nil), actual: ["/c"]).explanation
            == "It does not hold that `a` ends up at `/b`; Docker puts it at `/c`.")
    }

    @Test("Every caveat and slip has wording")
    func wording() {
        let claim = DockerfileClaim(kind: .placement, subject: "a", target: "/b", assertion: .landsAt, sentence: "")
        let caveats: [DockerfileFinding.Caveat] = [.placement(.insideIfDirectory("/b")), .placement(.baseImageWorkdir),
                                                   .placement(.renamedUnlessDirectory("/b")),
                                                   .placement(.globMatchesOne), .placement(.classicStops),
                                                   .placement(.doubleStar), .onlyIfBuiltFrom]
        for caveat in caveats {
            #expect(DockerfileFinding(claim: claim, outcome: .caveat(caveat)).explanation.hasPrefix("It holds that"))
        }
        for slip in DockerfileFinding.Slip.allCases {
            #expect(DockerfileFinding(claim: claim, outcome: .wrong(slip)).explanation.count > 40)
        }
        let probe = DockerfileFinding(claim: claim, outcome: .wrong(nil), actual: ["/x/" + DockerfileEvaluator.child])
        #expect(probe.where_.isEmpty)
        let line = DockerfileClaim(kind: .line, subject: "RUN x", assertion: .worksAsWritten, sentence: "")
        #expect(DockerfileFinding(claim: line, outcome: .exact).explanation == "It holds that `RUN x` works as written.")
        #expect(DockerfileFinding(claim: line, outcome: .wrong(nil), actual: ["/a"]).where_.isEmpty)
        let statements: [(DockerfileClaim.Kind, DockerfileClaim.Assertion)] = [
            (.directoryCopy, .copiesDirectory), (.directoryCopy, .copiesContents), (.runCd, .persists),
            (.runCd, .doesNotPersist), (.argBeforeFrom, .available), (.argBeforeFrom, .notAvailable),
            (.stageScope, .available), (.stageScope, .notAvailable), (.argAtRuntime, .available),
            (.argAtRuntime, .notAvailable), (.workdirCreates, .creates), (.workdirCreates, .mustExist)
        ]
        let texts = Set(statements.map { DockerfileClaim(kind: $0, subject: "ENV", assertion: $1, sentence: "").explanation })
        #expect(texts.count == statements.count)
        #expect(DockerfileFinding.Severity.holds < .wrong)
    }

    @Test("The ledger counts, marks repeats and forgets")
    func ledger() async {
        let ledger = DockerfileLedger()
        let wrongAnswer = block(nodeFile) + "\n\n`src/index.js` ends up at `/app/src/src/index.js`."
        _ = await ledger.review(wrongAnswer)
        let second = await ledger.review(wrongAnswer)
        #expect(second.repeatedCount == 1 && second.summary.hasSuffix("1 repeated"))
        let stats = await ledger.statistics
        #expect(stats == DockerfileLedger.Statistics(reviews: 2, claims: 2, flagged: 2, repeated: 1))
        await ledger.forget()
        let fresh = await ledger.review("As I said, `src/index.js` ends up at `/app/src/src/index.js`.")
        #expect(fresh.verdict == .noClaims)
        #expect(ledger.checker.policy == .standard)
    }

    @Test("Runtime behaviour recorded from docker run matches the line checks", arguments: runtimeCases)
    func runtime(_ item: RuntimeCase) {
        let flagged = !check(block(item.dockerfile)).flagged.isEmpty
        switch item.name {
        case "run cd alone": #expect(item.output == "/" && flagged)
        case "arg before from in run": #expect(item.output == "[]" && flagged)
        case "arg redeclared in run": #expect(item.output == "[1]" && !flagged)
        case "arg at runtime": #expect(item.output == "[]")
        case "arg kept by env": #expect(item.output == "[1]" && !flagged)
        case "exec form variable": #expect(item.output == "$P" && flagged)
        case "exec form shell": #expect(item.output == "8080" && !flagged)
        default: #expect(item.output == "[]" && flagged)
        }
    }
}
