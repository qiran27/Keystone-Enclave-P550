# The exact kernel revision is pinned by meta-sifive and sources.lock.yml.
# Avoid requiring an SSH credential or a local branch ref for that immutable
# commit; fetch-sources.sh deliberately checks out locked commits detached.
SRC_URI:prepend = "git://github.com/sifive/riscv-linux.git;protocol=https;name=machine;nobranch=1 "

# Port 9418 used by the native Git protocol is commonly blocked. The locked
# kernel metadata commit is also cached locally, with HTTPS as the fallback.
SRC_URI:append = " git://git.yoctoproject.org/yocto-kernel-cache;protocol=https;type=kmeta;name=meta;nobranch=1;destsuffix=${KMETA}"

SRC_URI:remove = " \
    git://git@github.com/sifive/riscv-linux.git;protocol=ssh;name=machine;branch=${KBRANCH} \
    git://git.yoctoproject.org/yocto-kernel-cache;type=kmeta;name=meta;branch=yocto-6.12;destsuffix=${KMETA} \
"
