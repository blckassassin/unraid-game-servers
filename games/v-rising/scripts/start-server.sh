#!/bin/bash
# V Rising dedicated server runner.
#
# Like ASA, V Rising ships no Linux server binary, so this installs the Windows
# depot with SteamCMD and runs VRisingServer.exe under GE-Proton. Three things
# differ from the ASA runner:
#
# 1. It needs a display. VRisingServer.exe will not start without one even
#    headless, so the launch goes through xvfb-run.
# 2. Nothing rewrites the config. Every ServerHostSettings.json field has a
#    command-line override that beats the file, so the template's fields are
#    passed as flags and the seeded JSON is never touched again. That is what
#    lets a hand edit and a template field coexist.
# 3. Shutdown does not use RCON. V Rising saves on SIGINT (not SIGTERM), so the
#    handler signals the process directly. RCON ships purely as an admin tool.

set -u
umask "${UMASK:-000}"

# shellcheck source=/dev/null
source /opt/scripts/proton.sh
# shellcheck source=/dev/null
source /opt/scripts/steamcmd.sh

SERVER_EXE="VRisingServer.exe"
SERVER_LOG="${SERVER_DIR}/logs/VRisingServer.log"
SETTINGS_SRC="${SERVER_DIR}/VRisingServer_Data/StreamingAssets/Settings"
BURST_DLL="${SERVER_DIR}/VRisingServer_Data/Plugins/x86_64/lib_burst_generated.dll"

SERVER_PID=""
LOG_TAIL_PID=""
SHUTTING_DOWN="false"
FLAGS=()

steamcmd_home
raise_nofile

# -----------------------------------------------------------------------------
# Settings. Seeded once from the defaults the server ships with, then never
# written again - not on upgrade, not on restart. Everything the Unraid template
# controls arrives as a launch flag instead (see build_flags), and flags beat
# the file, so a template field and a hand edit can both be right at once.
#
# ServerGameSettings.json - the ~60 gameplay knobs - is seeded and then left
# alone entirely. Nothing in this container ever reads or writes it.
# -----------------------------------------------------------------------------
seed_settings() {
    if [ -d "${DATA_PATH}/Settings" ]; then
        return 0
    fi
    if [ ! -d "${SETTINGS_SRC}" ]; then
        echo "---No shipped settings at ${SETTINGS_SRC}, letting the server write its own---"
        return 0
    fi
    echo "---Seeding Settings/ from the defaults this build ships with---"
    mkdir -p "${DATA_PATH}"
    cp -R "${SETTINGS_SRC}" "${DATA_PATH}/"
}

# -----------------------------------------------------------------------------
# lib_burst_generated.dll is compiled for AVX and aborts the server on a CPU
# without it - not rare on the older Xeons a lot of Unraid boxes are built on.
# Moving it aside makes the server fall back to its portable path. A SteamCMD
# update restores the DLL, so this runs on every boot rather than once.
# -----------------------------------------------------------------------------
check_avx() {
    if grep -qw avx /proc/cpuinfo; then
        return 0
    fi
    if [ -f "${BURST_DLL}" ]; then
        echo "---This CPU has no AVX; moving lib_burst_generated.dll aside---"
        mv -f "${BURST_DLL}" "${BURST_DLL}.bak"
    fi
}

# -----------------------------------------------------------------------------
# Launch flags. Every one of these overrides the matching ServerHostSettings.json
# field, which is why nothing has to rewrite that file.
#
# An empty value is omitted rather than passed blank: -password "" is not the
# same as no -password at all when the seeded file already holds one.
# -----------------------------------------------------------------------------
build_flags() {
    FLAGS=( "-persistentDataPath" "${DATA_PATH}" "-logFile" "${SERVER_LOG}" )
    FLAGS+=( "-serverName" "${SERVER_NAME}" )
    FLAGS+=( "-saveName" "${WORLD_NAME}" )
    FLAGS+=( "-gamePort" "${GAME_PORT}" "-queryPort" "${QUERY_PORT}" )
    FLAGS+=( "-maxUsers" "${MAX_PLAYERS}" "-maxAdmins" "${MAX_ADMINS}" )
    FLAGS+=( "-listOnSteam" "${LIST_ON_STEAM}" "-listOnEOS" "${LIST_ON_EOS}" )
    FLAGS+=( "-secure" "${SECURE}" )
    [ -n "${SERVER_DESC}" ]       && FLAGS+=( "-description" "${SERVER_DESC}" )
    [ -n "${SRV_PWD}" ]           && FLAGS+=( "-password" "${SRV_PWD}" )
    [ -n "${GAME_PRESET}" ]       && FLAGS+=( "-preset" "${GAME_PRESET}" )
    [ -n "${DIFFICULTY_PRESET}" ] && FLAGS+=( "-difficultyPreset" "${DIFFICULTY_PRESET}" )

    # V Rising's docs: the RCON password "must be configured, this cannot be
    # left empty". No admin password therefore means RCON off, not RCON open.
    if [ -n "${SRV_ADMIN_PWD}" ]; then
        FLAGS+=( "-rconEnabled" "true" "-rconPort" "${RCON_PORT}" "-rconPassword" "${SRV_ADMIN_PWD}" )
    else
        FLAGS+=( "-rconEnabled" "false" )
    fi

    if [ -n "${GAME_PARAMS_EXTRA}" ]; then
        local extra
        read -ra extra <<< "${GAME_PARAMS_EXTRA}"
        FLAGS+=( "${extra[@]}" )
    fi
}

# -----------------------------------------------------------------------------
# Shutdown. V Rising saves on SIGINT - NOT on SIGTERM. Measured 2026-09-07
# under GE-Proton10-34: SIGTERM kills it dead in under half a second with no
# save and nothing written to its log, while SIGINT writes a full save in about
# one second and exits 0 about three seconds later. A reference container that
# uses SIGTERM does so under plain wine64, which evidently translates it
# differently; do not "fix" this back to TERM on the strength of that.
#
# Signalling the game directly, rather than going through RCON, is what lets a
# server with no admin password still shut down cleanly. RCON's own `shutdown`
# command does save, but it schedules rather than acts - a `shutdown 1 msg`
# measured here took over three minutes to fire, far past any sane
# STOP_TIMEOUT - so it is an admin tool, not a shutdown path.
#
# The signal has to reach VRisingServer.exe itself, not the Proton launcher:
# SERVER_PID below is xvfb-run's, whose child is proton, whose child is the
# game. Signalling the launcher tears down the prefix without the game ever
# hearing about it, which is exactly the hard kill this function exists to
# avoid.
#
# Identifying that process is the whole problem. Three candidates match a naive
# search and only one of them is the game:
#
#   pkill -f VRisingServer.exe   matches too much. -f tests whole command lines,
#       and both wrappers carry the exe name in theirs: xvfb-run was invoked as
#       "sh /usr/bin/xvfb-run ... proton run ./VRisingServer.exe", and the Proton
#       launcher as "python3 .../proton run ./VRisingServer.exe".
#   pkill -x VRisingServer.exe   matches nothing. Linux truncates a process name
#       to 15 characters (TASK_COMM_LEN), so the game's is "VRisingServer.e".
#   filtering on /proc/<pid>/exe  looks right and is not. Debian's xvfb-run is
#       "#!/bin/sh", and on Debian /bin/sh is dash, so its exe resolves to
#       /usr/bin/dash - which no "is this a shell?" glob written for sh and bash
#       catches. That leaves the wrapper in the list, and SIGTERM to the wrapper
#       orphans the game while this function logs a clean shutdown.
#
# So match /proc/<pid>/comm - the kernel's own name for the process, which wine
# sets to the exe's basename - against that 15-character truncation. The wrappers
# keep their own comm ("dash", "python3"), so they fall out by construction
# rather than by a list of interpreters someone has to keep complete.
# -----------------------------------------------------------------------------
server_pids() {
    local pid comm
    for pid in $(pgrep -f "${SERVER_EXE}" 2>/dev/null); do
        [ "${pid}" = "$$" ] && continue
        comm="$(cat "/proc/${pid}/comm" 2>/dev/null)"
        # Derive the truncation rather than hardcoding "VRisingServer.e", so
        # renaming SERVER_EXE cannot silently stop this matching anything.
        [ "${comm}" = "${SERVER_EXE:0:15}" ] && echo "${pid}"
    done
}

graceful_shutdown() {
    [ "${SHUTTING_DOWN}" = "true" ] && return
    SHUTTING_DOWN="true"
    echo "---Shutdown requested, telling the server to save and exit---"

    local pids waited=0
    pids="$(server_pids)"

    if [ -z "${pids}" ]; then
        # Never signal a wrapper as a guess. Say plainly that the graceful path
        # was skipped, because the alternative - a hard kill under a "Server
        # stopped" message - is the one failure nobody would ever investigate.
        echo "---Could not identify the ${SERVER_EXE} process---"
        echo "---Skipping the save-and-exit path and killing the prefix instead.---"
        echo "---Progress since the last autosave is lost. This is a bug: please---"
        echo "---report it with the output of 'docker exec <name> ps -ef'.---"
        wineserver_kill
        sleep 5
    else
        echo "---Sending SIGINT to ${SERVER_EXE} (pid $(tr '\n' ' ' <<< "${pids}"))---"
        # INT, not TERM: TERM kills this server without saving. See the note above.
        # shellcheck disable=SC2086
        kill -INT ${pids} 2>/dev/null || true

        # Poll the game itself, not SERVER_PID. SERVER_PID is xvfb-run, which
        # outlives the game by however long it takes to tear the X server down,
        # so watching it would keep reporting "still running" after the save has
        # already finished. Saying something every 10s matters here: a silent
        # gap is exactly when someone decides to pull the plug mid-save.
        while [ -n "$(server_pids)" ] && [ "${waited}" -lt "${STOP_TIMEOUT}" ]; do
            sleep 2
            waited=$((waited + 2))
            if [ $((waited % 10)) -eq 0 ]; then
                echo "---Waiting for the server to exit (${waited}s of ${STOP_TIMEOUT}s)---"
            fi
        done

        if [ -n "$(server_pids)" ]; then
            echo "---Still running after ${STOP_TIMEOUT}s, killing the wine prefix---"
            wineserver_kill
            sleep 5
        fi
    fi

    # The game is down either way; clear the wrappers so tini is not left
    # waiting on an X server nobody is using.
    kill -9 "${SERVER_PID}" 2>/dev/null || true
    [ -n "${LOG_TAIL_PID}" ] && kill "${LOG_TAIL_PID}" 2>/dev/null
    echo "---Server stopped---"
    exit 0
}

trap graceful_shutdown SIGTERM SIGINT SIGQUIT

# -----------------------------------------------------------------------------
# Go
# -----------------------------------------------------------------------------
install_steamcmd

if ! resolve_proton; then
    exit 1
fi
proton_debug_env

# Proton expects to be told which game it is running. Without SteamGameId it
# silently disables its own logging entirely and protonfixes skips every fix.
export SteamAppId="${GAME_ID}"
export SteamGameId="${GAME_ID}"
export STEAM_COMPAT_APP_ID="${GAME_ID}"
setup_proton_prefix

echo "---Checking for V Rising updates---"
update_game

if [ ! -f "${SERVER_DIR}/${SERVER_EXE}" ]; then
    echo "---${SERVER_EXE} is missing after the SteamCMD run (exit ${STEAM_RC})---"
    echo "---Check free space and your appdata path---"
    exit 1
fi
if [ "${STEAM_RC}" -ne 0 ]; then
    echo "---SteamCMD exited ${STEAM_RC}, continuing with the files already on disk---"
fi

link_steam_sdk
seed_settings
check_avx
build_flags

mkdir -p "$(dirname "${SERVER_LOG}")"
: > "${SERVER_LOG}"
tail -F -n 0 "${SERVER_LOG}" 2>/dev/null &
LOG_TAIL_PID=$!

cd "${SERVER_DIR}" || exit 1
echo "---Starting V Rising '${SERVER_NAME}' on port ${GAME_PORT}, cap ${MAX_PLAYERS}---"
echo "---Save '${WORLD_NAME}' under ${DATA_PATH}---"
echo "---First boot builds the Proton prefix and can sit quiet for several minutes---"

# xvfb-run, not a bare launch: VRisingServer.exe needs a display even headless.
# --auto-servernum picks a free display number, so a restart never collides with
# a stale lock file from a container that was killed.
xvfb-run --auto-servernum --server-args='-screen 0 640x480x24:32' \
    "${PROTON_BIN}" run "./${SERVER_EXE}" "${FLAGS[@]}" &
SERVER_PID=$!

wait "${SERVER_PID}"
EXIT_CODE=$?

[ -n "${LOG_TAIL_PID}" ] && kill "${LOG_TAIL_PID}" 2>/dev/null

if [ "${SHUTTING_DOWN}" = "false" ]; then
    echo "---Server exited on its own with code ${EXIT_CODE}---"
    if [ ! -s "${SERVER_LOG}" ]; then
        echo "---No server log was written, so it failed before V Rising started.---"
        echo "---Set DEBUG=true and restart to capture wine and Proton output.---"
    fi
fi
exit "${EXIT_CODE}"
