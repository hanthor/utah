repo_organization := env_var_or_default("REPO_ORGANIZATION", "hanthor")
image := "utah"

default:
    @just --list

check:
    #!/usr/bin/env bash
    set -euo pipefail
    test -f Containerfile
    test -f packages/bluefin.toml
    python3 -m py_compile scripts/install-packages.py
    python3 -m py_compile scripts/verify-rpm-contract.py
    python3 scripts/install-packages.py --check packages/bluefin.toml
    python3 scripts/verify-rpm-contract.py --check packages/bluefin.toml
    grep -q 'projectbluefin/actions/.github/workflows/reusable-build.yml@v1' .github/workflows/build.yml

image_name base_name stream flavor:
    @echo "{{ image }}"

generate-default-tag stream build_number:
    @echo "{{ stream }}"

setup-cache base_name stream build_number event_name:
    @echo "utah-{{ stream }} 1"

build-ghcr base_name stream flavor kernel_pin="":
    #!/usr/bin/env bash
    set -euo pipefail
    version="${stream}-$(date -u +%Y%m%d)-$(git rev-parse --short HEAD)"
    podman build \
      --build-arg IMAGE_NAME={{ image }} \
      --build-arg IMAGE_VENDOR={{ repo_organization }} \
      --build-arg VERSION="$version" \
      --build-arg SHA_HEAD_SHORT="$(git rev-parse --short HEAD)" \
      --tag "localhost/{{ image }}:{{ stream }}" \
      --file Containerfile .

generate-build-tags base_name stream flavor kernel_pin build_number version event_name event_number:
    @echo "{{ stream }} {{ version }}"

tag-images image_name default_tag alias_tags:
    #!/usr/bin/env bash
    set -euo pipefail
    for tag in {{ alias_tags }}; do podman tag "localhost/{{ image_name }}:{{ default_tag }}" "localhost/{{ image_name }}:$tag"; done

gen-sbom base_name stream flavor syft_cmd:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "sbom_out/{{ image }}"
    "{{ syft_cmd }}" "localhost/{{ image }}:{{ stream }}" -o json >"sbom_out/{{ image }}/sbom.json"

secureboot base_name default_tag flavor:
    #!/usr/bin/env bash
    set -euo pipefail
    podman run --rm --entrypoint /bin/sh "localhost/{{ image }}:{{ default_tag }}" -c 'test -e /usr/lib/modules || test -e /boot'
