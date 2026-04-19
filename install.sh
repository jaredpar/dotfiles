#!/usr/bin/env bash

set -euo pipefail

log() {
    printf '[dotfiles] %s\n' "$*"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backup_root="${HOME}/.dotfiles-backup"
timestamp="$(date +%Y%m%d%H%M%S)"
backup_dir=""
default_packages=(bash git profile vim zsh)
apt_updated=false

if [ -n "${DOTFILES_PACKAGES:-}" ]; then
    read -r -a packages <<<"${DOTFILES_PACKAGES}"
else
    packages=("${default_packages[@]}")
fi

apt_install_packages() {
    local missing_packages=()
    local package

    for package in "$@"; do
        if ! dpkg -s "${package}" >/dev/null 2>&1; then
            missing_packages+=("${package}")
        fi
    done

    if [ "${#missing_packages[@]}" -eq 0 ]; then
        return
    fi

    if [ -z "${CODESPACES:-}" ] || ! command -v apt-get >/dev/null 2>&1; then
        log "Missing required packages: ${missing_packages[*]}"
        exit 1
    fi

    if [ "${apt_updated}" = false ]; then
        log "Updating apt package metadata"
        run_apt_get update
        apt_updated=true
    fi

    log "Installing packages: ${missing_packages[*]}"
    run_apt_get install -y "${missing_packages[@]}"
}

run_apt_get() {
    if [ "$(id -u)" -eq 0 ]; then
        DEBIAN_FRONTEND=noninteractive apt-get \
            -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold \
            "$@"
        return
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get \
            -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold \
            "$@"
        return
    fi

    log "apt-get requires root or sudo"
    exit 1
}

run_with_privileges() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
        return
    fi

    log "Command requires root or sudo: $*"
    exit 1
}

install_latest_btm() {
    local arch
    local current_version=""
    local deb_path
    local deb_url
    local release_json
    local tag_name
    local tmpdir
    local version

    if [ -z "${CODESPACES:-}" ]; then
        return
    fi

    apt_install_packages ca-certificates curl python3

    arch="$(dpkg --print-architecture)"
    case "${arch}" in
        amd64|arm64)
            ;;
        *)
            log "Unsupported architecture for btm release install: ${arch}"
            exit 1
            ;;
    esac

    release_json="$(curl -fsSL https://api.github.com/repos/ClementTsang/bottom/releases/latest)"
    tag_name="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' <<<"${release_json}")"
    version="${tag_name#v}"

    if command -v btm >/dev/null 2>&1; then
        current_version="$(btm --version | awk 'NR == 1 { print $2 }')"
    fi

    if [ "${current_version}" = "${version}" ]; then
        log "btm ${version} already installed"
        return
    fi

    deb_url="$(python3 -c '
import json
import sys

arch = sys.argv[1]
tag_name = None
release = json.load(sys.stdin)
tag_name = release["tag_name"].lstrip("v")
asset_name = f"bottom_{tag_name}-1_{arch}.deb"

for asset in release["assets"]:
    if asset["name"] == asset_name:
        print(asset["browser_download_url"])
        raise SystemExit(0)

raise SystemExit(f"Could not find {asset_name} in latest bottom release")
' "${arch}" <<<"${release_json}")"

    tmpdir="$(mktemp -d)"
    deb_path="${tmpdir}/btm.deb"

    log "Installing btm ${version} from GitHub releases"
    curl -fsSL "${deb_url}" -o "${deb_path}"
    run_apt_get install -y "${deb_path}"
    rm -rf "${tmpdir}"
}

ensure_copilot_cli() {
    local install_prefix="${DOTFILES_COPILOT_PREFIX:-/usr/local}"

    if [ -z "${CODESPACES:-}" ]; then
        return
    fi

    if command -v copilot >/dev/null 2>&1; then
        log "GitHub Copilot CLI already installed"
        return
    fi

    apt_install_packages ca-certificates curl

    log "Installing GitHub Copilot CLI"
    if [ "${install_prefix}" = "/usr/local" ]; then
        curl -fsSL https://gh.io/copilot-install | run_with_privileges env PREFIX="${install_prefix}" bash
    else
        mkdir -p "${install_prefix}/bin"
        curl -fsSL https://gh.io/copilot-install | env PREFIX="${install_prefix}" bash
    fi
}

ensure_stow() {
    if command -v stow >/dev/null 2>&1; then
        return
    fi

    apt_install_packages stow
}

ensure_codespaces_utilities() {
    if [ -z "${CODESPACES:-}" ]; then
        return
    fi

    apt_install_packages bat fzy gh
    install_latest_btm
    ensure_copilot_cli
}

backup_target() {
    local source="$1"
    local target="$2"
    local target_name
    local target_real=""
    local source_real=""

    if [ ! -e "${target}" ] && [ ! -L "${target}" ]; then
        return
    fi

    target_real="$(readlink -f "${target}" 2>/dev/null || true)"
    source_real="$(readlink -f "${source}" 2>/dev/null || true)"

    if [ -n "${target_real}" ] && [ "${target_real}" = "${source_real}" ]; then
        return
    fi

    if [ -z "${backup_dir}" ]; then
        backup_dir="${backup_root}/${timestamp}"
        mkdir -p "${backup_dir}"
    fi

    target_name="$(basename "${target}")"
    log "Backing up ${target} to ${backup_dir}/${target_name}"
    mv "${target}" "${backup_dir}/${target_name}"
}

backup_conflicts_for_package() {
    local package="$1"
    local entry
    local target

    while IFS= read -r -d '' entry; do
        target="${HOME}/$(basename "${entry}")"
        backup_target "${entry}" "${target}"
    done < <(find "${repo_root}/${package}" -mindepth 1 -maxdepth 1 -print0)
}

stow_package() {
    local package="$1"

    if [ ! -d "${repo_root}/${package}" ]; then
        log "Skipping missing package ${package}"
        return
    fi

    backup_conflicts_for_package "${package}"
    log "Applying ${package}"
    stow --restow --target="${HOME}" --dir="${repo_root}" "${package}"
}

ensure_stow
ensure_codespaces_utilities

for package in "${packages[@]}"; do
    stow_package "${package}"
done

log "Applied packages: ${packages[*]}"
if [ -n "${backup_dir}" ]; then
    log "Original files were backed up under ${backup_dir}"
fi