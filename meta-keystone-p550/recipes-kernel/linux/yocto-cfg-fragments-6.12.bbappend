# Consume the source-lock-verified project clone directly. This avoids both
# the unauthenticated git:// transport and ambiguity between BitBake's remote
# mirror cache and the two different yocto-kernel-cache revisions we pin.
# SRCREV remains pinned by the upstream meta-virtualization recipe.
SRC_URI = "git://${TOPDIR}/../sources/yocto-kernel-cache;protocol=file;nobranch=1"
