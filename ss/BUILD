load("//bazel_tools:haskell.bzl", "da_haskell_test", "da_haskell_binary")

da_haskell_test(
    name = "test",
    srcs = ["Main.hs"],
    hazel_deps = [
        "base",
        "extra",
        "text",
        "managed",
    ],
    deps = [
        "//daml-foundations/daml-ghc/daml-compiler",
        "//compiler/haskell-ide-core",
        "//libs-haskell/da-hs-base",
    ],
    data = [
        "//compiler/scenario-service/server:scenario_service_jar",
        "//daml-foundations/daml-ghc/package-database:package-db",
    ],
)

da_haskell_binary(
    name = "run",
    srcs = ["Main.hs"],
    hazel_deps = [
        "base",
        "extra",
        "text",
        "managed",
    ],
    deps = [
        "//daml-foundations/daml-ghc/daml-compiler",
        "//compiler/haskell-ide-core",
        "//libs-haskell/da-hs-base",
    ],
    data = [
        "//compiler/scenario-service/server:scenario_service_jar",
        "//daml-foundations/daml-ghc/package-database:package-db",
    ],
)