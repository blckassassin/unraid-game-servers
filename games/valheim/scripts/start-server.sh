#!/bin/bash
# Valheim dedicated server runner.
#
# The simplest runner in this repo, and deliberately so. Valheim has no config
# file of any kind: every setting is a launch flag, and -savedir relocates the
# entire persistent state - worlds_local/ plus adminlist.txt, bannedlist.txt and
# permittedlist.txt - into one directory on the mounted volume. So there is no
# seeding, no regeneration and no key-by-key ini rewriting here. Nothing in this
# container ever writes the server's configuration, because there is none to
# write.
#
# What is NOT simple is stopping it. Five things drive the rest of this file.
#
# 1. The Linux depot, not the Windows one. shared/scripts/steamcmd.sh defaults to
#    windows for the two Proton games; the Dockerfile sets
#    STEAM_DEPOT_PLATFORM=linux.
# 2. SIGINT, because that is the documented way to stop this server and the
#    shutdown save is the only save this container can ask for. See
#    graceful_shutdown for what was measured and why SIGTERM is not used even
#    though it now works.
# 3. The binary is launched directly, not through the shipped start_server.sh.
#    That wrapper does not exec: its last line restores LD_LIBRARY_PATH, which
#    can only run after the server has exited. Signalling it would leave the
#    game running. Launching the ELF makes $! the server itself.
# 4. SteamAppId is 892970 - the CLIENT app id - even though SteamCMD installs
#    896660. The shipped start_server.sh exports exactly that, and the server
#    will not start without it.
# 5. The password rules are enforced by the server with an exit, not a warning,
#    and one of the three rules surprises everybody. See check_password.

set -u
umask "${UMASK:-000}"

# shellcheck source=/dev/null
source /opt/scripts/steamcmd.sh

SERVER_BIN="${SERVER_DIR}/valheim_server.x86_64"
# -savedir takes the whole persistent tree with it, so this one directory holds
# worlds_local/, the three permission files and the server's own backups.
SAVE_DIR="${SERVER_DIR}/savedir"
# The client app id, not GAME_ID. See the header.
STEAM_APP_ID="892970"

SERVER_PID=""
SHUTTING_DOWN="false"
FLAGS=()

# -----------------------------------------------------------------------------
# Password. Three rules, all enforced by the server by refusing to start, and
# all worth catching here because the server's own complaint is one terse line
# in among its startup noise.
#
#   1. -public 1 requires a password. There is no such thing as a listed server
#      anyone can walk into; a passwordless server must be -public 0.
#   2. Minimum five characters.
#   3. The password must not appear anywhere inside the server name. This is the
#      one nobody expects: naming a server "Jordan's Valheim" and setting the
#      password to "valheim" fails, and the reason is not obvious from the
#      message. It is stated in the comment block of the shipped start_server.sh:
#        # NOTE: Minimum password length is 5 characters & Password cant be in
#        # the server name.
#
# Rule 3's case sensitivity is not documented anywhere, so the refusal below is
# case-SENSITIVE - the reading that cannot reject a configuration the server
# would have accepted - and a case-insensitive match downgrades to a warning
# instead. Being too strict here would block a working server on a guess.
# -----------------------------------------------------------------------------
check_password() {
    if [ -z "${SRV_PWD}" ]; then
        if [ "${PUBLIC}" = "1" ]; then
            echo "---PUBLIC is 1 and no password is set, and the server will not start that way---"
            echo "---Valheim requires a password on any server listed in the browser. Either---"
            echo "---set Server Password, or set Public to 0 for an unlisted server that---"
            echo "---players reach with the Join IP button.---"
            return 1
        fi
        echo "---No password set. This server is unlisted (PUBLIC=0) and anyone who---"
        echo "---can reach the port can join.---"
        return 0
    fi

    if [ "${#SRV_PWD}" -lt 5 ]; then
        echo "---The password is ${#SRV_PWD} characters and the server requires at least 5---"
        echo "---It refuses to start with a shorter one, so this container stops here---"
        echo "---rather than leaving you to find that in the log.---"
        return 1
    fi

    if [[ "${SERVER_NAME}" == *"${SRV_PWD}"* ]]; then
        echo "---The password appears inside the server name, which the server refuses---"
        echo "---to start with. Server name: '${SERVER_NAME}'---"
        echo "---Change one of the two so the password is not part of the name.---"
        return 1
    fi

    # Same test ignoring case. Not fatal, because nothing documents whether the
    # server's own check is case sensitive, and refusing on a guess would block
    # a configuration that may well be fine.
    local name_lc="${SERVER_NAME,,}" pwd_lc="${SRV_PWD,,}"
    if [[ "${name_lc}" == *"${pwd_lc}"* ]]; then
        echo "---Note: the password appears inside the server name if you ignore case.---"
        echo "---The server's own rule may or may not be case sensitive. If it refuses---"
        echo "---to start, this is the first thing to change.---"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# World modifiers, the system that arrived with 1.0.
#
# Three template fields become flags here: PRESET, MODIFIERS as
# "combat=hard,raids=none" and SETKEYS as "nomap,passivemobs". The alternative
# was ten Unraid fields for settings most servers leave alone.
#
# Every name and value is checked against the closed sets from Iron Gate's guide
# and a typo is fatal. That is on purpose: the server ignores a modifier it does
# not recognise, silently, so "combat=veryhrad" would otherwise give you a
# normal-difficulty world and no indication of why.
#
# Each modifier's value list omits its middle value. There is no spelling for
# "normal" - you pass a modifier only to deviate from it.
# -----------------------------------------------------------------------------
PRESET_VALUES="normal casual easy hard hardcore immersive hammer"
SETKEY_VALUES="nobuildcost playerevents passivemobs nomap"

modifier_values() {
    case "$1" in
        combat)       echo "veryeasy easy hard veryhard" ;;
        deathpenalty) echo "casual veryeasy easy hard hardcore" ;;
        resources)    echo "muchless less more muchmore most" ;;
        raids)        echo "none muchless less more muchmore" ;;
        portals)      echo "casual hard veryhard" ;;
        *)            return 1 ;;
    esac
}

# in_list <needle> <space separated haystack>
#
# The loop word-splits on IFS, so callers must not have IFS set to something
# else when they get here. Splitting the template's comma-separated fields with
# `IFS=',' read` below keeps that true, because that form scopes IFS to the read
# itself. A `local IFS=','` in the caller does not - it stays in force for
# everything the function goes on to call, which collapses this haystack into a
# single token and rejects every valid value.
in_list() {
    local needle="$1" item
    for item in $2; do
        [ "${item}" = "${needle}" ] && return 0
    done
    return 1
}

# Everything is lowercased before comparison and passed on lowercased, which is
# the spelling Iron Gate's own examples use (-preset hard, -modifier raids none).
build_modifier_flags() {
    local entry name value

    if [ -n "${PRESET}" ]; then
        local preset="${PRESET,,}"
        if ! in_list "${preset}" "${PRESET_VALUES}"; then
            echo "---'${PRESET}' is not a world preset. Valid: ${PRESET_VALUES}---"
            return 1
        fi
        FLAGS+=( "-preset" "${preset}" )
    fi

    if [ -n "${MODIFIERS}" ]; then
        local entries=()
        IFS=',' read -ra entries <<< "${MODIFIERS}"
        for entry in "${entries[@]}"; do
            entry="${entry// /}"
            [ -z "${entry}" ] && continue
            if [[ "${entry}" != *"="* ]]; then
                echo "---Modifier '${entry}' is not name=value, e.g. combat=hard---"
                return 1
            fi
            name="${entry%%=*}"
            value="${entry#*=}"
            name="${name,,}"
            value="${value,,}"
            local valid
            if ! valid="$(modifier_values "${name}")"; then
                echo "---'${name}' is not a world modifier---"
                echo "---Valid: combat, deathpenalty, resources, raids, portals---"
                return 1
            fi
            if ! in_list "${value}" "${valid}"; then
                echo "---'${value}' is not a value for ${name}. Valid: ${valid}---"
                return 1
            fi
            FLAGS+=( "-modifier" "${name}" "${value}" )
        done
    fi

    if [ -n "${SETKEYS}" ]; then
        local keys=()
        IFS=',' read -ra keys <<< "${SETKEYS}"
        for entry in "${keys[@]}"; do
            entry="${entry// /}"
            [ -z "${entry}" ] && continue
            entry="${entry,,}"
            if ! in_list "${entry}" "${SETKEY_VALUES}"; then
                echo "---'${entry}' is not a world toggle. Valid: ${SETKEY_VALUES}---"
                return 1
            fi
            FLAGS+=( "-setkey" "${entry}" )
        done
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Launch flags.
#
# Order is not free. -preset resets every slider it covers, so the server parses
# left to right and a -modifier placed before a -preset is silently overwritten.
# build_modifier_flags emits preset, then modifiers, then setkeys, and it is
# called in that position here, so a user cannot get the ordering wrong.
#
# An empty value is omitted rather than passed blank, which for -password is the
# difference between "no password" and a zero-length one.
# -----------------------------------------------------------------------------
build_flags() {
    FLAGS=( "-nographics" "-batchmode" )
    FLAGS+=( "-name" "${SERVER_NAME}" )
    FLAGS+=( "-port" "${GAME_PORT}" )
    FLAGS+=( "-world" "${WORLD_NAME}" )
    FLAGS+=( "-public" "${PUBLIC}" )
    FLAGS+=( "-savedir" "${SAVE_DIR}" )

    [ -n "${SRV_PWD}" ] && FLAGS+=( "-password" "${SRV_PWD}" )
    [ "${CROSSPLAY,,}" = "true" ] && FLAGS+=( "-crossplay" )

    [ -n "${SAVE_INTERVAL}" ] && FLAGS+=( "-saveinterval" "${SAVE_INTERVAL}" )
    [ -n "${BACKUP_COUNT}" ]  && FLAGS+=( "-backups" "${BACKUP_COUNT}" )
    [ -n "${BACKUP_SHORT}" ]  && FLAGS+=( "-backupshort" "${BACKUP_SHORT}" )
    [ -n "${BACKUP_LONG}" ]   && FLAGS+=( "-backuplong" "${BACKUP_LONG}" )

    build_modifier_flags || return 1

    if [ -n "${GAME_PARAMS_EXTRA}" ]; then
        local extra
        read -ra extra <<< "${GAME_PARAMS_EXTRA}"
        FLAGS+=( "${extra[@]}" )
    fi
    return 0
}

# -----------------------------------------------------------------------------
# The save directory has to be writable, and that is worth proving rather than
# assuming, because the server's own response to a read-only one is not to stop.
# It logs an UnauthorizedAccessException, carries on, and serves a world out of
# memory that it can never write. The container looks healthy, players join, and
# everything built is gone at the next restart - a whole evening of play, with no
# error anywhere except one line during startup.
#
# start.sh's ownership pass covers the ordinary case. This catches what it
# cannot: a read-only bind mount, a host path exported with squashed
# permissions, or a UID field that does not match who owns the files.
#
# Refusing is strictly better than running something that looks fine and saves
# nothing - the same call the config guards above make.
# -----------------------------------------------------------------------------
check_save_dir_writable() {
    local probe="${SAVE_DIR}/.write-probe.$$"
    # The redirect runs inside a subshell so that a failure is reported by that
    # subshell's stderr, which is discarded. Written as a bare `: > "${probe}"
    # 2>/dev/null` the shell reports the failed redirection on ITS own stderr
    # before the command ever runs, so the 2>/dev/null misses it and a raw
    # "Permission denied" lands immediately above the explanation below.
    if ! ( : > "${probe}" ) 2>/dev/null; then
        echo "---${SAVE_DIR} is not writable as $(id -un) ($(id -u):$(id -g))---"
        echo "---Refusing to start. The server itself would NOT stop here: it logs---"
        echo "---one permission error, keeps running, and serves a world it can---"
        echo "---never save, so it would look perfectly healthy while losing---"
        echo "---everything your players build.---"
        echo "---Check the UID and GID fields against who owns the game files path---"
        echo "---on the host, and that the mount is not read-only.---"
        return 1
    fi
    rm -f "${probe}"
    return 0
}

# -----------------------------------------------------------------------------
# worlds_local, not worlds.
#
# The dedicated server reads worlds_local/ and has done since 0.148. It does not
# look in worlds/ at all. Drop a world into the wrong one and the server does
# not complain - it generates a brand new world, boots happily, and reports
# nothing unusual. That is the single most common "my world disappeared" story,
# and it is worth a line in the log rather than a support thread.
#
# A warning, not a refusal: a leftover worlds/ directory beside a perfectly good
# worlds_local/ is harmless, and stopping a working server over it would be a
# worse trade.
# -----------------------------------------------------------------------------
check_world_dir() {
    local legacy="${SAVE_DIR}/worlds"
    [ -d "${legacy}" ] || return 0
    # Anything that looks like a world, in either the pre-1.0 flat-file shape or
    # the 1.0 directory shape.
    if ! find "${legacy}" -mindepth 1 -maxdepth 1 \
         \( -name '*.db' -o -name '*.fwl' -o -type d \) -print -quit 2>/dev/null | grep -q .; then
        return 0
    fi
    echo "---There is something that looks like a world in ${legacy}---"
    echo "---The dedicated server does NOT read that directory. It reads---"
    echo "---${SAVE_DIR}/worlds_local, and if your world is not there it will---"
    echo "---quietly generate a new one instead of telling you.---"
    echo "---Move the world into worlds_local if this is the world you wanted.---"
}

# -----------------------------------------------------------------------------
# Shutdown. SIGINT, and this is the only save path that exists.
#
# ASA saves over RCON and Terraria writes 'exit' into a FIFO console. Valheim has
# neither: no RCON, no stdin command interface, no remote save of any kind. The
# only way to make this server write its world is the signal below, so if it is
# wrong there is no second mechanism and nothing to fall back on.
#
# SIGINT specifically, and the reason is history rather than a live failure.
#
# Measured 2026-09-22 against Valheim 1.0, buildid 25390671, on a freshly
# generated world:
#
#   SIGINT  saved, world generation advanced 2 -> 3, whole stop took 4.2s
#   SIGTERM saved, world generation advanced 1 -> 2, sent straight to the game
#
# So on this build BOTH signals save, and the widely repeated claim that SIGTERM
# loses the world is out of date. It was true once: Iron Gate's own bug tracker
# carries an entry titled "dedicated server does not save world on SIGTERM", and
# the long-running community container converted TERM to INT because of it and
# still treats TERM as a step on the way to SIGKILL.
#
# This sends INT anyway. It is what Iron Gate's guide documents - stop the server
# with CTRL+C - it is what every established container sends, and it costs
# nothing. Relying on SIGTERM would mean relying on a fix staying fixed, for a
# server whose only save path this is: no RCON, no console, no remote save. When
# one of two signals is documented and both work, take the documented one.
#
# SERVER_PID is the game itself, not a wrapper, because the launch below runs the
# ELF directly. Valheim has no wrapper processes at all - no xvfb-run, no Proton
# launcher - so this needs neither V Rising's /proc/<pid>/comm matching nor the
# process-group signalling the community container uses to cope with its own
# setsid wrapper. (For the record, the comm route would be awkward here anyway:
# "valheim_server.x86_64" is 20 characters and truncates to "valheim_server.")
#
# STOP_TIMEOUT is a real save window. The 4.2s measured above is the floor, not
# the number to set: that was an empty world nobody had played, and the save
# grows with explored terrain and built structures. The default of 120 also has
# to cover the one-way world-format conversion a pre-1.0 save performs on its
# first 1.0 boot, which takes minutes and corrupts the world if it is
# interrupted, and it matches what the community container documents for its own
# --stop-timeout.
# -----------------------------------------------------------------------------
graceful_shutdown() {
    [ "${SHUTTING_DOWN}" = "true" ] && return
    SHUTTING_DOWN="true"
    echo "---Shutdown requested, telling the server to save and exit---"

    if [ -z "${SERVER_PID}" ] || ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "---The server is not running, nothing to stop---"
        exit 0
    fi

    # INT, not TERM. See the note above - TERM exits without saving.
    kill -INT "${SERVER_PID}" 2>/dev/null || true

    local waited=0
    while kill -0 "${SERVER_PID}" 2>/dev/null && [ "${waited}" -lt "${STOP_TIMEOUT}" ]; do
        sleep 2
        waited=$((waited + 2))
        # Say something periodically. A silent gap during a save is when someone
        # decides the container has hung and pulls the plug mid-write.
        if [ $((waited % 10)) -eq 0 ]; then
            echo "---Waiting for the server to save and exit (${waited}s of ${STOP_TIMEOUT}s)---"
        fi
    done

    if kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "---Still running after ${STOP_TIMEOUT}s, killing it---"
        echo "---The world is very likely back at its last autosave. Raise STOP_TIMEOUT,---"
        echo "---and raise this container's own stop timeout to match, if this repeats.---"
        kill -9 "${SERVER_PID}" 2>/dev/null || true
    fi

    # A trapped signal makes the first wait return 128+signum without reaping the
    # child, so this second wait is what collects the real status.
    wait "${SERVER_PID}" 2>/dev/null || true
    echo "---Server stopped---"
    exit 0
}

trap graceful_shutdown SIGTERM SIGINT SIGQUIT

# -----------------------------------------------------------------------------
# Go
# -----------------------------------------------------------------------------
steamcmd_home
install_steamcmd

echo "---Checking for Valheim updates---"
update_game

if [ ! -f "${SERVER_BIN}" ]; then
    echo "---The server binary is missing after the SteamCMD run (exit ${STEAM_RC})---"
    echo "---Expected it at ${SERVER_BIN}---"
    echo "---The Linux depot is about 2GB installed; check free space and your---"
    echo "---appdata path. If STEAM_DEPOT_PLATFORM is not 'linux', SteamCMD installed---"
    echo "---the Windows depot instead, which has no binary this image can run.---"
    exit 1
fi
if [ "${STEAM_RC}" -ne 0 ]; then
    echo "---SteamCMD exited ${STEAM_RC}, continuing with the files already on disk---"
fi

# The depot does not reliably carry the execute bit, and a Steam update can drop
# it again, so this runs on every boot rather than once.
chmod +x "${SERVER_BIN}" 2>/dev/null || true

mkdir -p "${SAVE_DIR}"

check_save_dir_writable || exit 1
check_password || exit 1
build_flags || exit 1
check_world_dir

# -----------------------------------------------------------------------------
# The port rule, stated on every boot.
#
# This is a statement, not a check. Nothing inside a container can read its own
# published port mapping, so the runner cannot tell a correct setup from a broken
# one and must not pretend to: a warning keyed on GAME_PORT differing from the
# image's EXPOSE fires on host 2500 -> container 2500 -> GAME_PORT 2500, which is
# correct. False alarms on the correct configuration are worse than none.
# -----------------------------------------------------------------------------
echo "---Starting Valheim '${SERVER_NAME}' on port ${GAME_PORT}/udp---"
echo "---The host port, the container port and Server Port must all be ${GAME_PORT}.---"
echo "---On Unraid the container port is behind the Edit button on the Game Port row.---"
echo "---Players who add this server in Steam use the QUERY port, $((GAME_PORT + 1)),---"
echo "---not ${GAME_PORT}. That catches nearly everyone once.---"
echo "---World '${WORLD_NAME}', saves under ${SAVE_DIR}/worlds_local---"
if [ "${CROSSPLAY,,}" = "true" ]; then
    echo "---Crossplay is on. This server is listed in the in-game Community---"
    echo "---servers list and NOT in the Steam server browser, which is expected---"
    echo "---and not a fault. In this mode the server does not bind ${GAME_PORT} at all -"
    echo "---PlayFab relays the traffic - so there is nothing to forward.---"
fi
echo "---First boot generates a world, which takes a few minutes---"

cd "${SERVER_DIR}" || exit 1

# The two variables the shipped start_server.sh exports, reproduced here because
# this runner bypasses that script. SteamAppId is the client app id and the
# server will not start without it; LD_LIBRARY_PATH points at the Steam libraries
# the depot ships alongside the binary.
export SteamAppId="${STEAM_APP_ID}"
export LD_LIBRARY_PATH="${SERVER_DIR}/linux64:${LD_LIBRARY_PATH:-}"

"${SERVER_BIN}" "${FLAGS[@]}" &
SERVER_PID=$!

wait "${SERVER_PID}"
EXIT_CODE=$?

if [ "${SHUTTING_DOWN}" = "false" ]; then
    echo "---Server exited on its own with code ${EXIT_CODE}---"
    echo "---If it never got as far as generating a world, check the password rules:---"
    echo "---at least 5 characters, and not a substring of the server name.---"
fi
exit "${EXIT_CODE}"
