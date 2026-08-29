#!/usr/bin/bash
# Strip build-time residue that `bootc container lint --fatal-warnings` rejects.
#
# This mirrors Bluefin's build_files/shared/clean-stage.sh, deliberately: Utah
# keeps Bluefin's package contract, so it inherits Bluefin's image hygiene too.
# Only the filesystem portion is ported. Bluefin's script also disables
# flatpak-add-fedora-repos.service and clears a dnf5 versionlock, neither of
# which exists here.
#
# The three lint checks this satisfies, all seen failing on a real build:
#
#   nonempty-run-tmp  /run/cockpit, /run/dnf and friends. /run is a tmpfs at
#                     runtime, so anything baked into the image is junk.
#   var-log           /var/log/dnf5.log and its rotations, written by the
#                     install step itself.
#   var-tmpfiles      /var/cache/ibus, /var/cache/ldconfig, /var/cache/libX11,
#                     /var/cache/swcatalog and ~40 more directories that have
#                     no systemd tmpfiles.d entry to recreate them.

set -eoux pipefail

# Applied as a prefix to every path so the script can be exercised against a
# temporary directory rather than the live filesystem.
CLEAN_ROOT="${CLEAN_ROOT:-/}"

# Everything under /var except the caches bootc itself expects to survive.
find "${CLEAN_ROOT}/var"/* -maxdepth 0 -type d \! -name cache -exec rm -fr {} \;
find "${CLEAN_ROOT}/var/cache"/* -maxdepth 0 -type d \! -name libdnf5 \! -name rpm-ostree -exec rm -fr {} \;

# Non-directory leftovers /var lint also flags: ldconfig's aux-cache, ibus's
# registry, the swcatalog .xb files, the ssh host key migration stamp.
find "${CLEAN_ROOT}/var" -mindepth 1 -type f -delete 2>/dev/null || true

rm -rf "${CLEAN_ROOT:?}/tmp" && mkdir -p "${CLEAN_ROOT:?}/tmp" && chmod 1777 "${CLEAN_ROOT:?}/tmp"
rm -rf "${CLEAN_ROOT:?}/run" && mkdir -p "${CLEAN_ROOT:?}/run"
