repo_organization := env_var_or_default("REPO_ORGANIZATION", "hanthor")
image := "utah"

default:
    @just --list

check:
    #!/usr/bin/env bash
    set -euo pipefail
    test -f Containerfile
    test -f packages/bluefin.toml
    test -f packages/utah.toml
    python3 -m py_compile scripts/install-packages.py
    python3 -m py_compile scripts/verify-rpm-contract.py
    python3 -m py_compile scripts/check-repo-availability.py
    python3 scripts/install-packages.py --check packages/bluefin.toml
    python3 scripts/verify-rpm-contract.py --check packages/bluefin.toml
    grep -q 'projectbluefin/actions/.github/workflows/reusable-build.yml@v1' .github/workflows/build.yml

# Fail fast when a contract package is in none of the repositories the image
# actually enables, instead of discovering it twenty minutes into a build.
# Checks names only -- it does not assert versions.  Needs network access.
check-repos:
    python3 scripts/check-repo-availability.py packages/bluefin.toml packages/utah.toml

# packages/bluefin.toml is a verbatim copy of Bluefin's base.toml.  Drift here
# is a parity bug, so make it loud rather than letting it accumulate quietly.
check-parity:
    #!/usr/bin/env bash
    set -euo pipefail
    upstream=$(mktemp)
    trap 'rm -f "$upstream"' EXIT
    curl -fsSL -o "$upstream" \
      https://raw.githubusercontent.com/projectbluefin/bluefin/main/build_files/packages/base.toml
    if diff -u "$upstream" packages/bluefin.toml; then
      echo "packages/bluefin.toml matches projectbluefin/bluefin"
    else
      echo "packages/bluefin.toml has drifted from projectbluefin/bluefin" >&2
      exit 1
    fi

image_name base_name stream flavor:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ flavor }}" in
      main) echo "{{ image }}" ;;
      nvidia) echo "{{ image }}-nvidia" ;;
      gaming) echo "{{ image }}-gaming" ;;
      nvidia-gaming) echo "{{ image }}-nvidia-gaming" ;;
      *) echo "unknown Utah image flavor: {{ flavor }}" >&2; exit 2 ;;
    esac

generate-default-tag stream build_number:
    @echo "{{ stream }}"

setup-cache base_name stream build_number event_name:
    @echo "utah-{{ stream }} 1"

build-ghcr base_name stream flavor kernel_pin="":
    #!/usr/bin/env bash
    set -euo pipefail
    version="{{ stream }}-$(date -u +%Y%m%d)-$(git rev-parse --short HEAD)"
    case "{{ flavor }}" in
      main) image_name="{{ image }}" ;;
      nvidia) image_name="{{ image }}-nvidia" ;;
      gaming) image_name="{{ image }}-gaming" ;;
      nvidia-gaming) image_name="{{ image }}-nvidia-gaming" ;;
      *) echo "unknown Utah image flavor: {{ flavor }}" >&2; exit 2 ;;
    esac
    podman build \
      --build-arg IMAGE_NAME="$image_name" \
      --build-arg IMAGE_FLAVOR={{ flavor }} \
      --build-arg IMAGE_VENDOR={{ repo_organization }} \
      --build-arg VERSION="$version" \
      --build-arg SHA_HEAD_SHORT="$(git rev-parse --short HEAD)" \
      --tag "localhost/$image_name:{{ stream }}" \
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
    image_name="$(just image_name '{{ base_name }}' '{{ stream }}' '{{ flavor }}')"
    mkdir -p "sbom_out/$image_name"
    "{{ syft_cmd }}" "localhost/$image_name:{{ stream }}" -o json >"sbom_out/$image_name/sbom.json"

secureboot base_name default_tag flavor:
    #!/usr/bin/env bash
    set -euo pipefail
    image_name="$(just image_name '{{ base_name }}' '{{ default_tag }}' '{{ flavor }}')"
    podman run --rm --entrypoint /bin/sh "localhost/$image_name:{{ default_tag }}" -c 'test -e /usr/lib/modules || test -e /boot'
