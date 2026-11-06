load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ScheduledCallScreen",
    module_name = "ScheduledCallScreen",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/ComponentFlow",
        "//submodules/Components/ViewControllerComponent",
        "//submodules/Components/SheetComponent",
        "//submodules/Components/BundleIconComponent",
        "//submodules/ContextUI",
        "//submodules/TelegramCore",
        "//submodules/AccountContext",
        "//submodules/AvatarNode",
        "//submodules/TelegramPresentationData",
        "//submodules/TelegramStringFormatting",
        "//submodules/TextFormat",
        "//submodules/TelegramUI/Components/ButtonComponent",
        "//submodules/TelegramUI/Components/GlassBarButtonComponent",
        "//submodules/TelegramUI/Components/ScheduledCall",
        "//submodules/TelegramUI/Components/ScheduledCallModel",
    ],
    visibility = [
        "//visibility:public",
    ],
)
