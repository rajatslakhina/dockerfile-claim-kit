// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DockerfileClaimKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(name: "DockerfileClaimKit", targets: ["DockerfileClaimKit"]),
        .executable(name: "DockerfileClaimDemo", targets: ["DockerfileClaimDemo"])
    ],
    dependencies: [
        .package(url: "https://github.com/rajatslakhina/dockerignore-claim-kit.git", from: "1.0.1")
    ],
    targets: [
        .target(
            name: "DockerfileClaimKit",
            dependencies: [.product(name: "DockerignoreClaimKit", package: "dockerignore-claim-kit")]
        ),
        .executableTarget(
            name: "DockerfileClaimDemo",
            dependencies: [
                "DockerfileClaimKit",
                .product(name: "DockerignoreClaimKit", package: "dockerignore-claim-kit")
            ]
        ),
        .testTarget(
            name: "DockerfileClaimKitTests",
            dependencies: ["DockerfileClaimKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
