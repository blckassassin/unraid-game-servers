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

for slug in ark-survival-ascended terraria v-rising; do
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

exit "$fail"
