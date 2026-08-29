# Utah

Utah is a GNOME workstation image: Bluefin's package experience on Fedora
Hummingbird.

## Design

- Four `x86_64` flavors -- `main`, `nvidia`, `gaming`, `nvidia-gaming` --
  matching Bluefin's, on a single `testing` stream. `config/flavors.json` is the
  single source for the build, promote and release matrices; see below.
- Pinned Hummingbird `bootc-os` base, preserving its hardened and fast-moving
  upstream model.
- Bluefin's base package manifest is the compatibility contract.
- Bluefin's pinned `projectbluefin/common` and `ublue-os/brew` OCI payloads,
  plus its GNOME Extensions submodules, are retained with their normal build
  step.
- The OGC kernel and NVIDIA's open module are built from source, since neither
  Hummingbird nor UBlue publishes a build for this base. Both are cached in an
  image of their own so the cost is paid once per pin, not once per push; see
  below.
- CI delegates builds, vulnerability reporting, SBOMs, keyless signatures,
  provenance, caching, and rechunking to `projectbluefin/actions@v1`.

## Build locally

```bash
just check
just build-ghcr utah testing main
```

The image is tagged `localhost/utah:testing`.

### Image flavors

`config/flavors.json` decides which images exist. Everything derives from it --
the build matrix, the promote matrix, the release matrix, and whether the kernel
cache image below is built at all:

```bash
python3 scripts/flavors.py list          # ["main"]
python3 scripts/flavors.py needs-kernel  # false
```

All four are currently built. A flavor is switched off by removing it from
`flavors` and recording why under `retired`, which keeps the reason beside the
list rather than in a commit message; nothing else has to change, because the
scripts, the Containerfile stages and the cache image all stay put either way.

`just check` fails if any workflow names `utah-nvidia` or `utah-gaming`
directly. Those literals were previously duplicated across three workflows,
which meant narrowing the set in one place left the others promoting and
releasing images the build no longer produced.

### The kernel cache image

`gaming`, `nvidia` and `nvidia-gaming` need an OGC kernel and an NVIDIA kernel
module that no repository ships for this base, so Utah compiles them. That is
about half an hour for the kernel and several minutes for the module, and it
depends on nothing the image build does -- only on the pinned base image and on
`scripts/install-ogc-kernel.sh` and `scripts/install-nvidia.sh`.

So it is paid once, in a separate image built from `Containerfile.kernel` and
tagged with a hash of exactly those inputs:

```bash
just kernel-cache-tag     # the hash
just kernel-cache-ref     # ghcr.io/<owner>/utah-kernel-cache:<hash>
just build-kernel-cache
```

CI builds and pushes it only when that tag is not already published, and the
three flavors that need it use it as their base image; `main` uses the pristine
Hummingbird base and pulls none of it. The install scripts find the archives
under `/utah-cache` and unpack them. With no cache present -- a local
`just build-ghcr`, or the cache image's own build -- the same scripts compile
from source, so there is no second implementation to drift.

Editing either script changes the hash and forces a rebuild, comment-only edits
included. That is deliberate: the key can only ever rebuild something that did
not need it, never reuse something stale.
