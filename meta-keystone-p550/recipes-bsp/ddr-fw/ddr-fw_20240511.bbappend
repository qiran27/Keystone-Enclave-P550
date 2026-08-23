# The release uses an immutable SHA that is already seeded into BitBake's Git
# cache. Do not require the upstream SSH endpoint or a branch ref.
SRC_URI:remove = "git://git@github.com/sifive/hifive-premier-p550-tools.git;branch=${BRANCH};protocol=ssh"
SRC_URI:prepend = "git://github.com/sifive/hifive-premier-p550-tools.git;protocol=https;nobranch=1 "
