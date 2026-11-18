import DockerfileClaimKit
import Testing

/// The README's usage example, run as written.
@Suite("README")
struct ReadmeTests {
    @Test("The usage example")
    func usage() async {
        let answer = """
        ```dockerfile
        FROM node:20-slim
        WORKDIR /app
        COPY src /app
        RUN cd /app
        CMD ["node", "$ENTRY"]
        ```

        `src/index.js` ends up at `/app/src/index.js`.
        """
        let report = DockerfileClaimChecker().check(answer)
        #expect(report.verdict == .wrong)
        #expect(report.summary == "3 claims checked, 0 hold, 3 wrong")
        #expect(report.note?.hasPrefix("Dockerfile check: It does not hold that `RUN cd /app` works as written") == true)
        #expect(report.findings.compactMap(\.fix) == ["WORKDIR /app", "CMD [\"sh\", \"-c\", \"node $ENTRY\"]"])
        #expect(report.findings.last?.actual == ["/app/index.js"])

        let model = DockerfileModel(Dockerfile("FROM scratch\nWORKDIR /srv\nCOPY src/*.js app/\n"))
        #expect(model.placements(of: "src/a.js").paths == ["/srv/app/a.js"])
        #expect(model.placements(of: "src/lib/b.js").paths.isEmpty)

        let checker = DockerfileClaimChecker()
        #expect(checker.check("`RUN cd /app` persists for the next steps.").verdict == .noClaims)
        #expect(checker.check("`RUN cd /app` persists for the next steps.", context: "My Dockerfile?").verdict == .wrong)

        let ledger = DockerfileLedger()
        _ = await ledger.review(answer)
        let again = await ledger.review("Yes, `src/index.js` ends up at `/app/src/index.js`.")
        #expect(again.repeatedCount == 1)
    }
}
