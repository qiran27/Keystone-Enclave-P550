FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# The vendor metadata pins pseudo before its modern openat2/*at handling.
# Ubuntu 22.04 host tar can then fail during do_package with EFAULT and
# "unknown base path for fd". Use the source-lock-verified current release.
SRCREV = "ba8887e5f1e922f866681ec7dec1a00b602a9328"
PV = "1.9.11"

SRC_URI:remove = " \
    git://git.yoctoproject.org/pseudo;branch=master;protocol=https \
    file://0001-configure-Prune-PIE-flags.patch \
    file://glibc238.patch \
"
SRC_URI:prepend = "git://${TOPDIR}/../sources/pseudo;protocol=file;nobranch=1 "

# pseudo uses GCC-only builtins in its syscall fallback wrapper.
TOOLCHAIN = "gcc"
TOOLCHAIN_NATIVE = "gcc"
