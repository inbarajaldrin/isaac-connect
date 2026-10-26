// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IsaacConnect",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "IsaacConnect", targets: ["IsaacConnect"]),
    ],
    targets: [
        .executableTarget(
            name: "IsaacConnect",
            resources: [
                .copy("Renderer"),
            ]
        ),
    ]
)
