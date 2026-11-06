load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ScheduledCall",
    module_name = "ScheduledCall",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/TelegramCore",
        "//submodules/AccountContext",
        "//submodules/AvatarNode",
        "//submodules/TelegramPresentationData",
        "//submodules/TelegramStringFormatting",
        "//submodules/TextFormat",
        "//submodules/TelegramUI/Components/ScheduledCallModel",
    ],
    visibility = [
        "//visibility:public",
    ],
)
