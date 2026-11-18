import DockerfileClaimKit
import DockerignoreClaimKit

func valuesAcrossStages() {
    heading(5, "Values and files across stages")
    let fresh = """
    FROM node:20 AS build
    ENV NODE_ENV=production
    WORKDIR /app
    COPY . .
    RUN npm run build
    FROM nginx:alpine
    COPY --from=build /app/public /usr/share/nginx/html
    RUN echo "$NODE_ENV" > /env
    """
    let answer = fenced(fresh) + "\n\n`ENV NODE_ENV` from the build stage is still set in the final stage, "
        + "and `public/logo.png` ends up at `/usr/share/nginx/html/logo.png`."
    for line in fresh.split(separator: "\n") { print("   | \(line)") }
    show(DockerfileClaimChecker().check(answer))
    let chained = "FROM node:20 AS base\nENV NODE_ENV=production\nFROM base\nCMD [\"node\", \"a.js\"]"
    print("   built FROM the stage instead:")
    show(DockerfileClaimChecker().check(fenced(chained)
        + "\n\n`ENV NODE_ENV` from the base stage is still set in the final stage."))
}

func dockerignoreAndDockerfile() {
    heading(6, "A .dockerignore keeps files out of every COPY")
    let answer = fenced("FROM node:20\nWORKDIR /app\nCOPY . .")
        + "\n\nAdd a `.dockerignore`:\n\n```\nnode_modules\n**/*.log\n```\n\n"
        + "With that Dockerfile, `logs/build.log` ends up at `/app/logs/build.log`, "
        + "and `src/a.js` lands at `/app/src/a.js`."
    print("   .dockerignore: node_modules, **/*.log; COPY . . into /app")
    print("   DockerfileClaimKit:")
    show(DockerfileClaimChecker().check(answer), indent: "     ")
    print("   DockerignoreClaimKit reads the same sentence as a claim that the file is sent:")
    let ignore = DockerignoreClaimChecker().check(answer)
    print("     verdict: \(ignore.verdict.rawValue) (\(ignore.summary))")
    for finding in ignore.findings { print("     - \(finding.explanation)") }
}

func builderPolicy() {
    heading(7, "What the builder decides")
    let line = fenced("FROM node:20\nWORKDIR /app\nCOPY package.json package-lock.json .\nRUN npm ci")
    let policies: [(String, DockerfilePolicy)] = [("builder unknown", .standard), ("classic builder", .classic),
                                                  ("BuildKit", .buildKit)]
    for (name, policy) in policies {
        let report = DockerfileClaimChecker(policy: policy).check(line)
        print("   \(name): \(report.verdict.rawValue)")
    }
    print("   " + (DockerfileClaimChecker().check(line).findings.first?.explanation ?? ""))
}

func conversation() async {
    heading(8, "A conversation, with a repeat after a correction")
    let ledger = DockerfileLedger()
    let turns: [(String, String)] = [
        ("Where does my code end up?",
         fenced("FROM node:20\nWORKDIR /app\nCOPY src /app") + "\n\n`src/index.js` ends up at `/app/src/index.js`."),
        ("And does `[a-z]+` match `abc`?", "Yes: `[a-z]+` matches `abc`, and `cp -r src /app` would make `/app/src`."),
        ("Are you sure about the path?", "Yes, `src/index.js` ends up at `/app/src/index.js`.")
    ]
    for (number, turn) in turns.enumerated() {
        let report = await ledger.review(turn.1, context: turn.0)
        print("   turn \(number + 1): \(report.verdict.rawValue) (\(report.summary))")
        if let note = report.note { print("     note: \(note)") }
    }
    let stats = await ledger.statistics
    print("   ledger: \(stats.reviews) reviews, \(stats.claims) claims, \(stats.flagged) flagged, "
          + "\(stats.repeated) repeated")
    let first = await DockerfileLedger().review(turns[0].1, context: turns[0].0)
    print("   feedback sent back to the model:")
    for line in (first.feedback ?? "").split(separator: "\n") { print("     \(line)") }
}
