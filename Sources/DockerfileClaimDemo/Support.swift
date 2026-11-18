import DockerfileClaimKit

func heading(_ number: Int, _ title: String) {
    print("")
    print("\(number). \(title)")
    print(String(repeating: "-", count: title.count + 3))
}

func fenced(_ dockerfile: String) -> String {
    "```dockerfile\n\(dockerfile)\n```"
}

func show(_ report: DockerfileReport, indent: String = "   ") {
    print("\(indent)verdict: \(report.verdict.rawValue) (\(report.summary))")
    for finding in report.findings {
        print("\(indent)- [\(label(finding.severity))] \(finding.explanation)")
    }
}

func label(_ severity: DockerfileFinding.Severity) -> String {
    switch severity {
    case .holds: "holds"
    case .unchecked: "unchecked"
    case .caution: "check"
    case .wrong: "wrong"
    }
}

func caveatText(_ caveat: PlacementCaveat) -> String {
    switch caveat {
    case .insideIfDirectory(let path): "only if \(path) is already a directory"
    case .renamedUnlessDirectory(let path): "only if \(path) is not a directory yet"
    case .baseImageWorkdir: "base image may set WORKDIR"
    case .globMatchesOne: "only while the pattern matches one file"
    case .classicStops: "classic builder stops"
    case .doubleStar: "** read as * by the classic builder"
    }
}
