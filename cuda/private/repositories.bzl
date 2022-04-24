"""Generate @local_cuda//"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")

defs_bzl_shared = """# DO NOT MODIFY. This file is generated by cuda/private/repositories.bzl

def if_linux(if_true, if_false = []):
    return select({
        "@platforms//os:linux": if_true,
        "//conditions:default": if_false,
    })

def if_windows(if_true, if_false = []):
    return select({
        "@platforms//os:windows": if_true,
        "//conditions:default": if_false,
    })

"""

def _to_forward_slash(s):
    return s.replace("\\", "/")

def _is_linux(ctx):
    return ctx.os.name.startswith("linux")

def _local_cuda_impl(repository_ctx):
    ## Detect CUDA Toolkit
    # Path to CUDA Toolkit is
    # - taken from CUDA_PATH environment variable or
    # - determined through 'which ptxas' or
    # - defaults to '/usr/local/cuda'
    cuda_path = repository_ctx.os.environ.get("CUDA_PATH", None)
    if cuda_path == None:
        ptxas_path = repository_ctx.which("ptxas")
        if ptxas_path:
            # ${CUDA_PATH}/bin/ptxas
            cuda_path = str(ptxas_path.dirname.dirname)
    if cuda_path == None and _is_linux(repository_ctx):
        cuda_path = "/usr/local/cuda"

    # if cuda_path == None:
    #     fail("Cannot determine CUDA Toolkit root, abort!")

    # Generate @local_cuda//BUILD and @local_cuda//defs.bzl and
    defs_bzl_content = defs_bzl_shared
    defs_if_local_cuda = "def if_local_cuda(if_true, if_false = []):\n    return %s\n"
    if repository_ctx.path(cuda_path).exists:
        repository_ctx.symlink(cuda_path, "cuda")
        repository_ctx.symlink(Label("//cuda:runtime/BUILD.local_cuda"), "BUILD")
        defs_bzl_content += defs_if_local_cuda % "if_true"
    else:
        repository_ctx.file("BUILD")  # Empty file
        defs_bzl_content += defs_if_local_cuda % "if_false"
    repository_ctx.file("defs.bzl", defs_bzl_content)

    # Generate @local_cuda//toolchain/BUILD
    tpl_label = Label(
        "//cuda:templates/BUILD.local_toolchain_" +
        ("linux" if _is_linux(repository_ctx) else "windows"),
    )
    substitutions = {"%{cuda_path}": _to_forward_slash(cuda_path)}
    env_tmp = repository_ctx.os.environ.get("TMP", repository_ctx.os.environ.get("TEMP", None))
    if env_tmp != None:
        substitutions["%{env_tmp}"] = _to_forward_slash(env_tmp)
    repository_ctx.template("toolchain/BUILD", tpl_label, substitutions = substitutions, executable = False)

_local_cuda = repository_rule(
    implementation = _local_cuda_impl,
    environ = ["CUDA_PATH", "PATH"],
    # remotable = True,
)

def rules_cuda_deps():
    maybe(
        name = "bazel_skylib",
        repo_rule = http_archive,
        sha256 = "f7be3474d42aae265405a592bb7da8e171919d74c16f082a5457840f06054728",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/bazel-skylib/releases/download/1.2.1/bazel-skylib-1.2.1.tar.gz",
            "https://github.com/bazelbuild/bazel-skylib/releases/download/1.2.1/bazel-skylib-1.2.1.tar.gz",
        ],
    )

    maybe(
        name = "platforms",
        repo_rule = http_archive,
        sha256 = "379113459b0feaf6bfbb584a91874c065078aa673222846ac765f86661c27407",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/platforms/releases/download/0.0.5/platforms-0.0.5.tar.gz",
            "https://github.com/bazelbuild/platforms/releases/download/0.0.5/platforms-0.0.5.tar.gz",
        ],
    )

    _local_cuda(name = "local_cuda")
