# The exact kernel revision is pinned by meta-sifive and sources.lock.yml.
# Avoid requiring an SSH credential or a local branch ref for that immutable
# commit; fetch-sources.sh deliberately checks out locked commits detached.
SRC_URI:prepend = "git://github.com/sifive/riscv-linux.git;protocol=https;name=machine;nobranch=1 "

# Port 9418 used by the native Git protocol is commonly blocked. The locked
# kernel metadata commit is also cached locally, with HTTPS as the fallback.
SRC_URI:append = " git://git.yoctoproject.org/yocto-kernel-cache;protocol=https;type=kmeta;name=meta;nobranch=1;destsuffix=${KMETA}"

SRC_URI:append = " \
    file://0001-eswin-cipher-backport-for-p550.patch \
    file://0002-keystone-driver-in-tree.patch \
    file://eswin-cipher.cfg \
    file://eswin-cipher/Kconfig \
    file://eswin-cipher/Makefile \
    file://eswin-cipher/eswin-ipc-scpu.c \
    file://eswin-cipher/eswin-ipc-scpu.h \
    file://eswin-cipher/eswin-mailbox.c \
    file://eswin-cipher/eswin-mailbox.h \
    file://eswin-cipher/eswin-mailbox-dt.h \
    file://keystone-driver/Kconfig \
    file://keystone-driver/Makefile \
    file://keystone-vf2-driver-finalize-cleanup.patch;apply=no \
    git://github.com/its-valentinvp/keystone.git;protocol=https;branch=vf2-support;name=keystone;destsuffix=keystone-vf2 \
"

SRCREV_keystone = "c5f7ac3977f50309ac816b54f470c4021573bf5e"
SRCREV_FORMAT = "meta_machine_keystone"

SRC_URI:remove = " \
    git://git@github.com/sifive/riscv-linux.git;protocol=ssh;name=machine;branch=${KBRANCH} \
    git://git.yoctoproject.org/yocto-kernel-cache;type=kmeta;name=meta;branch=yocto-6.12;destsuffix=${KMETA} \
"

KERNEL_MODULE_AUTOLOAD += "eswin-mailbox es_cipher keystone-driver"
KERNEL_LOCALVERSION = "-1-premier"

do_patch:append() {
    install -d ${S}/drivers/crypto/eswin
    install -d ${S}/include/linux/mailbox
    install -d ${S}/include/dt-bindings/mailbox
    install -d ${S}/include/uapi/linux

    install -m 0644 ${UNPACKDIR}/eswin-cipher/Kconfig \
        ${S}/drivers/crypto/eswin/Kconfig
    install -m 0644 ${UNPACKDIR}/eswin-cipher/Makefile \
        ${S}/drivers/crypto/eswin/Makefile
    install -m 0644 ${UNPACKDIR}/eswin-cipher/eswin-ipc-scpu.c \
        ${S}/drivers/crypto/eswin/eswin-ipc-scpu.c
    install -m 0644 ${UNPACKDIR}/eswin-cipher/eswin-ipc-scpu.h \
        ${S}/include/uapi/linux/eswin-ipc-scpu.h
    install -m 0644 ${UNPACKDIR}/eswin-cipher/eswin-mailbox.c \
        ${S}/drivers/mailbox/eswin-mailbox.c
    install -m 0644 ${UNPACKDIR}/eswin-cipher/eswin-mailbox.h \
        ${S}/include/linux/mailbox/eswin-mailbox.h
    install -m 0644 ${UNPACKDIR}/eswin-cipher/eswin-mailbox-dt.h \
        ${S}/include/dt-bindings/mailbox/eswin-mailbox.h

    cp -a ${UNPACKDIR}/keystone-vf2/linux-keystone-driver \
        ${S}/drivers/misc/keystone
    sed -i 's/\r$//' ${S}/drivers/misc/keystone/keystone-ioctl.c
    patch -d ${S}/drivers/misc/keystone -p1 \
        < ${UNPACKDIR}/keystone-vf2-driver-finalize-cleanup.patch
    install -m 0644 ${UNPACKDIR}/keystone-driver/Kconfig \
        ${S}/drivers/misc/keystone/Kconfig
    install -m 0644 ${UNPACKDIR}/keystone-driver/Makefile \
        ${S}/drivers/misc/keystone/Makefile
    install -m 0644 \
        ${UNPACKDIR}/keystone-vf2/sdk/include/shared/sm_call.h \
        ${S}/drivers/misc/keystone/sm_call.h
    install -m 0644 \
        ${UNPACKDIR}/keystone-vf2/sdk/include/shared/keystone_user.h \
        ${S}/drivers/misc/keystone/keystone_user.h
}
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
