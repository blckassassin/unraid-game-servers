#!/bin/bash
# RuneScape: Dragonwilds dedicated server runner.
#
# This is the first game here that is both SteamCMD-installed AND a native Linux
# binary, so it sits between the two existing shapes: it sources steamcmd.sh like
# ASA and V Rising, and sources no proton.sh at all like Terraria. Four things
# follow from that and drive everything below.
#
# 1. The Linux depot, not the Windows one. shared/scripts/steamcmd.sh defaults to
#    windows for the two Proton games; the Dockerfile sets STEAM_DEPOT_PLATFORM=linux.
# 2. The binary is launched directly, not through RSDragonwildsServer.sh. That
#    wrapper does not exec - it runs the ELF as a child - so signalling it would
#    leave the game running, which is the whole trap the V Rising runner needed
#    /proc/<pid>/comm to work around. Skipping it makes $! the server itself.
# 3. DedicatedServer.ini is edited key by key rather than seeded or regenerated.
#    The server writes into that file itself, and there is no command-line
#    override for any of its settings. See set_ini_key below.
# 4. An empty OwnerId is checked for explicitly, because the server's own
#    response to one is to keep running and serve nobody.
# 5. GAME_PORT is fixed at the exposed port on a bridge network and is not a
#    template field. Unraid freezes the container port, so the server has to bind
#    it. See check_game_port below.

set -u
umask "${UMASK:-000}"

# shellcheck source=/dev/null
source /opt/scripts/steamcmd.sh

# Launch the ELF, not the wrapper. RSDragonwildsServer.sh is four lines: it
# resolves its own directory, chmod +x's this binary and runs it with the project
# name as the first argument, WITHOUT exec. That missing exec is the reason to
# bypass it - see the header - and the chmod is reproduced below.
SERVER_BIN="${SERVER_DIR}/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping"
# What SteamCMD's own launch entry passes as argv[1]; the engine needs it to
# resolve the project.
PROJECT="RSDragonwilds"
SAVED_DIR="${SERVER_DIR}/RSDragonwilds/Saved"
CONFIG_DIR="${SAVED_DIR}/Config/LinuxServer"
INI="${CONFIG_DIR}/DedicatedServer.ini"
# SaveGames, with a capital G. The game's wiki writes it "Savegames", which is
# wrong - verified against a real run, where the save landed at
# Saved/SaveGames/<DefaultWorldName>.sav. A case-mismatched path would be created
# as a second, empty directory next to the real one and nobody would notice.
SAVE_DIR="${SAVED_DIR}/SaveGames"
# The literal section header the server writes, verified against a real first
# run. Not a guess: the file it generates is
#   ;METADATA=(Diff=true, UseCommands=true)
#   [/Script/Dominion.DedicatedServerSettings]
#   AdminPassword=...
INI_SECTION="/Script/Dominion.DedicatedServerSettings"
# What this image's Dockerfile EXPOSEs. Not the same thing as GAME_PORT, which is
# what the server is told to bind - see check_game_port below for why the two
# being different is worth saying out loud. A unit test asserts this tracks the
# EXPOSE line.
EXPOSED_PORT="7777"

SERVER_PID=""
SHUTTING_DOWN="false"

# -----------------------------------------------------------------------------
# Config.
#
# Dragonwilds has no launch flag for any of its settings - unlike V Rising, where
# every field has a flag that beats the file, which is what lets that container
# never write config at all. The ini is the only channel here, so the template's
# fields have to reach it by editing the file.
#
# But the server also writes this file itself. On a first run with no ini at all
# it generates and persists a ServerGuid, and fills in any of ServerName,
# AdminPassword and DefaultWorldName that are missing:
#
#   LogDomServerSettings: Generated missing DefaultWorldName: World-35188
#   LogDomServerSettings: Generated missing AdminPassword: YXPHC6S6YR8JW8KA
#   LogDomServerSettings: Generated missing ServerName: Server-44208
#   LogDomServerSettings: Generated missing ServerGuid: CE0871C643CA4D38A7F89D83DAB8C6B1
#
# So neither of the other two patterns in this repo fits. ASA's write-once seed
# would make every template field silently dead after first boot. Terraria's
# regenerate-every-boot would destroy the ServerGuid, which identifies the server
# to returning players. What is left is to rewrite only the keys the template
# owns and leave every other line exactly as it was - including ServerGuid,
# including the ;METADATA comment, including anything a future build adds.
#
# The documented consequence: a hand edit to one of the five managed keys is
# overwritten on the next start, because the Unraid field is the source of truth
# for those. Everything else in the file is the operator's.
# -----------------------------------------------------------------------------

# set_ini_key <file> <section> <key> <value>
#
# Replaces the key's value inside the named section, appends the key to that
# section if it is absent, or creates the section and the key if neither exists.
# Every other byte of the file is passed through untouched.
#
# The value is never interpreted as a regex or a replacement string - awk builds
# the output line by concatenation - so a password containing &, \ or / is safe.
# `sed s|...|...|` here would not be, which is why this is awk.
#
# The value arrives through the environment rather than through `awk -v`, which is
# not a style choice: `-v` runs escape processing over the assignment, so
# `-v value='a\fun'` hands awk a formfeed and silently drops two characters. An
# admin password is exactly the sort of value that contains a backslash. ENVIRON
# does no such processing. The key and section are fixed identifiers from this
# file, so they stay on -v.
set_ini_key() {
    local file="$1" section="$2" key="$3" value="$4"
    local tmp="${file}.tmp.$$"

    [ -f "${file}" ] || : > "${file}"

    if ! DW_INI_VALUE="${value}" awk -v section="${section}" -v key="${key}" '
    BEGIN { value = ENVIRON["DW_INI_VALUE"] }
    {
        lines[NR] = $0
        # A section header. Track whether we are inside the one we want, and
        # where it ends, so a missing key can be appended in the right place
        # rather than at the bottom of the file under someone else section.
        if ($0 ~ /^[[:space:]]*\[.*\][[:space:]]*$/) {
            s = $0
            sub(/^[[:space:]]*\[/, "", s)
            sub(/\][[:space:]]*$/, "", s)
            if (s == section) { seen = 1; inside = 1 }
            else {
                if (inside && !section_end) { section_end = last_content ? last_content : NR - 1 }
                inside = 0
            }
            next
        }
        # Remember the last line in our section that actually holds something, so
        # an appended key lands against the other keys rather than after the blank
        # line that separates this section from the next.
        if (inside && $0 !~ /^[[:space:]]*$/) { last_content = NR }
        if (inside && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=")) {
            lines[NR] = key "=" value
            done = 1
        }
    }
    END {
        # The section we want is the last one in the file, so it ends at EOF.
        if (!done && seen && !section_end) { section_end = last_content ? last_content : NR }
        for (i = 1; i <= NR; i++) {
            print lines[i]
            if (!done && seen && i == section_end) { print key "=" value }
        }
        if (!done && !seen) {
            if (NR > 0) { print "" }
            print "[" section "]"
            print key "=" value
        }
    }
    ' "${file}" > "${tmp}"; then
        echo "---Could not rewrite ${key} in $(basename "${file}")---"
        rm -f "${tmp}"
        return 1
    fi

    mv -f "${tmp}" "${file}"
}

write_config() {
    mkdir -p "${CONFIG_DIR}"

    if [ ! -f "${INI}" ]; then
        echo "---No DedicatedServer.ini yet, creating one---"
    else
        echo "---Applying the template's settings to DedicatedServer.ini---"
    fi

    # Only these five. WorldPassword and AdminPassword are written even when
    # blank, because blank is a meaningful value for both - an open world, and
    # letting the server generate an admin password of its own - and leaving a
    # previous run's value in place would silently ignore the field being
    # cleared.
    set_ini_key "${INI}" "${INI_SECTION}" OwnerId "${OWNER_ID}" || return 1
    set_ini_key "${INI}" "${INI_SECTION}" ServerName "${SERVER_NAME}" || return 1
    set_ini_key "${INI}" "${INI_SECTION}" DefaultWorldName "${WORLD_NAME}" || return 1
    set_ini_key "${INI}" "${INI_SECTION}" AdminPassword "${SRV_ADMIN_PWD}" || return 1
    set_ini_key "${INI}" "${INI_SECTION}" WorldPassword "${SRV_PWD}" || return 1
}

# -----------------------------------------------------------------------------
# OwnerId. Mandatory, unguessable by this container, and the failure mode without
# a check here is the worst kind: the server does NOT exit. Measured on a real
# boot with the key empty - it prints
#
#   The [OwnerId] for this server is empty.
#   An OwnerId is required for normal Server operation.
#   Update the config and restart to continue
#
# and then carries on initialising, binds 7777/udp and sits there. Docker reports
# a healthy container, Unraid shows it running, and it serves nobody. Refusing to
# start is strictly better than that, and the message is the whole fix.
#
# This runs AFTER the SteamCMD install on purpose: the 5GB download gets on with
# itself while the operator goes to find their ID, and the error is then the last
# thing in the log instead of buried above an install.
# -----------------------------------------------------------------------------
check_owner_id() {
    if [ -n "${OWNER_ID}" ]; then
        return 0
    fi
    echo "---OWNER_ID is empty, and the server will not run properly without it---"
    echo "---It is your in-game Player ID: open RuneScape: Dragonwilds, go to---"
    echo "---Settings, and it is at the bottom of the menu with a copy button---"
    echo "---next to it. Paste it into this container's Owner ID field.---"
    echo "---"
    echo "---Refusing to start rather than running a server nobody can use: with---"
    echo "---this empty the server does start and bind its port, so it would look---"
    echo "---healthy while refusing every player.---"
    return 1
}

# -----------------------------------------------------------------------------
# GAME_PORT, and why it is not a knob on a bridge network.
#
# Unraid renders a template's Type="Port" entry with the container port as a
# read-only line - it is not a field until you click Edit on that row, and on
# some installs not even then. So the container port is, in practice, frozen at
# whatever the template ships: 7777.
#
# That single fact decides the design. If the container port cannot move, the
# server must bind 7777, because the port mapping forwards there and nowhere
# else. A user who changes the port changes the HOST side of the mapping; the
# inside of the container stays 7777 forever. Two numbers, not three.
#
# It used to be three, and the third was this variable. The template exposed it
# as "Server Port" next to a "Game Port" mapping row, which is the same words
# twice, and changing the port the obvious way set both visible fields to 7780
# while the container port stayed 7777. Observed on a live server:
#
#   docker inspect  {"7777/udp": [{"HostPort": "7780"}]}
#   /proc/net/udp   listening on 7780, nothing on 7777
#
# Docker forwarded host:7780 to a container port the server never bound. The
# server started, the log was clean, the container was healthy and green, and no
# player could reach it. An external probe got ICMP port-unreachable from the
# container, which reads as "not forwarded" and sends the operator hunting their
# router. There was no error anywhere.
#
# So GAME_PORT is no longer a template field. It survives as an environment
# variable for exactly one case: host networking, where there is no mapping and
# no container port, and the bind port is genuinely the only number there is.
#
# Which is what this check says. It cannot detect the network mode - a container
# on a bridge and a container on the host see the same thing from in here - so it
# states the condition and lets the operator match it against what they set.
# -----------------------------------------------------------------------------
check_game_port() {
    [ "${GAME_PORT}" = "${EXPOSED_PORT}" ] && return 0

    echo "---GAME_PORT is ${GAME_PORT}, but this image exposes ${EXPOSED_PORT}.---"
    echo "---That is correct ONLY under host networking, where there is no port---"
    echo "---mapping and this is the only port number involved.---"
    echo "---"
    echo "---On a bridge network it is wrong. The mapping forwards to ${EXPOSED_PORT} inside---"
    echo "---this container, so nothing will reach a server bound to ${GAME_PORT} - and it---"
    echo "---will still look perfectly healthy. Leave GAME_PORT at ${EXPOSED_PORT} and change---"
    echo "---the host side of the mapping instead; that is the port players use.---"
    return 0
}

# -----------------------------------------------------------------------------
# Shutdown. It does NOT save, and nothing here can make it.
#
# Measured 2026-09-14 over a 20 minute run. Two facts:
#
#   1. The server autosaves every 300 seconds, exactly, whether or not anyone is
#      connected. Saves landed at +300s, +600s, +900s and +1200s, each 300s apart
#      to the second.
#   2. Neither SIGINT nor SIGTERM saves. The engine performs a full orderly
#      teardown - every module's ShutdownModule, "LogExit: Game engine shut down",
#      then RequestExit(bForce=false) - and exits in about two seconds with the
#      save file byte-identical, same mtime and same size.
#
# The two signals are otherwise indistinguishable: their shutdown sequences diff
# clean apart from the return code, 130 against 143. SIGINT is used because the
# game's wiki stops a server with Ctrl+C, and nothing depends on the choice.
#
# Why no save: the game HAS a save-on-exit path, UDominionNetworkSubsystem::
# RequestGameExit, a staged sequence whose second stage logs "RequestGameExit :
# Server saving World and Player state". But it is Blueprint-exposed
# (execRequestGameExit) and driven from the game's own UI - it is the in-game quit
# flow. A POSIX signal never reaches it; a signal lands on Unreal's
# FUnixPlatformMisc::RequestExit, which is a different function entirely and does
# not touch the persistence layer. There is no RCON, no stdin console (probed
# directly: help, Save, SaveGame, SaveWorld, quit and three others were all
# ignored) and no save command, so there is no lever to pull. This is the game's
# design, not a gap in this runner.
#
# The practical consequence, which the README states plainly: a stop costs
# whatever happened since the last autosave, so at most five minutes. Players who
# quit out through the game menu before the stop lose nothing.
#
# STOP_TIMEOUT therefore is not a save window - it is headroom for the engine
# teardown, measured at about 2s and defaulting to 30. Do not inflate it on the
# theory that a longer wait protects a save; there is no save to protect.
#
# SERVER_PID is the game itself, not a wrapper, because the launch below runs the
# ELF directly. That is the one simplification this runner gets over V Rising's:
# no /proc/<pid>/comm matching, no 15-character comm truncation, no risk of
# signalling a shell and orphaning the server.
# -----------------------------------------------------------------------------
graceful_shutdown() {
    [ "${SHUTTING_DOWN}" = "true" ] && return
    SHUTTING_DOWN="true"
    echo "---Shutdown requested, telling the server to save and exit---"

    if [ -z "${SERVER_PID}" ] || ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "---The server is not running, nothing to stop---"
        exit 0
    fi

    # INT, not TERM. See the note above.
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
        echo "---Anything since the last autosave is lost. Raise STOP_TIMEOUT, and---"
        echo "---raise this container's own stop timeout to match, if this repeats.---"
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

echo "---Checking for RuneScape: Dragonwilds updates---"
update_game

if [ ! -f "${SERVER_BIN}" ]; then
    echo "---The server binary is missing after the SteamCMD run (exit ${STEAM_RC})---"
    echo "---Expected it at ${SERVER_BIN}---"
    echo "---The Linux depot is about 5GB installed; check free space and your---"
    echo "---appdata path. If STEAM_DEPOT_PLATFORM is not 'linux', SteamCMD installed---"
    echo "---the Windows depot instead, which has no binary this image can run.---"
    exit 1
fi
if [ "${STEAM_RC}" -ne 0 ]; then
    echo "---SteamCMD exited ${STEAM_RC}, continuing with the files already on disk---"
fi

# The shipped wrapper chmod +x's this on every run, which says the depot does not
# reliably carry the bit. Do the same rather than trusting it.
chmod +x "${SERVER_BIN}" 2>/dev/null || true

write_config || exit 1
check_owner_id || exit 1
check_game_port

mkdir -p "${SAVE_DIR}"

echo "---Starting RuneScape: Dragonwilds '${SERVER_NAME}' on port ${GAME_PORT}/udp---"
echo "---World '${WORLD_NAME}', saves under ${SAVE_DIR}---"
echo "---First boot generates a world, which takes a few minutes---"

EXTRA=()
if [ -n "${GAME_PARAMS_EXTRA}" ]; then
    read -ra EXTRA <<< "${GAME_PARAMS_EXTRA}"
fi

cd "${SERVER_DIR}" || exit 1
# -log puts the engine log on stdout, which is why this runner needs no log tail
# of its own - contrast ASA, which tails an engine log file, and Terraria, which
# needs a file plus a collapsing filter. Dragonwilds writes a few thousand lines
# during startup and then goes quiet, well inside what a log driver keeps up with.
#
# -NewConsole, which the wiki's launch line carries, is deliberately not passed:
# it is a Windows console flag and does nothing on Linux.
"${SERVER_BIN}" "${PROJECT}" -log "-Port=${GAME_PORT}" ${EXTRA+"${EXTRA[@]}"} &
SERVER_PID=$!

wait "${SERVER_PID}"
EXIT_CODE=$?

if [ "${SHUTTING_DOWN}" = "false" ]; then
    echo "---Server exited on its own with code ${EXIT_CODE}---"
    if [ "${EXIT_CODE}" -eq 134 ]; then
        echo "---Exit 134 is an abort. If the log says 'Refusing to run with the---"
        echo "---root privileges', the container is running as root: set UID and---"
        echo "---GID to a non-zero user (99 and 100 on Unraid).---"
    fi
fi
exit "${EXIT_CODE}"
