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

exit "$fail"
