FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# The exact OpenSBI revision is pinned by meta-sifive and sources.lock.yml.
SRC_URI:remove = "git://github.com/riscv/opensbi.git;branch=master;protocol=https"
SRC_URI:prepend = "git://github.com/riscv/opensbi.git;protocol=https;nobranch=1 "

# All Keystone components use the VF2 support commit requested for this port.
# The source-lock verifier checks the same local repository before BitBake runs.
SRC_URI:append = " \
    git://${TOPDIR}/../sources/keystone-vf2;protocol=file;nobranch=1;name=keystone;destsuffix=keystone-vf2 \
    file://0001-eswin-eic770x-integrate-keystone-sm.patch \
    file://0002-keystone-vf2-add-p550-test-platform.patch;apply=no \
    file://0003-keystone-vf2-opensbi-1.6-ecall.patch;apply=no \
    file://0004-keystone-vf2-opensbi-1.6-trap-context.patch;apply=no \
    file://0005-keystone-vf2-opensbi-1.6-pmp-ipi.patch;apply=no \
    file://0006-keystone-vf2-opensbi-1.6-interrupt-return.patch;apply=no \
    file://0007-keystone-p550-publish-exact-entry-context.patch;apply=no \
    file://0008-keystone-p550-enable-enclave-cycle-counter.patch;apply=no \
    file://0009-keystone-p550-queue-pmp-ipi.patch;apply=no \
    file://0010-keystone-p550-retrigger-stalled-pmp-ipi.patch;apply=no \
    file://0012-keystone-p550-restore-pmp-ownership.patch;apply=no \
    file://0013-opensbi-p550-hand-pmp-back-to-keystone.patch;apply=no \
    file://0019-keystone-p550-use-opensbi-trap-entry.patch;apply=no \
    file://0022-keystone-p550-skip-opensbi-locked-pmp-layout.patch;apply=no \
    file://p550-platform.c;apply=no \
    file://p550-platform.h;apply=no \
"

SRCREV_keystone = "c5f7ac3977f50309ac816b54f470c4021573bf5e"
SRCREV_FORMAT = "default_keystone"

KEYSTONE_COPY = "${S}/keystone-sm"
KEYSTONE_SDK_COPY = "${S}/keystone-sdk"

# Populate and adapt Keystone in a dedicated shell task after OpenSBI's normal
# patch phase. This must precede autotools_preconfigure: that pre-function
# invokes `make clean`, and the EIC770X objects.mk already includes Keystone.
do_keystone_prepare() {
    rm -rf ${KEYSTONE_COPY}
    rm -rf ${KEYSTONE_SDK_COPY}
    cp -a ${UNPACKDIR}/keystone-vf2/sm ${KEYSTONE_COPY}
    cp -a ${UNPACKDIR}/keystone-vf2/sdk ${KEYSTONE_SDK_COPY}

    install -d ${KEYSTONE_COPY}/src/platform/p550
    install -m 0644 ${UNPACKDIR}/p550-platform.c \
        ${KEYSTONE_COPY}/src/platform/p550/platform.c
    install -m 0644 ${UNPACKDIR}/p550-platform.h \
        ${KEYSTONE_COPY}/src/platform/p550/platform.h
    install -m 0644 \
        ${UNPACKDIR}/keystone-vf2/sdk/include/verifier/test_dev_key.h \
        ${KEYSTONE_COPY}/src/platform/p550/test_dev_key.h
    sed -i '/^#warning Using TEST device root key/d' \
        ${KEYSTONE_COPY}/src/platform/p550/test_dev_key.h

    patch --fuzz=0 -d ${KEYSTONE_COPY} -p1 < \
        ${UNPACKDIR}/0002-keystone-vf2-add-p550-test-platform.patch
    patch --fuzz=0 -d ${KEYSTONE_COPY} -p1 < \
        ${UNPACKDIR}/0003-keystone-vf2-opensbi-1.6-ecall.patch
    patch --fuzz=0 -d ${KEYSTONE_COPY} -p1 < \
        ${UNPACKDIR}/0004-keystone-vf2-opensbi-1.6-trap-context.patch
    patch --fuzz=0 -d ${KEYSTONE_COPY} -p1 < \
        ${UNPACKDIR}/0005-keystone-vf2-opensbi-1.6-pmp-ipi.patch
    patch --fuzz=0 -d ${KEYSTONE_COPY} -p1 < \
        ${UNPACKDIR}/0006-keystone-vf2-opensbi-1.6-interrupt-return.patch
    patch --fuzz=0 -d ${KEYSTONE_COPY} -p1 < \
        ${UNPACKDIR}/0007-keystone-p550-publish-exact-entry-context.patch
    patch --fuzz=0 -d ${KEYSTONE_COPY} -p1 < \
        ${UNPACKDIR}/0008-keystone-p550-enable-enclave-cycle-counter.patch
    patch --fuzz=0 -d ${KEYSTONE_COPY} -p1 < \
        ${UNPACKDIR}/0009-keystone-p550-queue-pmp-ipi.patch
    patch --fuzz=0 -d ${KEYSTONE_COPY} -p1 < \
        ${UNPACKDIR}/0010-keystone-p550-retrigger-stalled-pmp-ipi.patch
    patch --fuzz=0 -d ${KEYSTONE_COPY} -p1 < \
        ${UNPACKDIR}/0012-keystone-p550-restore-pmp-ownership.patch
    patch --fuzz=0 -d ${S} -p1 < \
        ${UNPACKDIR}/0013-opensbi-p550-hand-pmp-back-to-keystone.patch
    patch --fuzz=0 -d ${S} -p1 < \
        ${UNPACKDIR}/0019-keystone-p550-use-opensbi-trap-entry.patch
    patch --fuzz=0 -d ${S} -p1 < \
        ${UNPACKDIR}/0022-keystone-p550-skip-opensbi-locked-pmp-layout.patch
}

addtask keystone_prepare after do_patch before do_configure

EXTRA_OEMAKE:append = " \
    KEYSTONE_SM=${KEYSTONE_COPY} \
    KEYSTONE_SDK_DIR=${KEYSTONE_SDK_COPY} \
"
