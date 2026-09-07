# Design: V Rising dedicated server

Status: approved 2026-09-07. Adds game three, `ferment9348/v-rising`. Amends §2 and
§8 of `2026-09-03-game-server-monorepo-design.md`, which are quoted and revised in
section 1 below.

## Goal

Add V Rising as a third container, and extract ASA's SteamCMD + GE-Proton layer into
`shared/scripts/` so the two Windows-depot games run one copy of it rather than two.

## Verified facts

Established from the official Stunlock instructions (`1.1.x-pc/INSTRUCTIONS.md`) and
from two widely used reference containers, not assumed. Re-verify before relying on
any of these.

- Steam app **1829350**, anonymous login. Windows only: *"At the moment there is only
  a Windows version of the server available."* SteamCMD needs
  `+@sSteamCmdForcePlatformType windows`, exactly as ASA does.
- Default ports: game **27015/udp**, query **27016/udp**, RCON **25575/tcp**.
- `-persistentDataPath <dir>` relocates both `Settings/` and `Saves/` under `<dir>`.
- The install ships defaults at
  `VRisingServer_Data/StreamingAssets/Settings/{ServerHostSettings,ServerGameSettings}.json`.
  Both reference containers copy these into the persistent path on first boot.
- **Every `ServerHostSettings.json` field has an environment-variable override
  (`VR_GAME_PORT`) and a command-line override (`-gamePort`), and both beat the file.**
  This is what removes any need to rewrite JSON at runtime.
- RCON commands: `help`, `announce`, `announcerestart`, `shutdown <message times>
  <message>`, `cancelshutdown`, `name`, `description`, `password`, `version`, `time`.
  The RCON password *"must be configured, this cannot be left empty."*
- A virtual display is required. ich777 runs
  `xvfb-run --auto-servernum --server-args='-screen 0 640x480x24:32' wine64 ...`;
  TrueOsiris runs `Xvfb :0` with `DISPLAY=:0.0`. Neither runs the binary bare.
- On CPUs without AVX, `VRisingServer_Data/Plugins/x86_64/lib_burst_generated.dll`
  has to be moved aside or the server fails to start.
- **The server saves on `SIGINT`, not `SIGTERM`.** Measured 2026-09-07 under
  GE-Proton10-34, three times: `SIGTERM` kills it in under half a second with no save
  and nothing in its log, while `SIGINT` writes a full save in about one second and
  exits 0 about three seconds later. TrueOsiris's container sends `kill -15` and
  relies on it, but that runs under plain `wine64`, which evidently translates the
  signal differently. This is why the reference containers are a starting point and
  not evidence.
- RCON's `shutdown` does save, but it *schedules*: `shutdown 1 msg` measured here took
  over three minutes to fire, and `<message times>` rejects `0`. It is an admin tool,
  not a shutdown path.

### Not verified — establish during implementation, do not assume

- Install size on disk. The Unraid template's `<Requires>` needs a real number.
- Whether V Rising's RCON is byte-compatible with `rcon.py`'s Source implementation.
  It is documented as RCON and the command set looks standard, but nothing here has
  spoken to it yet.
- Whether `GE-Proton10-34` runs V Rising. This repo has already lost time to a Proton
  build that hung ASA silently; assume nothing.
- Whether `xvfb` is still needed under **GE-Proton** specifically. Both references use
  plain `wine64`. Ship with it, since a missing display fails at startup and costs a
  release cycle; drop it later only with a boot that proves it.

## 1. Shared code boundary — the premise changed

The monorepo design says:

> Only `shared/scripts/start.sh` is shared. No base image, no per-game abstraction
> layer — there is nothing to abstract.

and, as a reason:

> Code reuse is *not* a reason. ASA (SteamCMD, Windows depot, GE-Proton, RCON) and
> Terraria (native Linux binary, no Steam, no RCON) share almost nothing.

That was true of those two games. V Rising is a second Windows-depot, SteamCMD,
GE-Proton, RCON game, so the premise no longer holds and the boundary moves. It moves
by exactly one step: **shared implementation for the two games that genuinely share
it.** Still no base image, still no per-game abstraction layer, still no registry.

| New file | Lifted verbatim from `games/ark-survival-ascended/scripts/start-server.sh` |
| --- | --- |
| `shared/scripts/proton.sh` | `install_proton()` with the `-x86_64` asset-naming fallback and sha512 verification, the `.created-by-proton` prefix marker and discard, `wineserver_kill()`, the `PROTON_TESTED` mismatch warning |
| `shared/scripts/steamcmd.sh` | SteamCMD bootstrap, `run_steamcmd()`, the retired-manifest recovery, `link_steam_sdk()` |
| `shared/scripts/rcon.py` | moved from `games/ark-survival-ascended/scripts/`, unchanged |
| `shared/scripts/rcon-cli.sh` | moved, unchanged; it already reads `RCON_PORT` and `SRV_ADMIN_PWD` from the environment |

**This is a move, not a rewrite.** The lines that survive review in ASA today are the
lines that go into the shared files. Any improvement anyone spots along the way is a
separate commit after ASA has booted green, not a passenger on this one.

Each shared file states the variables it reads at the top and reads nothing else:

- `proton.sh` — `PROTON_DIR`, `PROTON_VERSION`, `PROTON_TESTED`, `STEAM_COMPAT_DATA_PATH`.
  Exports `PROTON_BIN` and `PROTON_RESOLVED`, and owns the fallback to the newest
  build already on disk when the download fails, plus ASA's `ulimit -n` bump — that
  is Proton's esync/fsync FD appetite, not anything about ARK.
- `steamcmd.sh` — `STEAMCMD_DIR`, `SERVER_DIR`, `GAME_ID`, `USERNAME`, `PASSWRD`,
  `VALIDATE`. Exports `STEAM_RC`, and **owns the `HOME` repoint** to
  `${SERVER_DIR}/home`.

The `HOME` repoint moves into `steamcmd.sh` rather than staying with ASA. It is a
SteamCMD concern, not an ARK one: the `depotcache` manifests an incremental update
diffs against live under `$HOME`, and on the default `/home/steam` they are destroyed
whenever the container is recreated, after which Steam refuses a request code for the
superseded manifest and the update dies with `Access Denied`. V Rising updates through
the same SteamCMD and would hit the same wall. It must still be exported *after*
`gosu`, which sets `HOME` from passwd, so it stays a line the runner executes at
source time rather than a Dockerfile `ENV`.

What stays in ASA's runner because it is ASA's: the `?`-query string and its argument
ordering trap, the write-once `GameUserSettings.ini` seed, `fix_share_perms()` and
`resolve_config_modes()`, `locate_game_dirs()`, the `ShooterGame.log` tail, the
no-engine-output watchdog.

Terraria's Dockerfile copies `shared/scripts/` wholesale, so its image gains three
files it never runs (~30KB, and it has no `python3` to run `rcon.py` with anyway).
Restructuring that `COPY` to avoid dead weight costs more than the dead weight.

## 2. `games/v-rising/`

`Dockerfile`, modelled on ASA's. `debian:trixie-slim`, the same library set, plus
`xvfb`, `xauth` and `winbind`.

```
STEAMCMD_DIR="/serverdata/steamcmd"
SERVER_DIR="/serverdata/serverfiles"
PROTON_DIR="/serverdata/serverfiles/proton"
DATA_PATH="/serverdata/serverfiles/save-data"
GAME_ID="1829350"
SERVER_NAME="V Rising Server"
SERVER_DESC=""
WORLD_NAME="world1"
GAME_PORT="27015"
QUERY_PORT="27016"
RCON_PORT="25575"
MAX_PLAYERS="40"
MAX_ADMINS="4"
SRV_PWD=""
SRV_ADMIN_PWD=""
GAME_PRESET=""
DIFFICULTY_PRESET=""
LIST_ON_STEAM="true"
LIST_ON_EOS="true"
SECURE="true"
GAME_PARAMS_EXTRA=""
PROTON_TESTED="GE-Proton10-34"
PROTON_VERSION="GE-Proton10-34"
STOP_TIMEOUT="60"
```

plus the `VALIDATE`, `USERNAME`, `PASSWRD`, `UID`, `GID`, `DATA_PERM`, `UMASK`,
`DEBUG`, `WINEDEBUG` and `LD_LIBRARY_PATH` block ASA already carries.

`EXPOSE 27015/udp 27016/udp 25575/tcp`.
`VOLUME ["/serverdata/steamcmd", "/serverdata/serverfiles"]` — `PROTON_DIR` and
`DATA_PATH` both sit inside `SERVER_DIR` and must **not** be declared, or the nested
volume shadows the parent mount.
`ENTRYPOINT ["/usr/bin/tini", "--", "/opt/scripts/start.sh"]`, no `-g`, same reason
as ASA: process-group signalling would defeat the shutdown handler.

`start.sh` needs no change. `SERVER_DIR`, `STEAMCMD_DIR` and `PROTON_DIR` are all set,
so its existing `${VAR:+"${VAR}"}` loop already covers this game.

## 3. Settings

**Seeded once, never rewritten.** On boot, if `${DATA_PATH}/Settings/` is absent,
copy `VRisingServer_Data/StreamingAssets/Settings/` into it. After that the container
never writes those files again, so every hand edit survives — including all of
`ServerGameSettings.json`, which the container never touches at all.

Template-driven values reach the server as launch flags instead, so they take effect
on every restart without anything being rewritten:

| Variable | Flag | Note |
| --- | --- | --- |
| `SERVER_NAME` | `-serverName` | |
| `SERVER_DESC` | `-description` | omitted when empty |
| `GAME_PORT` | `-gamePort` | |
| `QUERY_PORT` | `-queryPort` | |
| `MAX_PLAYERS` | `-maxUsers` | |
| `MAX_ADMINS` | `-maxAdmins` | |
| `SRV_PWD` | `-password` | omitted when empty |
| `WORLD_NAME` | `-saveName` | |
| `SRV_ADMIN_PWD` | `-rconPassword` + `-rconEnabled true` | see below |
| `RCON_PORT` | `-rconPort` | only with RCON enabled |
| `LIST_ON_STEAM` | `-listOnSteam` | |
| `LIST_ON_EOS` | `-listOnEOS` | |
| `SECURE` | `-secure` | |
| `GAME_PRESET` | `-preset` | omitted when empty |
| `DIFFICULTY_PRESET` | `-difficultyPreset` | omitted when empty |
| `GAME_PARAMS_EXTRA` | appended verbatim | word-split like ASA's |

RCON follows ASA's rule: no admin password means no RCON. An empty `SRV_ADMIN_PWD`
emits `-rconEnabled false` and no port or password flag, because the documentation is
explicit that an enabled RCON with an empty password is not a valid configuration.

Everything not in that table is still reachable and costs no code: the server reads
`VR_*` variables from its own environment, so a `VR_FPS=45` added in the Unraid
template's extra-variable field arrives without the container knowing the setting
exists. Say so in the README and the template — it is the answer to every "can I set
X" question this container will ever get.

## 4. Launch

```
cd "${SERVER_DIR}"
xvfb-run --auto-servernum --server-args='-screen 0 640x480x24:32' \
    "${PROTON_BIN}" run ./VRisingServer.exe \
    -persistentDataPath "${DATA_PATH}" -logFile "${SERVER_LOG}" "${FLAGS[@]}"
```

Before that, the AVX guard, run once per install:

```bash
# lib_burst_generated.dll is compiled for AVX and aborts the server on a CPU
# without it - not rare on the older Xeons a lot of Unraid boxes are built on.
# Moving it aside makes the server fall back to its portable path. A SteamCMD
# update restores the DLL, so this runs on every boot rather than once.
BURST="${SERVER_DIR}/VRisingServer_Data/Plugins/x86_64/lib_burst_generated.dll"
if ! grep -qw avx /proc/cpuinfo && [ -f "${BURST}" ]; then
    echo "---This CPU has no AVX; moving lib_burst_generated.dll aside---"
    mv -f "${BURST}" "${BURST}.bak"
fi
```

`SERVER_LOG` is `${SERVER_DIR}/logs/VRisingServer.log`, mirrored into the
container log by `tail -F -n 0` the way ASA mirrors `ShooterGame.log`. V Rising does
not emit Terraria's per-0.1% progress flood, so no collapsing filter is needed and
none should be added.

## 5. Shutdown

`STOP_TIMEOUT=60`. The template repeats ASA's warning to raise Unraid's own container
stop timeout to match, since Docker's default grace is 10s.

```
graceful_shutdown()
  1. identify the VRisingServer.exe process  ->  kill -INT
     (SIGINT saves; SIGTERM does not - see Verified facts. Note below on
     identifying the process.)
  2. poll up to STOP_TIMEOUT, printing progress every 10s so the wait does not
     read as a hang while a save is in flight
  3. ONLY if it is still alive at STOP_TIMEOUT: wineserver_kill(), then kill -9
     the Proton wrapper. This is the fallback, not a step every shutdown runs -
     a clean exit skips it, exactly as ASA's shutdown does today.
```

Identifying the process is the part that is easy to get wrong. `pkill -f
VRisingServer.exe` matches too much: the Proton launcher was invoked *as* `proton run
./VRisingServer.exe` and the `xvfb-run` wrapper's command line contains the same string,
so `-f` hits all three. Signalling a wrapper tears the prefix down without the game ever
seeing SIGTERM - a hard kill wearing a graceful shutdown's log messages. `pkill -x` does
not help either: Linux truncates a process name to 15 characters, so the game's is
`VRisingServer.e` and an exact-name match on the full name never fires. Match on
`/proc/<pid>/comm` against that truncated name.

RCON is deliberately **not** on this path. It is an admin tool only —
`rcon-cli.sh announce`, `shutdown`, `password` — which is what makes moving `rcon.py`
into `shared/` worth doing rather than incidental. A shutdown that depends on RCON
would also depend on the user having set an admin password, and V Rising does not
need it to save.

## 6. Ports

Defaults are the documented ones: 27015/udp, 27016/udp, 25575/tcp.

**ASA's Query Port also defaults to 27015.** Running both containers on one Unraid box
in bridge mode means Docker refuses to start the second one. The V Rising template's
Game Port description says so and names ASA's port as the one to move, since ASA's
27015 is vestigial — discovery goes via EOS.

Game Port and Server Port are a paired field, following Terraria's template: the
container port, the host port and `GAME_PORT` must agree, or the log reports a number
players cannot use. Same for the query pair.

## 7. Template, CA, docs, icon

- `templates/v-rising.xml` — new. `<ReadMe>` points at
  `games/v-rising/README.md`; unlike ASA there is no frozen-URL constraint here,
  because no template for this game has ever been installed.
- `games/v-rising/README.md` — the guide. ASA's README-at-root exception does not
  apply and must not be copied.
- `games/v-rising/docs/dockerhub.md` — Docker Hub long description.
- `games/v-rising/docker-compose.yml` — local testing, uid/gid 1000.
- `v-rising.png` / `v-rising.svg` at the repo root, from a new
  `tools/icongen/vrising.py` beside `terraria.py`. Do not refactor `build.py` into a
  common module; the monorepo design already ruled on that.
- `ca_profile.xml` — the profile text goes from two servers to three.
- Root `README.md` line 3 — add V Rising to the "Other servers in this repo" line.
- `AGENTS.md` — the layout table's shared-scripts rows, the new build command, and a
  constraints entry for the xvfb requirement and the AVX guard.
- A `ferment9348/v-rising` repository on Docker Hub, created before the first tag.

`.dockerignore` needs no change for the new game: `!games/*/scripts/` already covers it,
and the monorepo design's claim that it needs editing per game is stale. It does need
one change for the shared directory - CI starts compiling `shared/scripts/*.py`, and the
`__pycache__` that creates is not matched by the existing `games/*/scripts/__pycache__/`
rule, so it would be copied into all three images.

## 8. CI

One new entry in `build.yml`'s `ALL` list — slug, title, description, tagline. The tag
glob is `'*/v*'`, the semver pattern is built from the slug, and the slug validation in
`setup` already fails a typo loudly, so nothing else about tagging changes.

One thing does, and it fails **silently** if missed. The lint step compiles
`games/*/scripts/*.py`, which is where `rcon.py` lives today. Once it moves to
`shared/scripts/` that glob matches nothing at all, and the loop's `[ -e "$f" ]` guard
turns a vanished file into a pass rather than an error. The step must gain
`shared/scripts/*.py`, and `AGENTS.md`'s Test section has the same path written out
and needs the same edit.

No e2e step. The `if: matrix.game.slug == 'terraria'` guard stays exactly as it is.

## 9. Testing

```sh
shellcheck --severity=warning shared/scripts/*.sh games/*/scripts/*.sh tests/*.sh
python3 -m py_compile shared/scripts/rcon.py
bash tests/unit.sh
bash tests/e2e-terraria.sh terraria-test
```

`tests/unit.sh` gains: the V Rising tag-regex cases (extracts its own version, does
not match another slug's tag), and a flags-array case covering the RCON rule — that an
empty `SRV_ADMIN_PWD` yields `-rconEnabled false` with no password flag, and a set one
yields all three flags.

Two manual smoke runs, both required before the first tag:

1. **ASA, after the extraction.** This is the real risk in the change. Boot it, confirm
   it resolves Proton, reaches SteamCMD, prints the uid/gid, and that a stop still
   saves over RCON.
2. **V Rising.** Boot to "Startup Completed" in the log, then stop the container and
   confirm the save landed. This is also where the four unverified facts above get
   settled. Joining from a real client is not part of this: it needs a licensed copy
   and proves less than the server-side checks already do.

## 10. Deliberately not building

- **BepInEx mod loading.** ich777 ships it; it is a large block of version-checking and
  archive-handling logic, and nobody has asked. A user who wants it can mount it.
- **Steam `-beta` branch selection.**
- **A shared base image**, a per-game abstraction layer, a `game.json` registry. All
  three were ruled out by the monorepo design and none of them is any more justified
  by a third game than it was by a second.
- **Any rewrite of ASA beyond the mechanical extraction.**
- **A worldgen-style log collapsing filter.** V Rising does not need one.

## 11. Blocking before the first `v-rising/v*` tag

1. Both smoke runs in section 9 green, ASA's first.
2. The four unverified facts settled, and this document corrected where they differ.
3. `ferment9348/v-rising` created on Docker Hub, and `DOCKERHUB_TOKEN` confirmed to
   carry "Read, Write, Delete" — the description sync fails silently otherwise, which
   has already happened twice in this repo.
4. `STOP_TIMEOUT` and the Unraid stop-timeout note agreeing in template and README.
