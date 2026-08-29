ARG BASE_IMAGE=quay.io/hummingbird-community/bootc-os:latest@sha256:c5539f9ed4d93aab6bd41e4f5aef8ab83055f3f9e855a47b69fadb7420d0d1df
ARG COMMON_IMAGE=ghcr.io/projectbluefin/common
ARG COMMON_IMAGE_SHA=sha256:fb943c87866292fb74eb74610e9cd08a1a91fe42e763e28473f3f57cf18f26a5
ARG BREW_IMAGE=ghcr.io/ublue-os/brew
ARG BREW_IMAGE_SHA=sha256:8f952ae54585db9f855a306ef365e13609ed7c7944b12b823ba7d5ce8e1a145b

FROM ${COMMON_IMAGE}@${COMMON_IMAGE_SHA} AS common
FROM ${BREW_IMAGE}@${BREW_IMAGE_SHA} AS brew
FROM ${BASE_IMAGE}

ARG IMAGE_NAME=utah
ARG IMAGE_FLAVOR=main
ARG IMAGE_VENDOR=hanthor
ARG VERSION=testing
ARG SHA_HEAD_SHORT=unknown

LABEL org.opencontainers.image.title="Utah"
LABEL org.opencontainers.image.description="A Hummingbird-based Bluefin GNOME workstation"
LABEL org.opencontainers.image.source="https://github.com/hanthor/utah"
LABEL org.opencontainers.image.vendor="${IMAGE_VENDOR}"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL containers.bootc=1

COPY packages/bluefin.toml /usr/share/utah/bluefin.toml
COPY packages/utah.toml /usr/share/utah/utah.toml
COPY packages/hummingbird.repo /etc/yum.repos.d/hummingbird.repo
COPY packages/fedora-44.repo /etc/yum.repos.d/fedora-44.repo
COPY scripts/install-packages.py /usr/local/libexec/utah-install-packages
COPY scripts/verify-rpm-contract.py /usr/local/libexec/utah-verify-rpm-contract
COPY scripts/build-gnome-extensions.sh /usr/local/libexec/utah-build-gnome-extensions
COPY scripts/install-ogc-kernel.sh /usr/local/libexec/utah-install-ogc-kernel
COPY scripts/install-nvidia.sh /usr/local/libexec/utah-install-nvidia
COPY scripts/clean-stage.sh /usr/local/libexec/utah-clean-stage
COPY --from=common /system_files/shared /tmp/utah-common
COPY --from=brew /system_files /tmp/utah-brew
COPY system_files/shared /tmp/utah-local

RUN chmod 0755 /usr/local/libexec/utah-install-packages /usr/local/libexec/utah-verify-rpm-contract /usr/local/libexec/utah-build-gnome-extensions /usr/local/libexec/utah-install-ogc-kernel /usr/local/libexec/utah-install-nvidia /usr/local/libexec/utah-clean-stage && \
    cp -a /tmp/utah-common/. / && \
    cp -a /tmp/utah-brew/. / && \
    cp -a /tmp/utah-local/. / && \
    rm -rf /tmp/utah-common /tmp/utah-brew /tmp/utah-local

# This first check covers the flavor-independent contract only, which is why it
# pins IMAGE_FLAVOR=main. verify-rpm-contract.py reads IMAGE_FLAVOR from the
# environment, and the build sets it, so without this the nvidia flavors
# asserted here that nvidia-driver, nvidia-driver-cuda and
# nvidia-container-toolkit were installed -- several steps before
# utah-install-nvidia runs. The flavor-aware assertion is the second call,
# after the NVIDIA and OGC step.
#
# Utah keeps Bluefin's user-facing package contract.  Hummingbird supplies the
# bootable base; Hummingbird's own repository plus Fedora 44 supply the rest,
# which is the pairing Hummingbird composes its own buildroot from.
# A missing package is a build failure: silently skipping one would make parity
# claims meaningless.  The only exceptions are the packages listed under
# [unavailable] in packages/utah.toml, each of which carries a tracking issue.
#
# The package lists live in the manifests, not here.  When they were spelled
# out in this RUN as well, the two copies drifted and the contract check was
# asserting a different set than the install had asked for.
RUN /usr/local/libexec/utah-install-packages \
      /usr/share/utah/bluefin.toml /usr/share/utah/utah.toml && \
    IMAGE_FLAVOR=main /usr/local/libexec/utah-verify-rpm-contract \
      /usr/share/utah/bluefin.toml /usr/share/utah/utah.toml && \
    DNF="$(command -v dnf5 || command -v dnf)" && \
    "$DNF" clean all && rm -rf /var/cache/libdnf5 /var/cache/dnf

# The extensions are the same pinned submodules Bluefin ships. Keeping their
# build here makes GNOME 51 compatibility visible in the normal image CI path.
RUN /usr/local/libexec/utah-build-gnome-extensions && \
    glib-compile-schemas /usr/share/glib-2.0/schemas

# Dakota-compatible flavors: OGC is built and asserted before NVIDIA so the
# NVIDIA path can bind its module to the exact kernel tree it will boot.
RUN case "${IMAGE_FLAVOR}" in \
      gaming|nvidia-gaming) /usr/local/libexec/utah-install-ogc-kernel ;; \
      main|nvidia) ;; \
      *) echo "Unknown Utah image flavor: ${IMAGE_FLAVOR}" >&2; exit 2 ;; \
    esac && \
    case "${IMAGE_FLAVOR}" in \
      nvidia|nvidia-gaming) /usr/local/libexec/utah-install-nvidia "${IMAGE_FLAVOR}" ;; \
      main|gaming) ;; \
    esac && \
    IMAGE_FLAVOR="${IMAGE_FLAVOR}" /usr/local/libexec/utah-verify-rpm-contract \
      /usr/share/utah/bluefin.toml /usr/share/utah/utah.toml

# Everything above writes build-time residue that bootc lint rejects: dnf logs
# under /var/log, cockpit and dnf state under /run, and ~45 /var directories
# with no tmpfiles.d entry. This must run after the last package install, which
# is the NVIDIA and OGC step, not after the main transaction.
RUN /usr/local/libexec/utah-clean-stage

RUN bootc container lint --fatal-warnings --skip nonempty-boot

CMD ["/sbin/init"]
