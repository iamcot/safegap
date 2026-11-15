// swift-tools-version:5.9
// Phần lõi SafeGap (port 1-1 từ proto/ Python): chọn xe cùng làn, khoảng cách, Kalman + IoU tracker, cảnh báo.
// Chỉ dùng Foundation nên chạy `swift test` được trên Mac (và Linux CI) mà không cần iPhone.
import PackageDescription

let package = Package(
    name: "SafeGapCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "SafeGapCore", targets: ["SafeGapCore"]),
    ],
    targets: [
        .target(name: "SafeGapCore"),
        .testTarget(
            name: "SafeGapCoreTests",
            dependencies: ["SafeGapCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
