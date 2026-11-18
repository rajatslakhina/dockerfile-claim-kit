@testable import DockerfileClaimKit
import Testing

private let correct0: String = block(nodeFile) + "\n\n`src/index.js` ends up at `/app/src/index.js`, and `package.json` lands in `/app`."
private let correct1: String = block("FROM node:20\nWORKDIR /app\nCOPY . .\nRUN npm ci\nCMD [\"node\", \"index.js\"]")
            + "\n\nWith `WORKDIR /app`, `COPY . .` copies `index.js` to `/app/index.js`."
private let correct2: String = "In a Dockerfile, `COPY src /app/` copies the contents of the `src` folder, not the folder itself."
private let correct3: String = "In a Dockerfile, `RUN cd /app` only lasts for that `RUN`; use `WORKDIR /app` for later steps."
private let correct4: String = "In a Dockerfile, an `ARG` declared before `FROM` is only available in the `FROM` line unless you redeclare it."
private let correct5: String = "In a Dockerfile, `ARG` values exist only at build time; use `ENV` if your app needs them at runtime."
private let correct6: String = "In a Dockerfile, `WORKDIR /app` creates `/app` if it does not exist, so no `mkdir` is needed."
private let correct7: String = "In a multi-stage Dockerfile, `ENV` values set in the build stage do not carry over into the final stage."
private let correct8: String = block("FROM golang:1.23 AS build\nWORKDIR /src\nCOPY . .\nRUN go build -o /out/app .\n"
              + "FROM gcr.io/distroless/static\nCOPY --from=build /out/app /app\nENTRYPOINT [\"/app\"]")
            + "\n\nThe binary ends up at `/app` in the final image."
private let correct9: String = block("FROM python:3.12-slim\nWORKDIR /code\nCOPY requirements.txt .\nRUN pip install -r requirements.txt\n"
              + "COPY app/ ./app/\nCMD [\"python\", \"-m\", \"app\"]")
            + "\n\n`app/main.py` lands at `/code/app/main.py`, and `requirements.txt` goes to `/code/requirements.txt`."
private let correct10: String = block("ARG VERSION=1.2\nFROM alpine:${VERSION}\nARG VERSION\nRUN echo $VERSION > /version")
            + "\n\nBecause the stage declares `ARG VERSION` again, `$VERSION` is available in `RUN`."
private let correct11: String = block("FROM node:20 AS deps\nENV NODE_ENV=production\nFROM deps\nCMD [\"node\", \"a.js\"]")
            + "\n\nThe final stage is built `FROM deps`, so `NODE_ENV` set in the deps stage is still set in the final stage."
private let correct12: String = block("FROM python:3.12-slim AS base\nENV PYTHONUNBUFFERED=1\nWORKDIR /app\nFROM base AS deps\n"
              + "COPY requirements.txt .\nRUN pip install -r requirements.txt\nFROM deps\nCOPY app ./app\n"
              + "CMD [\"uvicorn\", \"app.main:app\"]")
            + "\n\n- `WORKDIR /app` creates `/app` for every later instruction.\n- `COPY app ./app` places your package at "
            + "`/app/app`, so `app/main.py` ends up at `/app/app/main.py`."
private let correct13: String = block("FROM node:20 AS builder\nWORKDIR /app\nCOPY package*.json ./\nRUN npm ci\nCOPY . .\nRUN npm run build\n"
              + "FROM nginx:alpine\nCOPY --from=builder /app/dist /usr/share/nginx/html")
            + "\n\nThe built `index.html` ends up at `/usr/share/nginx/html/index.html`."


/// Found by review before tagging 1.0.0: each was flagged before the fix.
private let reviewProbes: [String] = [
    block("FROM nginx\nCOPY nginx.conf /etc/nginx/conf.d/default.conf")
        + "\n\n`nginx.conf` is copied to `/etc/nginx/conf.d/default.conf`.",
    block("FROM python:3.12 AS b\nENV PATH=\"/opt/venv/bin:$PATH\"\nFROM python:3.12-slim\nENV PATH=\"/opt/venv/bin:$PATH\""),
    block("FROM python:3.12\nWORKDIR /app\nCOPY requirements.txt .\nRUN pip install -r requirements.txt")
        + "\n\n`requirements.txt` is copied first, then `pip install` puts packages in "
        + "`/usr/local/lib/python3.12/site-packages`.",
    block(nodeFile) + "\n\nYou can't override an `ARG` with `docker run -e`; pass `--build-arg`.",
    block(nodeFile) + "\n\n`COPY src /app/src` copies the folder itself to `/app/src`.",
    block(nodeFile) + "\n\n`COPY . .` copies the project directory, including the Dockerfile itself.",
    block("FROM alpine\nENV X=1\nENTRYPOINT [\"tini\", \"--\", \"sh\", \"-c\", \"echo $X\"]"),
    block(nodeFile) + "\n\nDocker copies `package.json` and `package-lock.json` to `/app` first, so `npm ci` is cached.",
    block("FROM node:20\nWORKDIR /home/node/app\nCOPY --chown=node:node . .")
        + "\n\n`COPY --chown=node:node . .` copies the project into `/home/node/app`, and the `CMD` runs from there.",
    block("FROM node:20\nWORKDIR /app\nCOPY src ./src") + "\n\nFiles in `src/` are copied to `/app/src/` by `COPY src ./src`."
]

let correctAnswerProbes: [String] = reviewProbes + [correct0, correct1, correct2, correct3, correct4, correct5, correct6, correct7, correct8, correct9, correct10, correct11, correct12, correct13]

/// Run before tagging: sentences from neighbouring domains must stay quiet, correct answers must pass, wrong ones
/// must be caught with the right slip, and a later unrelated turn must stay quiet.
@Suite("Probes")
struct ProbeTests {
    @Test("Other domains make no claim", arguments: [
        "`cp -r src /app` creates `/app/src` when `/app` exists.",
        "`docker cp src container:/app` copies the `src` folder itself.",
        "`rsync -a src/ /app/` copies what is inside `src`.",
        "In compose, `volumes: - ./src:/app/src` mounts `src` at `/app/src`.",
        "`export PATH=$HOME/bin:$PATH` stays set for later commands in the same shell.",
        "In GitHub Actions, `env:` values are available to every later step.",
        "Run `cd /app` first, then the following commands run in `/app`.",
        "`SELECT name FROM users` returns every user, and `ADD COLUMN` adds a column.",
        "`kubectl cp ./a.txt pod:/tmp/a.txt` puts `a.txt` at `/tmp/a.txt`.",
        "The `.dockerignore` line `*.log` keeps `a.log` out of the build context.",
        "`mkdir -p /app` creates the directory if it is missing.",
        "`[a-z]+` matches `abc`, and `src/*.js` matches `src/a.js`.",
        "`git mv src lib` moves `src/index.js` to `lib/index.js`.",
        "Set `ENV` in your `.env` file and it is available at runtime to your app.",
        "`npm ci` installs into `node_modules` and copies nothing to `/usr/lib`."
    ])
    func otherDomains(_ sentence: String) {
        #expect(check(sentence).verdict == .noClaims, "\(sentence)")
    }

    @Test("Sentences from other domains stay quiet even next to a Dockerfile", arguments: [
        "`cp -r src /app` would create `/app/src` instead.",
        "`docker cp` copies the `src` folder itself into the container.",
        "The `.dockerignore` keeps `logs/a.log` out of the build context.",
        "With `rsync -a src /app`, you get `/app/src/index.js`."
    ])
    func besideDockerfile(_ sentence: String) {
        #expect(check(block(nodeFile) + "\n\n" + sentence).verdict == .noClaims, "\(sentence)")
    }

    @Test("A question about another file keeps sentences that do not name the Dockerfile quiet")
    func neighbouringQuestion() {
        let question = "In my docker-compose.yml, not the Dockerfile: where does ./src end up?"
        let answer = "It is mounted, so `src/index.js` ends up at `/app/src/index.js`."
        #expect(check(answer, context: question).verdict == .noClaims)
        let named = "In the Dockerfile, `COPY src /app` puts `src/index.js` at `/app/src/index.js`."
        #expect(slips(check(named, context: question)) == [.copiesDirectoryItself])
    }

    @Test("Correct answers pass", arguments: correctAnswerProbes)
    func correctAnswers(_ answer: String) {
        let report = check(answer)
        #expect(report.flagged.isEmpty, "\(report.corrections)")
    }

    @Test("Wrong answers are caught with the right slip", arguments: [
        (block(nodeFile) + "\n\n`COPY src /app` would put `src/index.js` at `/app/src/index.js`.",
         [DockerfileFinding.Slip.copiesDirectoryItself]),
        (block("FROM node:20\nRUN mkdir /app\nRUN cd /app\nCOPY . .\nCMD [\"npm\", \"start\"]"),
         [.runCdDoesNotPersist]),
        (block("ARG APP_VERSION=1.0\nFROM node:20\nRUN echo $APP_VERSION > /v"), [.argBeforeFrom]),
        (block("FROM node:20\nARG PORT=3000\nCMD node server.js --port $PORT"), [.argIsBuildOnly]),
        (block("FROM node:20\nENV PORT=3000\nCMD [\"node\", \"server.js\", \"--port\", \"$PORT\"]"), [.execFormNoShell]),
        ("In a Dockerfile, `RUN cd /app` sets the working directory for the next instructions.", [.runCdDoesNotPersist]),
        ("In a Dockerfile, `WORKDIR /app` needs the directory to exist, so create it first with `mkdir`.",
         [.workdirCreatesDirectory]),
        (block("FROM node:20 AS build\nENV API_URL=https://x\nRUN npm run build\nFROM nginx\nRUN echo $API_URL"),
         [.stageStartsFresh]),
        (block("FROM alpine\nCOPY a.txt /etc/app") + "\n\nThis puts `a.txt` at `/etc/app/a.txt`.", []),
        (block("FROM scratch\nCOPY config.json /etc/app") + "\n\n`config.json` lands at `/etc/app/config.json`.",
         [.destinationNotDirectory])
    ] as [(String, [DockerfileFinding.Slip])])
    func wrongAnswers(_ answer: String, _ expected: [DockerfileFinding.Slip]) {
        let report = check(answer)
        #expect(!report.flagged.isEmpty)
        #expect(slips(report) == expected, "\(report.corrections)")
    }

    @Test("A later turn about something else stays quiet")
    func laterTurn() async {
        let ledger = DockerfileLedger()
        let first = await ledger.review(block(nodeFile) + "\n\n`src/index.js` ends up at `/app/src/src/index.js`.")
        #expect(first.verdict == .wrong)
        let regex = await ledger.review("`[a-z]+` matches `abc`, and `cp -r src /app` makes `/app/src`.",
                                        context: "How do regexes work?")
        #expect(regex.verdict == .noClaims)
        let again = await ledger.review("As I said, `src/index.js` ends up at `/app/src/src/index.js`.",
                                        context: "Are you sure?")
        #expect(again.findings.count == 1 && again.repeatedCount == 1)
        #expect(again.note?.contains("stated again") == true)
    }
}
