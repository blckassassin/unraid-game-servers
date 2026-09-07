#!/bin/bash
# ARK: Survival Ascended dedicated server runner.
#
# ASA has no native Linux server binary, so this installs the Windows depot with
# SteamCMD (forcing the windows platform type) and runs ArkAscendedServer.exe
# under GE-Proton.

set -u
umask "${UMASK:-000}"

# shellcheck source=/dev/null
source /opt/scripts/proton.sh
# shellcheck source=/dev/null
source /opt/scripts/steamcmd.sh

# First, before anything writes under $HOME: this repoints it at the volume so
# SteamCMD's depotcache survives the container being recreated.
steamcmd_home

SERVER_EXE="ArkAscendedServer.exe"

# Filled in by locate_game_dirs() once the files are on disk.
SERVER_EXE_DIR=""
GAME_ROOT=""
SAVED_DIR=""
CONFIG_DIR=""

SERVER_PID=""
LOG_TAIL_PID=""
WATCHDOG_PID=""
SHUTTING_DOWN="false"
CONFIG_UMASK_EFFECTIVE=""

# -----------------------------------------------------------------------------
# Open file limit, raised for Proton. See shared/scripts/proton.sh.
# -----------------------------------------------------------------------------
raise_nofile

# -----------------------------------------------------------------------------
# Permissions.
#
# The point of this is that you can open the config files over SMB from a
# Windows box and actually save them. Two things have to be true: the files need
# permissive modes, and every directory above them needs to be traversable.
#
# umask 000 handles files the server creates from here on (666 files, 777 dirs),
# but it does nothing for files that already exist - a migrated install, or
# anything wine created with a tighter mode - so the config tree gets an explicit
# recursive pass on every start. It is only the config and save data, not the
# game binaries, so this stays cheap.
# -----------------------------------------------------------------------------
# Turn a umask into the two modes it implies, exactly as the kernel does at
# creation time: files start from 0666, directories from 0777, umask bits come
# off. Directories have to be handled separately or they lose the execute bit
# and nothing underneath is reachable.
CONFIG_FILE_MODE=""
CONFIG_DIR_MODE=""
resolve_config_modes() {
    # CONFIG_UMASK is the knob; it falls back to the container-wide UMASK so
    # that by default there is a single number governing everything.
    local m="${CONFIG_UMASK:-${UMASK:-000}}"

    if ! [[ "${m}" =~ ^[0-7]{1,4}$ ]]; then
        echo "---CONFIG_UMASK '${m}' is not a valid octal umask, using 000---"
        m="000"
    fi

    local dec=$((8#${m}))
    CONFIG_FILE_MODE="$(printf '%04o' $(( 0666 & ~dec & 0777 )))"
    CONFIG_DIR_MODE="$(printf '%04o' $(( 0777 & ~dec & 0777 )))"
    CONFIG_UMASK_EFFECTIVE="${m}"
}

fix_share_perms() {
    if [ "${FIX_PERMS,,}" != "true" ]; then
        return 0
    fi

    [ -n "${SAVED_DIR}" ] && [ -d "${SAVED_DIR}" ] || return 0

    resolve_config_modes

    # The parent chain gets the directory mode too, otherwise a permissive
    # config folder still sits behind an unreachable parent.
    chmod "${CONFIG_DIR_MODE}" "${GAME_ROOT}" 2>/dev/null
    find "${SAVED_DIR}" -type d -exec chmod "${CONFIG_DIR_MODE}" {} + 2>/dev/null
    find "${SAVED_DIR}" -type f -exec chmod "${CONFIG_FILE_MODE}" {} + 2>/dev/null
}

# -----------------------------------------------------------------------------
# Locate the install. Finding the binary beats hardcoding ShooterGame/ - the
# layout has shifted before, and people arrive here with folders laid out by
# whichever container they used previously.
# -----------------------------------------------------------------------------
locate_game_dirs() {
    local hit
    hit="$(find "${SERVER_DIR}" -maxdepth 5 -name "${SERVER_EXE}" -type f 2>/dev/null | head -n1)"
    if [ -z "${hit}" ]; then
        return 1
    fi

    SERVER_EXE_DIR="$(dirname "${hit}")"                       # .../Binaries/Win64
    GAME_ROOT="$(dirname "$(dirname "${SERVER_EXE_DIR}")")"     # .../ShooterGame
    SAVED_DIR="${GAME_ROOT}/Saved"
    CONFIG_DIR="${SAVED_DIR}/Config/WindowsServer"
    return 0
}

install_steamcmd

if ! resolve_proton; then
    exit 1
fi

proton_debug_env

# Proton expects to be told which game it is running. Without SteamGameId it
# silently disables its own logging entirely (setup_logging returns early), and
# protonfixes decides it is running under a unit test and skips every fix. Both
# were happening here, which is why DEBUG=true produced no log at all.
export SteamAppId="${GAME_ID}"
export SteamGameId="${GAME_ID}"
export STEAM_COMPAT_APP_ID="${GAME_ID}"

setup_proton_prefix

# -----------------------------------------------------------------------------
# Game files
# -----------------------------------------------------------------------------
echo "---Checking for ARK: Survival Ascended updates---"

update_game

if ! locate_game_dirs; then
    echo "---${SERVER_EXE} is missing after the SteamCMD run (exit ${STEAM_RC})---"
    echo "---The ASA depot is ~13GB, check free space and your appdata path---"
    exit 1
fi
if [ "${STEAM_RC}" -ne 0 ]; then
    echo "---SteamCMD exited ${STEAM_RC}, continuing with the files already on disk---"
fi

link_steam_sdk

echo "---Config directory: ${CONFIG_DIR}---"

# -----------------------------------------------------------------------------
# Config seed. Only written when absent - your edits are never overwritten.
# -----------------------------------------------------------------------------
mkdir -p "${CONFIG_DIR}"
if [ ! -f "${CONFIG_DIR}/GameUserSettings.ini" ]; then
    echo "---Seeding GameUserSettings.ini---"
    cat > "${CONFIG_DIR}/GameUserSettings.ini" <<EOF
[ServerSettings]
RCONEnabled=True
RCONPort=${RCON_PORT}
ServerAdminPassword=${SRV_ADMIN_PWD}
EOF
fi
[ -f "${CONFIG_DIR}/Game.ini" ] || touch "${CONFIG_DIR}/Game.ini"

if ! grep -qi "RCONEnabled=True" "${CONFIG_DIR}/GameUserSettings.ini"; then
    echo "---Note: RCON looks disabled in GameUserSettings.ini---"
    echo "---Without it this container can only hard-stop the server, which risks save loss---"
fi

# A short path to the configs, so the SMB share reads
# .../ark-sa/config/GameUserSettings.ini rather than the full nested path.
if [ ! -e "${SERVER_DIR}/config" ]; then
    ln -sfn "${CONFIG_DIR}" "${SERVER_DIR}/config" 2>/dev/null || true
fi

if [ "${FIX_PERMS,,}" = "true" ]; then
    resolve_config_modes
    echo "---Applying umask ${CONFIG_UMASK_EFFECTIVE} to ${SAVED_DIR} (files ${CONFIG_FILE_MODE}, dirs ${CONFIG_DIR_MODE})---"
fi
fix_share_perms

# -----------------------------------------------------------------------------
# Launch arguments
#
# ASA moved the important knobs off the ?-string and onto - flags. ?MaxPlayers=
# and ?Port= are silently ignored; -WinLiveMaxPlayers= and -port= are the real
# ones. ServerAdminPassword must be the LAST ? argument or the parser swallows
# whatever follows into the password value.
# -----------------------------------------------------------------------------
QUERY="${MAP}?listen"
[ -n "${SERVER_NAME}" ]        && QUERY+="?SessionName=${SERVER_NAME}"
[ -n "${QUERY_PARAMS_EXTRA}" ] && QUERY+="?${QUERY_PARAMS_EXTRA#\?}"
[ -n "${SRV_PWD}" ]            && QUERY+="?ServerPassword=${SRV_PWD}"
[ -n "${SRV_ADMIN_PWD}" ]      && QUERY+="?ServerAdminPassword=${SRV_ADMIN_PWD}"

FLAGS=( "-port=${GAME_PORT}" "-WinLiveMaxPlayers=${MAX_PLAYERS}" )
[ -n "${QUERY_PORT}" ] && FLAGS+=( "-QueryPort=${QUERY_PORT}" )
[ -n "${MODS}" ]       && FLAGS+=( "-mods=${MODS}" )
[ "${BATTLEYE,,}" = "false" ] && FLAGS+=( "-NoBattlEye" )
[ "${CROSSPLAY,,}" = "true" ] && FLAGS+=( "-crossplay" )
if [ -n "${CLUSTER_ID}" ]; then
    mkdir -p "${CLUSTER_DIR}"
    FLAGS+=( "-clusterid=${CLUSTER_ID}" "-ClusterDirOverride=${CLUSTER_DIR}" )
fi
if [ -n "${GAME_PARAMS_EXTRA}" ]; then
    read -ra EXTRA_ARR <<< "${GAME_PARAMS_EXTRA}"
    FLAGS+=( "${EXTRA_ARR[@]}" )
fi

# -----------------------------------------------------------------------------
# Shutdown handling. ARK writes its world on exit, so a plain SIGKILL is how
# people lose hours of progress. Ask nicely over RCON first.
# -----------------------------------------------------------------------------
stop_log_tail() {
    if [ -n "${LOG_TAIL_PID}" ]; then
        kill "${LOG_TAIL_PID}" 2>/dev/null || true
        LOG_TAIL_PID=""
    fi
    if [ -n "${WATCHDOG_PID}" ]; then
        kill "${WATCHDOG_PID}" 2>/dev/null || true
        WATCHDOG_PID=""
    fi
}

graceful_shutdown() {
    [ "${SHUTTING_DOWN}" = "true" ] && return
    SHUTTING_DOWN="true"
    echo "---Shutdown requested---"

    if [ -n "${SRV_ADMIN_PWD}" ] && grep -qi "RCONEnabled=True" "${CONFIG_DIR}/GameUserSettings.ini" 2>/dev/null; then
        echo "---Saving world via RCON---"
        python3 /opt/scripts/rcon.py 127.0.0.1 "${RCON_PORT}" "${SRV_ADMIN_PWD}" "SaveWorld" || \
            echo "---RCON save failed, the server may already be down---"
        sleep 5
        echo "---Sending DoExit---"
        python3 /opt/scripts/rcon.py 127.0.0.1 "${RCON_PORT}" "${SRV_ADMIN_PWD}" "DoExit" >/dev/null 2>&1 || true
    else
        echo "---No RCON available, stopping the process directly---"
    fi

    # Say something while waiting. A silent gap of up to STOP_TIMEOUT seconds
    # reads as a hang, and this is exactly when someone is deciding whether to
    # pull the plug on a server that is mid-save.
    local waited=0
    while kill -0 "${SERVER_PID}" 2>/dev/null && [ "${waited}" -lt "${STOP_TIMEOUT}" ]; do
        sleep 2
        waited=$((waited + 2))
        if [ $((waited % 10)) -eq 0 ]; then
            echo "---Waiting for the server to exit (${waited}s of ${STOP_TIMEOUT}s)---"
        fi
    done

    if kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "---Still running after ${STOP_TIMEOUT}s, killing the wine prefix---"
        echo "---The world was already saved above, so this is not data loss---"
        wineserver_kill
        sleep 5
        kill -9 "${SERVER_PID}" 2>/dev/null || true
    fi

    # The server just rewrote its saves and configs on the way out; make sure
    # those new files are editable over the share too.
    fix_share_perms

    stop_log_tail
    echo "---Server stopped---"
    exit 0
}

trap graceful_shutdown SIGTERM SIGINT SIGQUIT

# -----------------------------------------------------------------------------
# Go
# -----------------------------------------------------------------------------
cd "${SERVER_EXE_DIR}" || exit 1

echo "---Starting ${MAP} on port ${GAME_PORT}, cap ${MAX_PLAYERS}---"
echo "---Launch line: ${SERVER_EXE} <query string hidden> ${FLAGS[*]}---"
echo "---First boot builds the Proton prefix and can sit quiet for several minutes---"

# Mirror the engine log into the container log, so the Unraid "Logs" button and
# `docker logs` show what the server is actually doing instead of only this
# script's own messages. ARK replaces ShooterGame.log on each start rather than
# appending, and `tail -F` follows by name: starting at -n 0 skips the previous
# run's contents, then it reopens the new file and reads it from the beginning.
ENGINE_LOG="${SAVED_DIR}/Logs/ShooterGame.log"
mkdir -p "$(dirname "${ENGINE_LOG}")" 2>/dev/null || true
tail -F -n 0 "${ENGINE_LOG}" 2>/dev/null &
LOG_TAIL_PID=$!

# A wrong Proton build hangs ASA before it writes any engine log at all: no
# crash, no error, the container just sits there looking healthy. That is far
# harder to diagnose than a crash, so call it out rather than let someone wait.
(
    sleep "${STARTUP_WARN_SECS:-300}"
    if [ ! -s "${ENGINE_LOG}" ]; then
        echo "---No engine output yet. The server may be hung rather than slow.---"
        echo "---A Proton build ASA does not tolerate fails exactly like this,---"
        echo "---silently and before any log is written. Currently running:---"
        echo "---  ${PROTON_RESOLVED} (tested: ${PROTON_TESTED:-unknown})---"
        echo "---If those differ, set PROTON_VERSION=${PROTON_TESTED:-GE-Proton10-34} and restart.---"
    fi
) &
WATCHDOG_PID=$!

"${PROTON_BIN}" run "./${SERVER_EXE}" "${QUERY}" "${FLAGS[@]}" &
SERVER_PID=$!

wait "${SERVER_PID}"
EXIT_CODE=$?

stop_log_tail

if [ "${SHUTTING_DOWN}" = "false" ]; then
    echo "---Server exited on its own with code ${EXIT_CODE}---"
    # A server that dies before writing an engine log failed in Proton or in
    # loading the binary, not in ARK itself. Saying which narrows it a lot.
    if [ ! -s "${SAVED_DIR}/Logs/ShooterGame.log" ]; then
        echo "---No engine log was written, so it failed before ARK started.---"
        echo "---Set DEBUG=true and restart to capture wine and Proton output.---"
    fi
    fix_share_perms
fi
exit "${EXIT_CODE}"
