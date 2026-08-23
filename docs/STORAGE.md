# Storage and cleanup

## Why the old build filled 98 GB

The original target inherited SiFive `demo-coreip-cli`. Despite its name, that
image enables SDK, development, debug and documentation features and installs
large packages including TensorFlow Lite, OpenCV, QEMU, Rust and Boost. Yocto
also keeps native tools, target sysroots, package staging trees and shared
state. SiFive documents complete image builds as requiring well over 100 GB.

This project now downloads the official P550 Ubuntu image and limits Yocto to
the board bootchain. It no longer builds `keystone-p550-image` or any other
root filesystem.

## One-time cleanup after switching to the hybrid workflow

Preview the exact paths and their sizes:

```bash
./scripts/clean-yocto-state.sh
```

Then delete the obsolete full-image state:

```bash
./scripts/clean-yocto-state.sh --apply
```

The cleanup removes only:

```text
build/
sstate-cache/
downloads/
build.log
fetch.log
```

It preserves `sources/`, `.venv/`, project files and the new
`release-cache/`. Keeping `sources/` avoids downloading the locked P550 and
Keystone repositories again.

Do not run a new build while the filesystem is still at 100%. Free space
first, then use `df -h .` to confirm that the filesystem has working room.
