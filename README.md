# Utah

Utah is a single-variant GNOME workstation image: Bluefin's package experience
on Fedora Hummingbird, with the GNOME 51 stack supplied by
[TunaOS packages](https://github.com/tuna-os/tunaos-packages).

## Design

- One `utah:testing` image for `x86_64`; no NVIDIA or desktop variant matrix.
- Pinned Hummingbird `bootc-os` base, preserving its hardened and fast-moving
  upstream model.
- Bluefin's base package manifest is the compatibility contract.
- TunaOS's Hummingbird RPM repository is enabled at higher priority to provide
  the newer GNOME 51 packages.
- CI delegates builds, vulnerability reporting, SBOMs, keyless signatures,
  provenance, caching, and rechunking to `projectbluefin/actions@v1`.

## Build locally

```bash
just check
just build-ghcr utah testing main
```

The image is tagged `localhost/utah:testing`.
