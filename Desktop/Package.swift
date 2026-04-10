// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Fazm",
    platforms: [
        .macOS("14.0")
    ],
    dependencies: [
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.0.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "8.58.1"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0"),
        .package(url: "https://github.com/m13v/macos-session-replay.git", from: "0.7.0"),
        .package(path: "LocalPackages/Highlightr"),
        .package(url: "https://github.com/m13v/ai-browser-profile-swift-light.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "ObjCExceptionCatcher",
            path: "ObjCExceptionCatcher",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Fazm",
            dependencies: [
                "ObjCExceptionCatcher",
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "PostHog", package: "posthog-ios"),
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "SessionReplay", package: "macos-session-replay"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "BrowserProfileLight", package: "ai-browser-profile-swift-light"),
            ],
            path: "Sources",
            resources: [
                .copy("BundledSkills"),
                .process("Resources"),
            ]
        )
    ]
)
