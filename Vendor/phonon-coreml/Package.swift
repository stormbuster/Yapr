// swift-tools-version:6.0
// phonon-coreml 1.1.2 by Fermion Research (Apache 2.0), vendored in Yapr with a patch so it also builds for Intel Macs.
// Only the library is kept; see PATCHES.md.
import PackageDescription

let package = Package(
    name: "phonon-coreml",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PhononCoreML", targets: ["PhononCoreML"]),
    ],
    targets: [
        .binaryTarget(name: "PhononTDT", path: "Binaries/PhononTDT.xcframework"),
        .target(name: "PhononCoreML", dependencies: ["PhononTDT"], path: "Sources/PhononCoreML"),
    ]
)
