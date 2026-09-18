#!/bin/bash
# Plain assertions, no framework. Run: bash tests/unit.sh
set -u
fail=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "ok   - $1"
    else
        echo "FAIL - $1"
        echo "         expected: [$2]"
        echo "         actual:   [$3]"
        fail=1
    fi
}

# --- start.sh directory loop -------------------------------------------------
# The loop must survive STEAMCMD_DIR and PROTON_DIR being unset under `set -u`,
# must not word-split a path containing spaces, and must still emit all four
# directories for ASA so each keeps its own ownership-drift check.

dirs_for() {  # dirs_for <SERVER_DIR> [STEAMCMD_DIR] [PROTON_DIR]
    (
        set -u
        SERVER_DIR="$1"
        [ $# -ge 2 ] && STEAMCMD_DIR="$2"
        [ $# -ge 3 ] && PROTON_DIR="$3"
        for DIR in "${SERVER_DIR}" "${SERVER_DIR}/home" ${STEAMCMD_DIR:+"${STEAMCMD_DIR}"} ${PROTON_DIR:+"${PROTON_DIR}"}; do
            printf '[%s]' "${DIR}"
        done
    )
}

check "terraria: both unset, no crash, two dirs" \
    "[/sd][/sd/home]" \
    "$(dirs_for /sd)"

check "asa: all four dirs present" \
    "[/sd][/sd/home][/steam][/sd/proton]" \
    "$(dirs_for /sd /steam /sd/proton)"

check "path with spaces is not split" \
    "[/a b][/a b/home]" \
    "$(dirs_for "/a b")"

# --- release tag regex -------------------------------------------------------
# This is the exact `match=` value used in .github/workflows/build.yml. It must
# extract the version, reject a Terraria tag when scoped to the ASA slug, and
# refuse to match the `v` inside "sur[v]ival".

extract() {  # extract <slug> <tag>
    printf '%s' "$2" | sed -nE "s|^$1/v([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)$|\1|p"
}

check "asa release version extracts" \
    "1.5.0" "$(extract ark-survival-ascended ark-survival-ascended/v1.5.0)"
check "asa prerelease version extracts" \
    "1.6.0-rc.1" "$(extract ark-survival-ascended ark-survival-ascended/v1.6.0-rc.1)"
check "terraria tag does not match the asa pattern" \
    "" "$(extract ark-survival-ascended terraria/v1.0.0)"
check "terraria release version extracts" \
    "1.0.0" "$(extract terraria terraria/v1.0.0)"
check "a bare tag does not match" \
    "" "$(extract ark-survival-ascended v1.5.0)"
check "a typo'd slug does not match" \
    "" "$(extract ark-survival-ascended ark-survival-acended/v1.5.0)"

# --- repo root guard ---------------------------------------------------------
# Every check from here down reads repo files by relative path. Run from
# anywhere else and each one reports a misleading "no" instead of an error.
if [ ! -f shared/scripts/start.sh ]; then
    echo "FAIL - run this from the repo root: bash tests/unit.sh"
    exit 1
fi

# --- shared library surface --------------------------------------------------
# Two games source these now. A function that silently fails to move during an
# extraction produces a container that boots and then dies inside wine, so
# assert the surface exists rather than trusting the diff.

defines() {  # defines <file> <function name>
    bash -c "source '$1' >/dev/null 2>&1; declare -F '$2' >/dev/null && echo yes || echo no"
}

for fn in raise_nofile install_proton resolve_proton proton_debug_env \
          setup_proton_prefix wineserver_kill; do
    check "proton.sh defines ${fn}" "yes" "$(defines shared/scripts/proton.sh "${fn}")"
done

# --- proton tested-build comparison ------------------------------------------
# resolve_proton() warns when the build in use is not the one the image was
# tested against. Both sides are stripped of the -x86_64 suffix first, because
# GE-Proton ships the same build under both spellings depending on the release,
# and comparing them unstripped warns on every boot of a correct install.

same_build() {  # same_build <resolved> <tested>
    if [ "${1%-x86_64}" = "${2%-x86_64}" ]; then echo same; else echo differs; fi
}

check "suffixed and bare spellings of one build compare equal" \
    "same" "$(same_build GE-Proton10-34-x86_64 GE-Proton10-34)"
check "two different builds compare unequal" \
    "differs" "$(same_build GE-Proton11-5 GE-Proton10-34)"

for fn in steamcmd_home install_steamcmd run_steamcmd update_game link_steam_sdk; do
    check "steamcmd.sh defines ${fn}" "yes" "$(defines shared/scripts/steamcmd.sh "${fn}")"
done

# --- steam content log mark --------------------------------------------------
# update_game() records how long content_log.txt was before the run so the
# retired-manifest check only reads this run's lines. SteamCMD truncates that
# log when it grows, which would leave the mark past the end of the file and
# silently disable the recovery. A shrunk log means the mark is meaningless.

mark_after() {  # mark_after <mark before> <length now>
    local mark="$1"
    [ "$2" -lt "${mark}" ] && mark=0
    echo "${mark}"
}

check "a grown log keeps its mark" "500" "$(mark_after 500 900)"
check "a truncated log resets the mark to 0" "0" "$(mark_after 500 12)"

# --- lint globs --------------------------------------------------------------
# CI compiles games/*/scripts/*.py. Once rcon.py lives in shared/ that glob
# matches nothing, and the loop's own [ -e "$f" ] guard turns a vanished file
# into a pass rather than an error - a silent hole exactly where the shutdown
# path's only Python lives. Assert the workflow looks in both places.

check "CI compiles shared/scripts python" "yes" \
    "$(grep -q 'shared/scripts/\*\.py' .github/workflows/build.yml && echo yes || echo no)"
check "rcon.py is in shared" "yes" \
    "$([ -f shared/scripts/rcon.py ] && echo yes || echo no)"
check "rcon-cli.sh is in shared" "yes" \
    "$([ -f shared/scripts/rcon-cli.sh ] && echo yes || echo no)"

# --- v rising rcon flags -----------------------------------------------------
# This is the exact rule in games/v-rising/scripts/start-server.sh's build_flags().
# V Rising's own docs: the RCON password "must be configured, this cannot be
# left empty", so no admin password means RCON off, not RCON open.

rcon_flags() {  # rcon_flags <admin password> <port>
    if [ -n "$1" ]; then
        printf -- '-rconEnabled true -rconPort %s -rconPassword %s' "$2" "$1"
    else
        printf -- '-rconEnabled false'
    fi
}

check "an admin password enables rcon with port and password" \
    "-rconEnabled true -rconPort 25575 -rconPassword hunter2" \
    "$(rcon_flags hunter2 25575)"
check "no admin password disables rcon and emits no password flag" \
    "-rconEnabled false" \
    "$(rcon_flags "" 25575)"

# --- template env targets ----------------------------------------------------
# A Config Target= that names no ENV in the image is a field the user fills in
# and the server never sees. Nothing at runtime catches it, so catch it here.
#
# The absent-file and no-targets cases are called out explicitly. grep on a
# missing file prints nothing, so a loop over its output simply never runs and
# "missing" stays empty - which would report a pass for a template that does not
# exist at all, in exactly the situation this check was written for.

for slug in ark-survival-ascended terraria v-rising dragonwilds; do
    missing=""
    targets=""
    if [ ! -f "templates/${slug}.xml" ]; then
        missing="(no templates/${slug}.xml)"
    else
        targets="$(grep -o 'Target="[A-Z_]*"' "templates/${slug}.xml" | cut -d'"' -f2)"
        if [ -z "${targets}" ]; then
            missing="(template declares no environment targets)"
        fi
    fi
    for target in ${targets}; do
        grep -q "^ *${target}=" "games/${slug}/Dockerfile" || missing="${missing} ${target}"
    done
    check "${slug} template targets all exist in its Dockerfile" "" "${missing}"
done

check "v-rising release version extracts" \
    "1.0.0" "$(extract v-rising v-rising/v1.0.0)"
check "an asa tag does not match the v-rising pattern" \
    "" "$(extract v-rising ark-survival-ascended/v1.5.0)"
check "v-rising is in the CI game list" "yes" \
    "$(grep -q '"slug":"v-rising"' .github/workflows/build.yml && echo yes || echo no)"

# --- steamcmd first-run retry ------------------------------------------------
# update_game() retries once when a pass fails having installed nothing, which
# is SteamCMD's intermittent first-run "Missing configuration". It must NOT
# retry a failure that has an install on disk (a real error, and retrying just
# doubles the wait), nor one whose manifest the retired-manifest recovery has
# just moved aside, nor a pass that succeeded.

retry_decision() {  # retry_decision <rc> <manifest: yes|no> <stale manifest: yes|no>
    if [ "$1" -ne 0 ] && [ "$2" = "no" ] && [ "$3" = "no" ]; then
        echo retry
    else
        echo no-retry
    fi
}

check "a failed first pass with nothing installed retries" \
    "retry" "$(retry_decision 8 no no)"
check "a failed pass with an install on disk does not retry" \
    "no-retry" "$(retry_decision 8 yes no)"
check "a failure right after the retired-manifest recovery does not retry" \
    "no-retry" "$(retry_decision 8 no yes)"
check "a successful pass does not retry" \
    "no-retry" "$(retry_decision 0 no no)"

# --- steamcmd platform -------------------------------------------------------
# run_steamcmd() passes +@sSteamCmdForcePlatformType. It defaulted to "windows"
# when every SteamCMD game here was a Windows depot run under Proton; Dragonwilds
# publishes both a Windows and a Linux depot and needs the Linux one. The failure
# is silent in the worst way - the wrong depot installs perfectly cleanly and the
# launch target is simply absent afterwards, which reads as a failed download
# rather than a wrong one - so assert both branches.

platform_for() {  # platform_for [STEAM_DEPOT_PLATFORM]
    (
        set -u
        [ $# -ge 1 ] && STEAM_DEPOT_PLATFORM="$1"
        echo "${STEAM_DEPOT_PLATFORM:-windows}"
    )
}

check "no STEAM_DEPOT_PLATFORM keeps the windows default the proton games rely on" \
    "windows" "$(platform_for)"
check "STEAM_DEPOT_PLATFORM=linux overrides it" \
    "linux" "$(platform_for linux)"
check "the shared runner reads STEAM_DEPOT_PLATFORM rather than hardcoding windows" \
    "yes" \
    "$(grep -q 'STEAM_DEPOT_PLATFORM:-windows' shared/scripts/steamcmd.sh && echo yes || echo no)"
check "the dragonwilds image asks for the linux depot" \
    "yes" \
    "$(grep -q '^ *STEAM_DEPOT_PLATFORM="linux"' games/dragonwilds/Dockerfile && echo yes || echo no)"

# The name must not be STEAM_PLATFORM. SteamCMD's own steamcmd.sh reads that one
# to locate its binary (`: "${STEAM_PLATFORM:=linux32}"`, then
# `STEAMEXE="${STEAMROOT}/$STEAM_PLATFORM/${STEAMCMD}"`), so an image exporting
# STEAM_PLATFORM=linux sends SteamCMD hunting for
# /serverdata/steamcmd/linux/steamcmd and it exits 1 before doing anything, on
# every boot. That is a container that never installs its game and whose only
# complaint is one line in the startup noise. Caught by running the thing; this
# assertion is what stops it coming back.
# Comment lines are excluded on purpose: steamcmd.sh explains the collision in
# prose, and quoting the name in a warning must not trip the warning. Note that
# "STEAM_DEPOT_PLATFORM" does not contain "STEAM_PLATFORM" as a substring, so no
# further guarding is needed to tell the two apart.
check "no image or shared script sets the colliding STEAM_PLATFORM" "" \
    "$(grep -rn 'STEAM_PLATFORM' shared/scripts games/*/Dockerfile games/*/scripts 2>/dev/null \
       | grep -v ':[[:space:]]*#' | cut -d: -f1 | sort -u | tr '\n' ' ' | sed 's/ $//')"

# --- dragonwilds ini key rewriting -------------------------------------------
# The only non-trivial logic in that runner, and the one place a bug is
# expensive: this file is the sole channel for every setting the game has, and
# the SERVER writes to it too. A first run with no ini generates and persists a
# ServerGuid plus any missing ServerName/AdminPassword/DefaultWorldName:
#
#   LogDomServerSettings: Generated missing ServerGuid: CE0871C6...
#
# So the container must replace the five keys the template owns and preserve
# every other byte. Regenerating the file (Terraria's pattern) would destroy the
# ServerGuid; seeding write-once (ASA's pattern) would make the template's fields
# silently dead after first boot.
#
# The function is pulled out of the shipped runner rather than copied here, so
# these assertions cannot drift away from the code they describe.
eval "$(sed -n '/^set_ini_key() {/,/^}/p' games/dragonwilds/scripts/start-server.sh)"
DW_SECTION="/Script/Dominion.DedicatedServerSettings"
ini_tmp="$(mktemp -d)"
trap 'rm -rf "${ini_tmp}"' EXIT

# The literal file a real first run produced, on 2026-09-14.
generated_ini() {
    cat <<EOF
;METADATA=(Diff=true, UseCommands=true)
[${DW_SECTION}]
AdminPassword=YXPHC6S6YR8JW8KA
OwnerId=
ServerGuid=CE0871C643CA4D38A7F89D83DAB8C6B1
ServerName=Server-44208
WorldPassword=
DefaultWorldName=World-35188
EOF
}

f="${ini_tmp}/a.ini"
generated_ini > "${f}"
set_ini_key "${f}" "${DW_SECTION}" OwnerId 0123456789ABCDEF
check "an existing key is replaced in place" \
    "OwnerId=0123456789ABCDEF" "$(grep '^OwnerId=' "${f}")"
check "ServerGuid survives a managed-key rewrite" \
    "ServerGuid=CE0871C643CA4D38A7F89D83DAB8C6B1" "$(grep '^ServerGuid=' "${f}")"
check "the ;METADATA line survives" \
    ";METADATA=(Diff=true, UseCommands=true)" "$(head -n1 "${f}")"
check "the rewrite adds no lines" "8" "$(wc -l < "${f}")"

# A value carrying the characters that would break a sed-based implementation.
# awk concatenates rather than substituting, which is why this is safe.
set_ini_key "${f}" "${DW_SECTION}" ServerName 'Jordan & co = 100% \fun/'
check "a value with & = \\ / and spaces is written verbatim" \
    "ServerName=Jordan & co = 100% \\fun/" "$(grep '^ServerName=' "${f}")"

# Clearing a password field must actually clear it, not leave the old value.
set_ini_key "${f}" "${DW_SECTION}" WorldPassword ""
check "an emptied field is written as an empty value" \
    "WorldPassword=" "$(grep '^WorldPassword=' "${f}")"

# A key the file does not have yet, in a section it does.
f="${ini_tmp}/b.ini"
printf ';META\n[%s]\nServerGuid=KEEP\n' "${DW_SECTION}" > "${f}"
set_ini_key "${f}" "${DW_SECTION}" OwnerId ABC
check "a missing key is appended to the existing section" \
    ";META|[${DW_SECTION}]|ServerGuid=KEEP|OwnerId=ABC" \
    "$(paste -sd'|' "${f}")"

# Neither the section nor the key exists. Must not corrupt what is there.
f="${ini_tmp}/c.ini"
printf '[SomethingElse]\nFoo=bar\n' > "${f}"
set_ini_key "${f}" "${DW_SECTION}" OwnerId ABC
check "a missing section is created without disturbing the existing one" \
    "[SomethingElse]|Foo=bar||[${DW_SECTION}]|OwnerId=ABC" \
    "$(paste -sd'|' "${f}")"

# No file at all: the very first boot, before the server has ever run.
f="${ini_tmp}/d.ini"
set_ini_key "${f}" "${DW_SECTION}" OwnerId ABC
check "an absent file is created with just the section and key" \
    "[${DW_SECTION}]|OwnerId=ABC" "$(paste -sd'|' "${f}")"

# The target section is NOT last. An appended key must land inside it, against
# the other keys, rather than at the bottom of the file under someone else's.
f="${ini_tmp}/e.ini"
printf '[%s]\nServerGuid=KEEP\n\n[Other]\nX=1\n' "${DW_SECTION}" > "${f}"
set_ini_key "${f}" "${DW_SECTION}" OwnerId ABC
check "a key appended to a non-final section stays inside it" \
    "[${DW_SECTION}]|ServerGuid=KEEP|OwnerId=ABC||[Other]|X=1" \
    "$(paste -sd'|' "${f}")"

# The same key name in another section is not ours to touch.
f="${ini_tmp}/f.ini"
printf '[Other]\nOwnerId=DO_NOT_TOUCH\n[%s]\nOwnerId=old\n' "${DW_SECTION}" > "${f}"
set_ini_key "${f}" "${DW_SECTION}" OwnerId NEW
check "a same-named key in a different section is left alone" \
    "[Other]|OwnerId=DO_NOT_TOUCH|[${DW_SECTION}]|OwnerId=NEW" \
    "$(paste -sd'|' "${f}")"

# --- dragonwilds release and CI ----------------------------------------------
check "dragonwilds release version extracts" \
    "1.0.0" "$(extract dragonwilds dragonwilds/v1.0.0)"
check "a v-rising tag does not match the dragonwilds pattern" \
    "" "$(extract dragonwilds v-rising/v1.0.0)"
check "dragonwilds is in the CI game list" "yes" \
    "$(grep -q '"slug":"dragonwilds"' .github/workflows/build.yml && echo yes || echo no)"

# --- dragonwilds launches the binary, not the wrapper ------------------------
# RSDragonwildsServer.sh does not exec - it runs the ELF as a child - so a signal
# sent to the wrapper never reaches the game, and the shutdown handler would
# report a clean save while the server was hard-killed by the teardown. Launching
# the ELF directly is what makes $! the server. This is the same class of bug the
# V Rising runner needed /proc/<pid>/comm to work around, avoided rather than
# handled, so assert the avoidance holds.
check "the runner launches the ELF directly" "yes" \
    "$(grep -q 'RSDragonwildsServer-Linux-Shipping' games/dragonwilds/scripts/start-server.sh && echo yes || echo no)"
check "the runner does not launch the non-exec wrapper" "yes" \
    "$(grep -q '\${SERVER_DIR}/RSDragonwildsServer.sh' games/dragonwilds/scripts/start-server.sh && echo no || echo yes)"

# The server aborts under root with "Refusing to run with the root privileges",
# so the image must not ship UID=0 as a default.
check "the dragonwilds image does not default to root" "yes" \
    "$(grep -q '^ *UID="0"' games/dragonwilds/Dockerfile && echo no || echo yes)"

# --- dragonwilds port model --------------------------------------------------
# This game advertises the port the server BINDS, not the port the host publishes:
#
#   LogRedpointEOSNetworking: Verbose: User '(dedicated server)' is now listening
#   on Internet address '0.0.0.0:7777' with 0 developer addresses.
#
# and the EOS session carries no address or port attribute of its own, so a client
# joining from the in-game browser is sent to <public ip>:<bind port>. A port
# mapping cannot translate that. Publish 7780 against a server bound to 7777 and
# the world is listed, reports ReadyToJoin=1, heartbeats fine and logs nothing -
# while every join lands on 7777. So all three numbers are one number.
#
# 1.0.3 shipped the opposite advice and this is what guards against it returning.
dw_runner=games/dragonwilds/scripts/start-server.sh

# There is no runtime check here on purpose. Nothing inside a container can read
# its own published mapping, so any warning keyed on GAME_PORT vs the image's
# EXPOSE fires on host 7780 -> container 7780 -> GAME_PORT 7780, which is correct.
# A false alarm on the correct configuration is worse than no alarm.
check "the runner has no port warning that cannot tell right from wrong" "yes" \
    "$(grep -q 'check_game_port\|EXPOSED_PORT' "${dw_runner}" && echo no || echo yes)"

# The banner is unconditional, so it must be true unconditionally: it states the
# rule rather than judging the configuration.
dw_banner_text="$(sed -n '/^echo "---Starting RuneScape/,/^echo "---First boot/p' "${dw_runner}")"
check "the banner states all three numbers must match" "yes" \
    "$(echo "${dw_banner_text}" | grep -q 'must all be' && echo yes || echo no)"
check "the banner names the container port" "yes" \
    "$(echo "${dw_banner_text}" | grep -qi 'container' && echo yes || echo no)"
check "the banner does not claim a host-side change is enough" "yes" \
    "$(echo "${dw_banner_text}" | grep -qi 'host side of the mapping instead' && echo no || echo yes)"

# The three sockets, measured on a real boot with GAME_PORT=7900:
#   7900  IpNetDriver listening on port 7900          <- tracks GAME_PORT
#   8888  World settings beacon listening on port 8888 <- fixed, NOT derived
#   45453 LogDomLanProbe: Socket setup OK              <- fixed
# Derived from the game port would have put the beacon at 9011.
check "the image exposes the game port" "yes" \
    "$(grep -q '^EXPOSE 7777/udp$' games/dragonwilds/Dockerfile && echo yes || echo no)"
check "the image exposes the beacon port" "yes" \
    "$(grep -q '^EXPOSE 8888/udp$' games/dragonwilds/Dockerfile && echo yes || echo no)"
check "the image does not expose the LAN probe, which cannot work on a bridge" "yes" \
    "$(grep -q '^EXPOSE 45453' games/dragonwilds/Dockerfile && echo no || echo yes)"

# --- dragonwilds template port rows ------------------------------------------
dw_gp="$(grep -o '<Config Name="Game Port"[^>]*>' templates/dragonwilds.xml)"
dw_sp="$(grep -o '<Config Name="Server Port"[^>]*>' templates/dragonwilds.xml)"
check "Server Port is a visible field again" "yes" \
    "$(echo "${dw_sp}" | grep -q 'Display="always"' && echo yes || echo no)"
check "Server Port is required again" "yes" \
    "$(echo "${dw_sp}" | grep -q 'Required="true"' && echo yes || echo no)"
check "the template has a Beacon Port row" "yes" \
    "$(grep -q '<Config Name="Beacon Port"[^>]*Target="8888"' templates/dragonwilds.xml && echo yes || echo no)"
check "the Game Port field teaches the three-number rule" "yes" \
    "$(echo "${dw_gp}" | grep -q 'THREE things to the same number' && echo yes || echo no)"
check "no template text says changing this row alone moves the port" "yes" \
    "$(grep -qi 'only port number you need to change' templates/dragonwilds.xml && echo no || echo yes)"

# --- dragonwilds documented ports --------------------------------------------
# Four copies of "7777 is the only port the server binds" is how that wrong claim
# survived two releases; it stays asserted against.
dw_wrong_claim='only port the server binds\|only port this server binds\|exactly one socket'
for doc in games/dragonwilds/README.md games/dragonwilds/docs/dockerhub.md \
           games/dragonwilds/Dockerfile; do
    check "${doc} does not claim 7777 is the only port bound" "yes" \
        "$(grep -qi "${dw_wrong_claim}" "${doc}" && echo no || echo yes)"
done
check "the template's fields do not claim 7777 is the only port bound" "yes" \
    "$(grep '<Config ' templates/dragonwilds.xml | grep -qi "${dw_wrong_claim}" && echo no || echo yes)"

for doc in games/dragonwilds/README.md games/dragonwilds/docs/dockerhub.md; do
    check "${doc} documents all three sockets" "yes" \
        "$(grep -q '8888' "${doc}" && grep -q '45453' "${doc}" && echo yes || echo no)"
    check "${doc} states the LAN-discovery-under-bridge limitation" "yes" \
        "$(grep -qi 'broadcast' "${doc}" && echo yes || echo no)"
    check "${doc} points at the Direct tab for LAN play" "yes" \
        "$(grep -qi 'Direct' "${doc}" && echo yes || echo no)"
    check "${doc} keeps bridge on a non-default port supported" "yes" \
        "$(grep -qi 'bridge networking on a non-default port is fully supported' "${doc}" && echo yes || echo no)"
done
check "the README notes the NAT hairpin caveat" "yes" \
    "$(grep -qi 'hairpin' games/dragonwilds/README.md && echo yes || echo no)"

exit "$fail"
