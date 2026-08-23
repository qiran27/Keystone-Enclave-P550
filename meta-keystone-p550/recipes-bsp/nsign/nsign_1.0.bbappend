# The exact nsign revision is pinned by meta-sifive and sources.lock.yml.
SRC_URI:remove = "git://github.com/eswincomputing/Esbd-77serial-nsign.git;branch=${BRANCH};protocol=https"
SRC_URI:prepend = "git://github.com/eswincomputing/Esbd-77serial-nsign.git;protocol=https;nobranch=1 "
