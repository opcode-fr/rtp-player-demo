// swift-tools-version:5.9
// Cœur RTP/H.264 sans dépendance (réception, remise en ordre, dépaquetage, SDP).
// Testable sur le Mac avec `swift test` ; utilisé par l'appli iOS.
import PackageDescription

let package = Package(
    name: "RtpCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "RtpCore", targets: ["RtpCore"])],
    targets: [
        .target(name: "RtpCore"),
        .testTarget(name: "RtpCoreTests", dependencies: ["RtpCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
