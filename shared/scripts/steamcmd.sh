#!/bin/bash
# SteamCMD install and app update, shared by every game here that installs from
# Steam. Sourced, never executed.
#
# Reads:  STEAMCMD_DIR, SERVER_DIR, GAME_ID, USERNAME, PASSWRD, VALIDATE, and HOME
#         (which steamcmd_home() below is what sets - call it first)
# Sets:   STEAM_RC
# Exports: HOME

STEAMCMD_URL="https://media.steampowered.com/client/installer/steamcmd_linux.tar.gz"
STEAM_RC=0

# -----------------------------------------------------------------------------
# SteamCMD keeps its state under $HOME, including depotcache - the manifests an
# incremental update diffs against. gosu points $HOME at /home/steam, which is
# in the container's writable layer and so is destroyed whenever the container
# is recreated from a new image. Without the cached manifest SteamCMD has to
# ask Steam for it, and Steam refuses request codes for any manifest that is no
# longer the published one, which cancels the update outright and strands the
# server on its old build. Keep the cache on the same volume as the install it
# describes. This must be called after gosu, which sets HOME from passwd.
# -----------------------------------------------------------------------------
steamcmd_home() {
    export HOME="${SERVER_DIR}/home"
    mkdir -p "${HOME}"
}

# -----------------------------------------------------------------------------
# SteamCMD itself.
# -----------------------------------------------------------------------------
install_steamcmd() {
    if [ -f "${STEAMCMD_DIR}/steamcmd.sh" ]; then
        return 0
    fi
    echo "---SteamCMD not found, downloading---"
    mkdir -p "${STEAMCMD_DIR}"
    if ! curl -fsSL "${STEAMCMD_URL}" -o /tmp/steamcmd.tar.gz; then
        echo "---Could not download SteamCMD, exiting---"
        exit 1
    fi
    tar -xzf /tmp/steamcmd.tar.gz -C "${STEAMCMD_DIR}"
    rm -f /tmp/steamcmd.tar.gz
    chmod +x "${STEAMCMD_DIR}/steamcmd.sh"
}

run_steamcmd() {
    local args=( "+@sSteamCmdForcePlatformType" "windows" "+force_install_dir" "${SERVER_DIR}" )
    if [ -n "${USERNAME}" ]; then
        args+=( "+login" "${USERNAME}" "${PASSWRD}" )
    else
        args+=( "+login" "anonymous" )
    fi
    args+=( "+app_update" "${GAME_ID}" )
    if [ "${1:-}" = "validate" ]; then
        args+=( "validate" )
    fi
    args+=( "+quit" )
    "${STEAMCMD_DIR}/steamcmd.sh" "${args[@]}"
}

# Proton's lsteamclient bridges the game's Windows Steam API calls to the
# native Linux steamclient.so, and it looks for that in exactly two places:
#
#   $HOME/.steam/sdk64/steamclient.so
#   $HOME/.steam/sdk32/steamclient.so
#
# (lsteamclient/unixlib.cpp). That is the long-standing convention for
# Steamworks dedicated servers. Miss it and lsteamclient does not fail softly -
# it asserts, aborting the process the moment the game first touches the Steam
# API, which for ASA is a second or so after startup. SteamCMD ships both
# libraries once it has run, so link them into place.
link_steam_sdk() {
    local bits src dst
    for bits in 64 32; do
        src="${STEAMCMD_DIR}/linux${bits}/steamclient.so"
        dst="${HOME}/.steam/sdk${bits}"
        if [ -f "${src}" ]; then
            mkdir -p "${dst}" 2>/dev/null || continue
            ln -sfn "${src}" "${dst}/steamclient.so" 2>/dev/null || true
        else
            echo "---Note: ${src} is missing; the Steam API bridge may not load---"
        fi
    done
}

# -----------------------------------------------------------------------------
# Install or update the game, and recover from the one failure that otherwise
# strands a server on its old build forever. Sets STEAM_RC.
# -----------------------------------------------------------------------------
update_game() {
    local STEAM_LOG="${HOME}/Steam/logs/content_log.txt"
    local STEAM_MANIFEST="${SERVER_DIR}/steamapps/appmanifest_${GAME_ID}.acf"
    local STEAM_LOG_MARK STEAM_LOG_NOW

    # Where the log ends now, so the retry check below only reads this run's lines.
    STEAM_LOG_MARK=0
    [ -f "${STEAM_LOG}" ] && STEAM_LOG_MARK="$(wc -l < "${STEAM_LOG}")"

    if [ "${VALIDATE,,}" = "true" ]; then
        echo "---Validate is enabled, this pass will take longer---"
        run_steamcmd validate
    else
        run_steamcmd
    fi
    STEAM_RC=$?

    # SteamCMD truncates content_log.txt when it grows, which would leave the mark
    # past the end of the file and silently disable the recovery below. If the log
    # shrank, the mark means nothing - read the whole file.
    STEAM_LOG_NOW=0
    [ -f "${STEAM_LOG}" ] && STEAM_LOG_NOW="$(wc -l < "${STEAM_LOG}")"
    [ "${STEAM_LOG_NOW}" -lt "${STEAM_LOG_MARK}" ] && STEAM_LOG_MARK=0

    # Steam stops issuing manifest request codes for a depot's old manifest once a
    # new build ships. SteamCMD asks for the installed manifest as the delta source,
    # is refused with 'Access Denied', and cancels the update rather than falling
    # back to a plain download - so it moves zero bytes, leaves the app flagged
    # update-required, and every later start fails identically. VALIDATE does not
    # help; the request comes first. The stale pointer is the appmanifest's
    # InstalledDepots entry, so drop the file and there is nothing to delta from.
    # Seen on 2026-08-27 going from build 24827022 to 24976862.
    if [ "${STEAM_RC}" -ne 0 ] && [ -f "${STEAM_MANIFEST}" ] && \
       tail -n "+$((STEAM_LOG_MARK + 1))" "${STEAM_LOG}" 2>/dev/null \
       | grep -q "Failed to get manifest request code"; then
        echo "---Steam refused the delta source: this build's installed manifest is retired---"
        echo "---Dropping the stale appmanifest and retrying with validate---"
        mv "${STEAM_MANIFEST}" "${STEAM_MANIFEST}.stale"
        run_steamcmd validate
        STEAM_RC=$?
    fi

    # SteamCMD's very first run on an empty steamcmd directory downloads its own
    # update and re-execs ("Restarting steamcmd by request"), and app_update on
    # that same pass intermittently gives up with
    #   ERROR! Failed to install app 'NNN' (Missing configuration)
    # and exit 8, after a clean anonymous login. It is Steam's own first-run
    # state, not ours: measured 2026-09-07 at roughly one run in two, and it
    # reproduces identically with steamcmd invoked by hand, no runner involved.
    # The next attempt runs against a warm directory and works every time.
    #
    # Retry once, and only when nothing was installed at all. A failure with an
    # appmanifest already on disk is a real error - out of space, a bad depot -
    # and retrying that just doubles the wait before the same message. The
    # .stale check keeps this from firing as a third attempt right after the
    # retired-manifest recovery above, which moves the manifest out of the way.
    if [ "${STEAM_RC}" -ne 0 ] && [ ! -f "${STEAM_MANIFEST}" ] && \
       [ ! -f "${STEAM_MANIFEST}.stale" ]; then
        echo "---SteamCMD installed nothing on its first pass (exit ${STEAM_RC})---"
        echo "---That is usually its own first-run bootstrap. Trying once more---"
        run_steamcmd
        STEAM_RC=$?
    fi
}
