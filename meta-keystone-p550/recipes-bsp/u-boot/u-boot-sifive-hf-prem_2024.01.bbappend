# meta-sifive names the release with the EIC7X-2025.01 tag. A tag-valued
# SRCREV makes BitBake run `git ls-remote` while parsing recipes, so a
# temporary DNS outage aborts the build before normal fetch retries apply.
# Pin the exact commit recorded in sources.lock.yml instead. This is the
# commit to which EIC7X-2025.01 resolves in the 2025.11.00-HFP550 release.
SRCREV = "6c8f710028e52709b29b70809131509f2edfb1e5"

SRC_URI:remove = "git://github.com/eswincomputing/u-boot.git;protocol=https;branch=u-boot-2024.01-EIC7X"
SRC_URI:prepend = "git://github.com/eswincomputing/u-boot.git;protocol=https;nobranch=1 "
