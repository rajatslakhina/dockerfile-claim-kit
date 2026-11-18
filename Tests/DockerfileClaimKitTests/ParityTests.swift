@testable import DockerfileClaimKit
import DockerignoreClaimKit
import Testing

struct ParityCase: Sendable, CustomStringConvertible {
    let name: String
    let dockerfile: String
    let dockerignore: String?
    let files: String
    /// Where Docker put each context file; `nil` when the build stopped.
    let placed: [String: [String]]?

    var description: String { name }
}

struct RuntimeCase: Sendable, CustomStringConvertible {
    let name: String
    let dockerfile: String
    let output: String

    var description: String { name }
}

/// Hoisted out of `@Test(arguments:)`: Swift 6.0's compiler crashes on a closure there.
let builtCases = parityCases.filter { $0.placed != nil }
let stoppedCases = parityCases.filter { $0.placed == nil }

@Suite("Parity with docker build")
struct ParityTests {
    func model(_ item: ParityCase) -> DockerfileModel {
        DockerfileModel(Dockerfile(item.dockerfile), dockerignore: item.dockerignore.map(DockerignoreRules.init))
    }

    @Test("Every file lands where the classic builder put it", arguments: builtCases)
    func placements(_ item: ParityCase) throws {
        let model = model(item)
        for (file, expected) in try #require(item.placed) {
            let result = model.placements(of: file)
            #expect(result.paths.sorted() == expected, "\(item.name): \(file)")
            let allowed: Set<PlacementCaveat> = [.globMatchesOne, .doubleStar]
            #expect(result.placements.allSatisfy { Set($0.caveats).isSubset(of: allowed) }, "\(item.name): \(file)")
        }
    }

    @Test("A build Docker stopped is foreseen", arguments: stoppedCases)
    func failures(_ item: ParityCase) {
        let model = model(item)
        let results = item.files.split(separator: "\n").map { model.placements(of: String($0)) }
        let stops = results.contains { result in
            result.excludedBy != nil || result.placements.contains {
                $0.caveats.contains(.classicStops) || $0.caveats.contains(.globMatchesOne)
            }
        }
        #expect(stops || item.dockerfile.contains("../"), "\(item.name)")
    }

    @Test("Every case was recorded")
    func counts() {
        #expect(parityCases.count == 69)
        #expect(runtimeCases.count == 8)
    }
}
