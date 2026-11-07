// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipDiary",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipDiaryCore", targets: ["ClipDiaryCore"]),
        .executable(name: "ClipDiary", targets: ["ClipDiary"])
    ],
    targets: [
        .target(name: "ClipDiaryCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ClipDiary", dependencies: ["ClipDiaryCore"],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .executableTarget(name: "ClipDiaryCoreChecks", dependencies: ["ClipDiaryCore"]),
        .testTarget(name: "ClipDiaryCoreTests", dependencies: ["ClipDiaryCore"])
    ],
    swiftLanguageVersions: [.v5]
)
