ARG BASE_IMAGE=quay.io/hummingbird-community/bootc-os:latest@sha256:c5539f9ed4d93aab6bd41e4f5aef8ab83055f3f9e855a47b69fadb7420d0d1df
FROM ${BASE_IMAGE}

ARG IMAGE_NAME=utah
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

RUN chmod 0755 /usr/local/libexec/utah-install-packages /usr/local/libexec/utah-verify-rpm-contract

# Utah keeps Bluefin's user-facing package contract, with TunaOS's GNOME 51
# stack preferred over the Hummingbird base packages. A missing package is a
# build failure: silently skipping one would make parity claims meaningless.
RUN dnf5 -y install python3-dnf5 && \
    /usr/local/libexec/utah-install-packages /usr/share/utah/bluefin.toml && \
    dnf5 -y install \
      gnome-control-center gnome-session gnome-settings-daemon gnome-shell \
      gsettings-desktop-schemas gtk4 libadwaita mutter \
      xdg-desktop-portal xdg-desktop-portal-gnome && \
    dnf5 -y remove \
      fedora-bookmarks fedora-third-party firefox-langpacks \
      gnome-extensions-app gnome-shell-extension-background-logo \
      gnome-software gnome-software-rpm-ostree gnome-terminal-nautilus \
      yelp || true && \
    /usr/local/libexec/utah-verify-rpm-contract /usr/share/utah/bluefin.toml && \
    dnf5 clean all && rm -rf /var/cache/libdnf5

RUN bootc container lint --fatal-warnings --skip nonempty-boot

CMD ["/sbin/init"]
