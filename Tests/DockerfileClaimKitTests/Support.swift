@testable import DockerfileClaimKit

/// A fenced Dockerfile block.
func block(_ lines: String, tag: String = "dockerfile") -> String {
    "```\(tag)\n\(lines)\n```"
}

let nodeFile = """
FROM node:20-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY src /app/src
CMD ["node", "src/index.js"]
"""

func check(_ text: String, context: String = "", policy: DockerfilePolicy = .standard) -> DockerfileReport {
    DockerfileClaimChecker(policy: policy).check(text, context: context)
}

func slips(_ report: DockerfileReport) -> [DockerfileFinding.Slip] {
    report.findings.compactMap {
        if case .wrong(let slip?) = $0.outcome { return slip }
        return nil
    }
}

func outcome(_ sentence: String, file: String = nodeFile, policy: DockerfilePolicy = .standard)
    -> DockerfileFinding.Outcome? {
    check(block(file) + "\n\n" + sentence, policy: policy).findings.first { $0.claim.isExplicit }?.outcome
}
