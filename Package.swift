// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "muty",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "muty", targets: ["muty"]),
               .executable(name: "muty-askpass", targets: ["muty-askpass"]),
               .executable(name: "muty-ssh-proxy", targets: ["muty-ssh-proxy"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
    targets: [
        .target(name: "MutyIPC"),
        .target(name: "SecureCRTSupport", exclude: ["README.md", "LICENSE"], publicHeadersPath: "include", cSettings: [.headerSearchPath(".")]),
        .executableTarget(name: "muty", dependencies: ["MutyIPC", "SecureCRTSupport", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "muty-askpass", dependencies: ["MutyIPC"]),
        .executableTarget(name: "muty-ssh-proxy")
    ]
)
