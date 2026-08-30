// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VitalsLoom",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VitalsLoom", targets: ["VitalsLoom"])],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: "sqlite3"),
        .executableTarget(
            name: "VitalsLoom",
            dependencies: ["CSQLite"],
            path: "Sources/VitalsLoom",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(
            name: "VitalsLoomTests",
            dependencies: ["VitalsLoom"],
            path: "Tests/VitalsLoomTests"
        )
    ]
)
