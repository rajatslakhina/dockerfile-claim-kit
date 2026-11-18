import DockerfileClaimKit
import DockerignoreClaimKit

let nodeDockerfile = """
FROM node:20-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY src /app/src
COPY README.md /docs
CMD ["node", "src/index.js"]
"""

func whereFilesLand() {
    heading(1, "Where each file from the build context lands")
    let model = DockerfileModel(Dockerfile(nodeDockerfile))
    for line in nodeDockerfile.split(separator: "\n") { print("   | \(line)") }
    for path in ["src/index.js", "src/lib/db.js", "package.json", "README.md", "test/a.test.js"] {
        let result = model.placements(of: path)
        let places = result.placements.map { placement in
            placement.caveats.isEmpty ? placement.path
                : placement.path + " (" + placement.caveats.map(caveatText).joined(separator: "; ") + ")"
        }
        print("   \(path) -> " + (places.isEmpty ? "not copied" : places.joined(separator: " or ")))
    }
}

func copyOfADirectory() {
    heading(2, "COPY of a directory copies what is inside it")
    let answer = fenced("FROM python:3.12-slim\nCOPY app /srv\nCMD [\"python\", \"/srv/main.py\"]")
        + "\n\n`COPY app /srv` puts `app/main.py` at `/srv/app/main.py`."
    print("   answer: `COPY app /srv` puts `app/main.py` at `/srv/app/main.py`.")
    show(DockerfileClaimChecker().check(answer))
    let fixed = fenced("FROM python:3.12-slim\nCOPY app /srv\nCMD [\"python\", \"/srv/main.py\"]")
        + "\n\n`app/main.py` lands at `/srv/main.py`, which is what `CMD` runs."
    print("   rewrite: `app/main.py` lands at `/srv/main.py`, which is what `CMD` runs.")
    show(DockerfileClaimChecker().check(fixed))
}

func linesThatDoNotDoWhatTheySay() {
    heading(3, "Dockerfile lines that do not do what they are written to do")
    let dockerfile = """
    ARG APP_VERSION=1.4.2
    FROM node:20-slim
    RUN mkdir -p /app && cd /app
    COPY package.json package-lock.json .
    RUN npm ci
    RUN echo "$APP_VERSION" > /version
    ENV PORT=3000
    CMD ["node", "server.js", "--port", "$PORT"]
    """
    for line in dockerfile.split(separator: "\n") { print("   | \(line)") }
    show(DockerfileClaimChecker().check(fenced(dockerfile)))
}

func statementsWithoutADockerfile() {
    heading(4, "General statements about Dockerfile rules")
    let wrong = "In a Dockerfile, `RUN cd /app` makes the following commands run in `/app`. "
        + "`ARG` values are available at runtime. `WORKDIR /app` fails if the directory does not exist yet."
    print("   answer: \(wrong)")
    show(DockerfileClaimChecker().check(wrong))
    let right = "In a Dockerfile, `RUN cd /app` only lasts for that `RUN`. `ARG` values exist only during the build. "
        + "`WORKDIR /app` creates the directory if it is missing."
    print("   rewrite: \(right)")
    show(DockerfileClaimChecker().check(right))
}
