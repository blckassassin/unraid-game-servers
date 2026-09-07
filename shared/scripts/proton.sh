#!/bin/bash
# GE-Proton install and prefix management, shared by every game here that runs a
# Windows binary. Sourced, never executed.
#
# Reads:  PROTON_DIR, PROTON_VERSION, PROTON_TESTED, SERVER_DIR, GAME_ID, DEBUG,
#         WINEDEBUG_OVERRIDE
# Sets:   PROTON_BIN, PROTON_RESOLVED
# Exports: STEAM_COMPAT_CLIENT_INSTALL_PATH, STEAM_COMPAT_DATA_PATH

PROTON_API="https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"
PROTON_BIN=""
PROTON_RESOLVED=""

# -----------------------------------------------------------------------------
# Open file limit. Proton's esync/fsync eat FDs fast and a Windows server dies
# with confusing wine errors when the limit is the usual 1024.
# -----------------------------------------------------------------------------
raise_nofile() {
    local HARD_NOFILE
    HARD_NOFILE="$(ulimit -Hn)"
    if [ "${HARD_NOFILE}" = "unlimited" ]; then
        ulimit -n 1048576 2>/dev/null || true
    else
        ulimit -n "${HARD_NOFILE}" 2>/dev/null || true
    fi
    echo "---Open file limit set to $(ulimit -n)---"
}

# -----------------------------------------------------------------------------
# GE-Proton
# -----------------------------------------------------------------------------
# GE-Proton changed its asset naming at GE-Proton11: releases now ship a
# -x86_64 and a -aarch64 tarball where they used to ship one unsuffixed file.
# Both spellings are still in play depending on which version you pin, and the
# aarch64 asset sorts first in the API listing, so picking "the first .tar.gz"
# lands you an ARM build on an amd64 host.
install_proton() {
    local requested="$1"
    local version="" url="" assets tarball tag base candidate

    if [ "${requested}" = "latest" ]; then
        echo "---Looking up the latest GE-Proton release---"
        assets="$(curl -fsSL "${PROTON_API}" \
                 | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url')"
        if [ -z "${assets}" ] || [ "${assets}" = "null" ]; then
            echo "---Could not reach the GitHub API (rate limited?)---"
            echo "---Pin a version instead, e.g. PROTON_VERSION=GE-Proton9-27---"
            return 1
        fi
        url="$(printf '%s\n' "${assets}" | grep -m1 'x86_64\.tar\.gz$')" || \
            url="$(printf '%s\n' "${assets}" | head -n1)"
        version="$(basename "${url}" .tar.gz)"
    else
        # Accept either the release tag (GE-Proton11-5) or the full asset name
        # (GE-Proton11-5-x86_64); the download path always wants the tag.
        tag="${requested%-x86_64}"
        base="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${tag}"
        for candidate in "${tag}-x86_64" "${tag}"; do
            if [ -x "${PROTON_DIR}/${candidate}/proton" ]; then
                version="${candidate}"
                break
            fi
            if curl -fsIL -o /dev/null "${base}/${candidate}.tar.gz"; then
                version="${candidate}"
                url="${base}/${candidate}.tar.gz"
                break
            fi
        done
        if [ -z "${version}" ]; then
            echo "---No downloadable tarball for '${requested}'---"
            echo "---Expected ${tag}-x86_64.tar.gz or ${tag}.tar.gz on that release---"
            return 1
        fi
    fi

    if [ -x "${PROTON_DIR}/${version}/proton" ]; then
        echo "---${version} already installed---"
        PROTON_BIN="${PROTON_DIR}/${version}/proton"
        return 0
    fi

    echo "---Downloading ${version}---"
    tarball="/tmp/${version}.tar.gz"
    if ! curl -fL "${url}" -o "${tarball}"; then
        echo "---Download of ${version} failed---"
        rm -f "${tarball}"
        return 1
    fi

    # Verify before extracting. Every GE-Proton release publishes a .sha512sum
    # next to the tarball, naming the file exactly as we saved it. A missing
    # sums file is a warning rather than a failure; a mismatch is fatal.
    if curl -fsSL "${url%.tar.gz}.sha512sum" -o "${tarball}.sha512sum"; then
        if ( cd /tmp && sha512sum -c --status "$(basename "${tarball}").sha512sum" ); then
            echo "---Checksum verified---"
        else
            echo "---Checksum MISMATCH for ${version}, refusing to extract---"
            rm -f "${tarball}" "${tarball}.sha512sum"
            return 1
        fi
    else
        echo "---No published checksum for ${version}, skipping verification---"
    fi
    rm -f "${tarball}.sha512sum"

    mkdir -p "${PROTON_DIR}"
    echo "---Extracting ${version}---"
    tar -xzf "${tarball}" -C "${PROTON_DIR}"
    rm -f "${tarball}"

    if [ ! -x "${PROTON_DIR}/${version}/proton" ]; then
        echo "---${version} did not extract as expected---"
        return 1
    fi

    PROTON_BIN="${PROTON_DIR}/${version}/proton"
    return 0
}

# -----------------------------------------------------------------------------
# Pick a Proton build: the requested one, or whatever is already on disk.
# -----------------------------------------------------------------------------
resolve_proton() {
    PROTON_BIN=""
    if ! install_proton "${PROTON_VERSION}"; then
        # Fall back to whatever build is already on disk rather than refusing to boot.
        PROTON_BIN="$(find "${PROTON_DIR}" -maxdepth 2 -name proton -type f -executable 2>/dev/null | sort -V | tail -n1)"
        if [ -z "${PROTON_BIN}" ]; then
            echo "---No usable Proton build available---"
            return 1
        fi
        echo "---Falling back to $(basename "$(dirname "${PROTON_BIN}")")---"
    fi
    echo "---Using Proton: ${PROTON_BIN}---"

    # These games are sensitive to the Proton build, so say something when this
    # is not the one the image was built and tested against. Checking for a deviation rather
    # than for specific bad versions means this never goes stale, and it also
    # catches a pinned old build or a fallback to whatever was already on disk.
    PROTON_RESOLVED="$(basename "$(dirname "${PROTON_BIN}")")"
    if [ -n "${PROTON_TESTED:-}" ] && [ "${PROTON_RESOLVED%-x86_64}" != "${PROTON_TESTED%-x86_64}" ]; then
        echo "---WARNING: this is not the Proton build this image was tested with---"
        echo "---  running: ${PROTON_RESOLVED}---"
        echo "---  tested:  ${PROTON_TESTED}---"
        echo "---If the server exits without producing any engine log output, this is---"
        echo "---the first thing to change: set PROTON_VERSION=${PROTON_TESTED} and---"
        echo "---delete ${PROTON_DIR} so the prefix is rebuilt.---"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Optional Proton/wine logging.
# -----------------------------------------------------------------------------
proton_debug_env() {
    # WINEDEBUG=-all silences exactly the output you need when the server dies
    # during startup, so DEBUG=true turns it back on and captures Proton's own log.
    # +loaddll matters most here: when a Windows binary dies before reaching its own
    # logging, the last DLL it loaded is usually the whole diagnosis.
    if [ "${DEBUG,,}" = "true" ]; then
        export PROTON_LOG=1
        export PROTON_LOG_DIR="${SERVER_DIR}/logs"
        export WINEDEBUG="${WINEDEBUG_OVERRIDE:-+err,+fixme,+loaddll}"
        mkdir -p "${PROTON_LOG_DIR}"
        echo "---DEBUG is on: Proton log at ${PROTON_LOG_DIR}/steam-${GAME_ID}.log---"
        echo "---Turn it off once you have what you need; it is noisy and slows startup---"
    fi
}

# -----------------------------------------------------------------------------
# The wine prefix.
# -----------------------------------------------------------------------------
setup_proton_prefix() {
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="${PROTON_DIR}/steam"
    export STEAM_COMPAT_DATA_PATH="${PROTON_DIR}/prefix"
    mkdir -p "${STEAM_COMPAT_CLIENT_INSTALL_PATH}" "${STEAM_COMPAT_DATA_PATH}"

    # A wine prefix belongs to the Proton build that created it, and handing one to
    # a different build fails in ways that are hard to read. Record who built it and
    # discard it when that changes, so switching PROTON_VERSION is enough on its own
    # - no one should have to know to go and delete a folder by hand.
    #
    # Nothing here needs preserving: every game keeps its saves and configs
    # elsewhere under SERVER_DIR, and Proton rebuilds the prefix on the next start.
    PREFIX_MARKER="${STEAM_COMPAT_DATA_PATH}/.created-by-proton"
    if [ -d "${STEAM_COMPAT_DATA_PATH}/pfx" ]; then
        PREFIX_BUILT_BY="$(cat "${PREFIX_MARKER}" 2>/dev/null || echo "an unknown build")"
        if [ "${PREFIX_BUILT_BY}" != "${PROTON_RESOLVED}" ]; then
            echo "---Prefix was built by ${PREFIX_BUILT_BY}, now running ${PROTON_RESOLVED}---"
            echo "---Discarding it so Proton rebuilds; saves and configs are untouched---"
            rm -rf "${STEAM_COMPAT_DATA_PATH:?}"
            mkdir -p "${STEAM_COMPAT_DATA_PATH}"
        fi
    fi
    printf '%s' "${PROTON_RESOLVED}" > "${PREFIX_MARKER}" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Tear the prefix down. The last resort in a shutdown handler, after the game
# has been asked nicely and has not gone.
# -----------------------------------------------------------------------------
wineserver_kill() {
    local ws
    ws="$(dirname "${PROTON_BIN}")/files/bin/wineserver"
    [ -x "${ws}" ] || ws="$(dirname "${PROTON_BIN}")/dist/bin/wineserver"
    if [ -x "${ws}" ]; then
        WINEPREFIX="${STEAM_COMPAT_DATA_PATH}/pfx" "${ws}" -k 2>/dev/null || true
    fi
}
