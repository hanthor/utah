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
COPY packages/tunaos-hummingbird.repo /etc/yum.repos.d/tunaos-hummingbird.repo
COPY scripts/install-packages.py /usr/local/libexec/utah-install-packages
COPY scripts/verify-rpm-contract.py /usr/local/libexec/utah-verify-rpm-contract
COPY scripts/build-gnome-extensions.sh /usr/local/libexec/utah-build-gnome-extensions
COPY scripts/install-ogc-kernel.sh /usr/local/libexec/utah-install-ogc-kernel
COPY scripts/install-nvidia.sh /usr/local/libexec/utah-install-nvidia
COPY --from=common /system_files/shared /tmp/utah-common
COPY --from=brew /system_files /tmp/utah-brew
COPY system_files/shared /tmp/utah-local

RUN chmod 0755 /usr/local/libexec/utah-install-packages /usr/local/libexec/utah-verify-rpm-contract /usr/local/libexec/utah-build-gnome-extensions /usr/local/libexec/utah-install-ogc-kernel /usr/local/libexec/utah-install-nvidia && \
    cp -a /tmp/utah-common/. / && \
    cp -a /tmp/utah-brew/. / && \
    cp -a /tmp/utah-local/. / && \
    rm -rf /tmp/utah-common /tmp/utah-brew /tmp/utah-local

# Utah keeps Bluefin's user-facing package contract, with TunaOS's GNOME 51
# stack preferred over the Hummingbird base packages. A missing package is a
# build failure: silently skipping one would make parity claims meaningless.
RUN DNF="$(command -v dnf5 || command -v dnf)" && \
    /usr/local/libexec/utah-install-packages /usr/share/utah/bluefin.toml && \
    "$DNF" -y install \
      gnome-control-center gnome-session gnome-settings-daemon gnome-shell \
      gsettings-desktop-schemas gtk4 libadwaita mutter \
      xdg-desktop-portal xdg-desktop-portal-gnome \
      cmake dbus-devel glib2-devel meson sassc unzip && \
    "$DNF" -y remove \
      fedora-bookmarks fedora-third-party firefox-langpacks \
      gnome-extensions-app gnome-shell-extension-background-logo \
      gnome-software gnome-software-rpm-ostree gnome-terminal-nautilus \
      yelp || true && \
    /usr/local/libexec/utah-verify-rpm-contract /usr/share/utah/bluefin.toml && \
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
    IMAGE_FLAVOR="${IMAGE_FLAVOR}" /usr/local/libexec/utah-verify-rpm-contract /usr/share/utah/bluefin.toml

RUN bootc container lint --fatal-warnings --skip nonempty-boot

CMD ["/sbin/init"]
