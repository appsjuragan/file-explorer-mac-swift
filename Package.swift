// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FileExplorer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FileExplorer", targets: ["FileExplorer"])
    ],
    targets: [
        // Single module: pure logic lives in Core/ and Services/, UI in UI/.
        // No third-party dependencies on purpose (smaller binary, smaller attack surface).
        .executableTarget(
            name: "FileExplorer",
            path: "Sources/FileExplorer"
        ),
        .testTarget(
            name: "FileExplorerTests",
            dependencies: ["FileExplorer"],
            path: "Tests/FileExplorerTests"
        )
    ]
)
