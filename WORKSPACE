workspace(name = "rabbitmq-server")

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")
load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository", "new_git_repository")

http_archive(
    name = "rules_pkg",
    sha256 = "8f9ee2dc10c1ae514ee599a8b42ed99fa262b757058f65ad3c384289ff70c4b8",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/rules_pkg/releases/download/0.9.1/rules_pkg-0.9.1.tar.gz",
        "https://github.com/bazelbuild/rules_pkg/releases/download/0.9.1/rules_pkg-0.9.1.tar.gz",
    ],
)

load("@rules_pkg//:deps.bzl", "rules_pkg_dependencies")

rules_pkg_dependencies()

git_repository(
    name = "rules_erlang",
    remote = "https://github.com/rabbitmq/rules_erlang.git",
<<<<<<< HEAD
    tag = "3.11.3",
=======
    tag = "3.13.1",
>>>>>>> 2273bc530a (Update rules_erlang version in WORKSPACE to match MODULE.bazel)
)

load("@rules_erlang//:internal_deps.bzl", "rules_erlang_internal_deps")

rules_erlang_internal_deps()

load("@rules_erlang//:internal_setup.bzl", "rules_erlang_internal_setup")

rules_erlang_internal_setup(go_repository_default_config = "//:WORKSPACE")

load("@rules_erlang//gazelle:deps.bzl", "gazelle_deps")

gazelle_deps()

http_archive(
    name = "io_bazel_rules_docker",
    sha256 = "b1e80761a8a8243d03ebca8845e9cc1ba6c82ce7c5179ce2b295cd36f7e394bf",
    urls = ["https://github.com/bazelbuild/rules_docker/releases/download/v0.25.0/rules_docker-v0.25.0.tar.gz"],
)

load(
    "@io_bazel_rules_docker//repositories:repositories.bzl",
    container_repositories = "repositories",
)

container_repositories()

load("@io_bazel_rules_docker//repositories:deps.bzl", container_deps = "deps")

container_deps()

load(
    "@io_bazel_rules_docker//container:container.bzl",
    "container_pull",
)

container_pull(
    name = "ubuntu2004",
    registry = "index.docker.io",
    repository = "pivotalrabbitmq/ubuntu",
    tag = "20.04",
)

http_file(
    name = "openssl-1.1.1g",
    downloaded_file_path = "openssl-1.1.1g.tar.gz",
    sha256 = "ddb04774f1e32f0c49751e21b67216ac87852ceb056b75209af2443400636d46",
    urls = ["https://www.openssl.org/source/openssl-1.1.1g.tar.gz"],
)

http_file(
    name = "otp_src_24",
    downloaded_file_path = "OTP-24.3.4.14.tar.gz",
    sha256 = "7edeef41b491bf7eb5e85795b4c58e40b7c6b803168b67c729644b66c618f544",
    urls = ["https://github.com/erlang/otp/archive/OTP-24.3.4.14.tar.gz"],
)

http_file(
    name = "otp_src_25_0",
    downloaded_file_path = "OTP-25.0.4.tar.gz",
    sha256 = "05878cb51a64b33c86836b12a21903075c300409b609ad5e941ddb0feb8c2120",
    urls = ["https://github.com/erlang/otp/archive/OTP-25.0.4.tar.gz"],
)

http_file(
    name = "otp_src_25_1",
    downloaded_file_path = "OTP-25.1.2.1.tar.gz",
    sha256 = "79f8e31bb9ff7d43a920f207ef104d1106b2332fdbadf11241d714eacb6d8d1a",
    urls = ["https://github.com/erlang/otp/archive/OTP-25.1.2.1.tar.gz"],
)

http_file(
    name = "otp_src_25_2",
    downloaded_file_path = "OTP-25.2.3.tar.gz",
    sha256 = "637bc5cf68dd229fd3c3fe889a6f84dd32c4a827488550a0a98123b00c2d78b5",
    urls = ["https://github.com/erlang/otp/archive/OTP-25.2.3.tar.gz"],
)

http_file(
    name = "otp_src_25_3",
    downloaded_file_path = "OTP-25.3.2.6.tar.gz",
    sha256 = "67e0f5c209a335cfc216a57b1f016072a69eb9683d36d6d101bf2f60a2e45926",
    urls = ["https://github.com/erlang/otp/archive/OTP-25.3.2.6.tar.gz"],
)

load(
    "@rules_erlang//:rules_erlang.bzl",
    "erlang_config",
    "internal_erlang_from_github_release",
    "internal_erlang_from_http_archive",
)

erlang_config(
    internal_erlang_configs = [
        internal_erlang_from_github_release(
            name = "23",
            sha256 = "e3ecb3ac2cc549ab90cd9f8921eaebc8613f4d5c89972a3987e5a762d5a2df08",
            version = "23.3.4.16",
        ),
        internal_erlang_from_github_release(
            name = "24",
            sha256 = "111a00cf3fd512526e35f232fb18e6e95c7a9b1688bb38d7dd8152a82e0ea684",
            version = "24.3.4.13",
        ),
        internal_erlang_from_github_release(
            name = "25_0",
            sha256 = "8fc707f92a124b2aeb0f65dcf9ac8e27b2a305e7bcc4cc1b2fdf770eec0165bf",
            version = "25.0.4",
        ),
        internal_erlang_from_github_release(
            name = "25_1",
            sha256 = "1cd2fbe225a412009cda9b1fd9f3fff0293e75e3020daa48abf68721471e91eb",
            version = "25.1.2.1",
        ),
        internal_erlang_from_github_release(
            name = "25_2",
            sha256 = "f4d9f11d67ba478a053d72e635a44722a975603fe1284063fdf38276366bc61c",
            version = "25.2.3",
        ),
        internal_erlang_from_github_release(
            name = "25_3",
            sha256 = "1f899b4b1ef8569c08713b76bc54607a09503a1d188e6d61512036188cc356db",
            version = "25.3.2.5",
        ),
        internal_erlang_from_http_archive(
            name = "git_master",
            strip_prefix = "otp-master",
            url = "https://github.com/erlang/otp/archive/refs/heads/master.tar.gz",
            version = "master",
        ),
    ],
)

load("@erlang_config//:defaults.bzl", "register_defaults")

register_defaults()

load(
    "//bazel/elixir:elixir.bzl",
    "elixir_config",
    "internal_elixir_from_github_release",
)

elixir_config(
    internal_elixir_configs = [
        internal_elixir_from_github_release(
            name = "1_13",
            sha256 = "95daf2dd3052e6ca7d4d849457eaaba09de52d65ca38d6933c65bc1cdf6b8579",
            version = "1.13.4",
        ),
        internal_elixir_from_github_release(
            name = "1_14",
            sha256 = "2ea249566c67e57f8365ecdcd0efd9b6c375f57609b3ac2de326488ac37c8ebd",
            version = "1.14.5",
        ),
        internal_elixir_from_github_release(
            name = "1_15",
            sha256 = "3cfadca57c3092ccbd3ec3f17e5eab529bbd2946f50e4941a903c55c39e3c5f5",
            version = "1.15.2",
        ),
    ],
    rabbitmq_server_workspace = "@",
)

load(
    "@elixir_config//:defaults.bzl",
    register_elixir_defaults = "register_defaults",
)

register_elixir_defaults()

new_git_repository(
    name = "bats",
    build_file = "@//:BUILD.bats",
    remote = "https://github.com/sstephenson/bats",
    tag = "v0.4.0",
)

load("//deps/amqp10_client:activemq.bzl", "activemq_archive")

activemq_archive()

load("//bazel/bzlmod:secondary_umbrella.bzl", "secondary_umbrella")

secondary_umbrella()

git_repository(
    name = "rbe",
    branch = "linux-rbe",
    remote = "https://github.com/rabbitmq/rbe-erlang-platform.git",
)
