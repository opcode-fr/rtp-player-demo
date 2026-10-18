// swift-tools-version:5.9
// Cœur RTP/H.264 sans dépendance (réception, remise en ordre, dépaquetage, SDP).
// Testable sur le Mac avec `swift test` ; utilisé par l'appli iOS.
import PackageDescription

let package = Package(
    name: "RtpCore",
    platforms: [.iOS("16.4"), .macOS(.v13)],
    products: [.library(name: "RtpCore", targets: ["RtpCore"])],
    targets: [
        // Mêmes sources que le pod RtpVideo (hors fichiers Expo) : voir RtpVideo.podspec.
        .target(name: "RtpCore", path: "RtpCore"),
        .testTarget(name: "RtpCoreTests", dependencies: ["RtpCore"], path: "Tests/RtpCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
