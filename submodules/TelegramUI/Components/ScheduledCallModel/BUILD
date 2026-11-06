load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ScheduledCallModel",
    module_name = "ScheduledCallModel",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/TelegramPresentationData",
        "//submodules/TelegramStringFormatting",
    ],
    visibility = [
        "//visibility:public",
    ],
)
