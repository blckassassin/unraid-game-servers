# AGENTS.md

Dedicated game server containers for Unraid. Five games live here today, in three
shapes:

- **ARK: Survival Ascended** and **V Rising** — Debian + SteamCMD pulling the
  Windows depot, run under GE-Proton. V Rising additionally needs a virtual
  display.
- **RuneScape: Dragonwilds** and **Valheim** — Debian + SteamCMD pulling the
  *Linux* depot, run natively. No Proton.
- **Terraria** — Debian, native Linux binary, no SteamCMD and no Proton.

Target platform is Unraid; each game's `docker-compose.yml` is for local testing
only.

## Layout

| Path                                   | What it is                                          |
| --------------------------------------- | --------------------------------------------------- |
| `games/<slug>/Dockerfile`              | Image definition for that game. Built with the repo root as context. |
| `games/<slug>/docker-compose.yml`      | Local testing only. Uses uid/gid 1000, not Unraid's 99/100. |
| `games/<slug>/scripts/`                | Game-specific scripts, copied to `/opt/scripts` in the image. |
| `games/<slug>/docs/dockerhub.md`       | Docker Hub long description, synced by CI on release. |
| `games/<slug>/README.md`               | That game's guide, and what that template's `<ReadMe>` points at. Every game has one. |
| `shared/scripts/rcon.py`               | Minimal Source RCON client, shared by every game with RCON. No dependencies beyond stdlib. |
| `shared/scripts/rcon-cli.sh`           | Thin wrapper for `docker exec` use.                 |
| `games/terraria/scripts/console.sh`    | Sends a command through Terraria's FIFO console.    |
| `shared/scripts/start.sh`              | Common root entrypoint, runs as root. Reconciles the `steam` uid/gid, fixes ownership, then `gosu` to that game's `start-server.sh`. |
| `shared/scripts/proton.sh`             | GE-Proton install, prefix management and `wineserver_kill`. Sourced by ASA and V Rising. |
| `shared/scripts/steamcmd.sh`           | SteamCMD bootstrap, the app update and its retired-manifest recovery, and the `HOME` repoint. Sourced by ASA, V Rising, Dragonwilds and Valheim. `STEAM_DEPOT_PLATFORM` picks the depot; it defaults to `windows` for the two Proton games. |
| `templates/<slug>.xml`                 | Unraid Community Apps template for that game. CA requires one XML per app under `templates/`. |
| `ca_profile.xml`                       | CA repository profile, covering every game here. Must be at the root with a non-empty `<Profile>`, or submission is blocked. |
| `icon.png` / `icon.svg`                | ASA's icons, referenced by `ca_profile.xml` and its template. |
| `terraria.png` / `terraria.svg`        | Terraria's icons.                                    |
| `v-rising.png` / `v-rising.svg`        | V Rising's icons.                                    |
| `dragonwilds.png` / `dragonwilds.svg`  | Dragonwilds' icons.                                  |
| `valheim.png` / `valheim.svg`          | Valheim's icons.                                     |
| `tools/icongen/`                       | Generates the per-game icon PNGs from source art.    |
| `tests/unit.sh`                        | Plain-assertion unit tests, no framework.            |
| `tests/e2e-terraria.sh`                | Boot/shutdown end-to-end test against a built Terraria image. |
| `.github/workflows/build.yml`          | CI: lints, builds every game, publishes on a `<slug>/v<version>` tag. |

## Build

```sh
docker build -f games/ark-survival-ascended/Dockerfile -t asa-test .
docker build -f games/terraria/Dockerfile -t terraria-test .
docker build -f games/v-rising/Dockerfile -t vrising-test .
docker build -f games/dragonwilds/Dockerfile -t dragonwilds-test .
docker build -f games/valheim/Dockerfile -t valheim-test .
```

## Test

There is no unit test framework beyond plain assertions. The checks that must
pass before a change ships:

```sh
shellcheck --severity=warning shared/scripts/*.sh games/*/scripts/*.sh tests/*.sh
python3 -m py_compile shared/scripts/rcon.py
bash tests/unit.sh
bash tests/e2e-terraria.sh terraria-test     # Terraria only; ASA's boot pulls ~13GB
```

Terraria's install is ~46MB and its e2e test above covers a real boot and
shutdown, so it needs no manual check beyond that. ASA and V Rising are the
opposite: their boots pull ~13GB and ~2GB, so both stay manual smoke runs — start
one and confirm it reaches the SteamCMD step and prints the resolved uid/gid,
then stop it there:

```sh
docker run --rm -e UID=1000 -e GID=1000 asa-test
docker run --rm -e UID=1000 -e GID=1000 vrising-test
docker run --rm -e UID=1000 -e GID=1000 dragonwilds-test
docker run --rm -e UID=1000 -e GID=1000 -e SRV_PWD=atleast5 valheim-test
```

Dragonwilds is the same kind of manual check (~1.5GB download, ~5GB installed),
but it needs a real `OWNER_ID` to get past the guard in its runner and reach a
world. Without one the run stops at that message, which is itself the thing worth
confirming.

## Constraints

- **Release tags are `<slug>/v<version>`.** e.g. `ark-survival-ascended/v1.5.0`.
  A bare `v1.2.3` triggers nothing at all.
- **Push release tags one at a time.** Four tags in a single `git push` created
  all four refs and fired *zero* workflow runs: no build, no publish, and no
  failure anywhere to notice, because an empty run list looks identical to a
  release that has not started yet. GitHub drops push events when several tags
  arrive together. Delete and re-push each one on its own —
  `git push origin :refs/tags/<tag>` then `git push origin <tag>` — and confirm
  the run exists before pushing the next.
- **Every game has `games/<slug>/README.md`, and the root `README.md` is the
  repo index.** ASA was the exception until 2026-09-18: its guide lived at the
  root because an installed CA template's `<ReadMe>` freezes that URL forever
  and those users never receive a new template. The guide has moved to
  `games/ark-survival-ascended/README.md` and the template now points there, so
  **the root `README.md` must keep a visible pointer to the ASA guide near the
  top** — that is what an installed pre-2026-09-18 ASA template still fetches,
  and removing it strands those users. A unit test asserts every game has a
  README, that each template points at its own, and that the root still carries
  the ASA pointer.
- **Terraria's `STOP_TIMEOUT` is `6`, not ASA's `120`.** `6` plus a bounded 3s
  wait for the log reader must stay under Docker's 10s default stop grace
  (6+3=9s). Do not copy ASA's value over.
- **Every image runs as the account `steam`, Terraria included**, because
  `shared/scripts/start.sh` hardcodes it in the `gosu` call.
- **`UID` is also a bash variable.** In `shared/scripts/start.sh` it is read
  into `TARGET_UID` rather than used directly, and `PUID`/`PGID` are accepted
  as aliases. Do not "simplify" that back to bare `${UID}`.
- **Terraria's stdout never gets piped to a live reader.** The runner
  (`games/terraria/scripts/start-server.sh`) writes the server's stdout to a
  plain file and mirrors a collapsed view of it into the container log
  separately. This is not cosmetic: Terraria emits one line per 0.1% of every
  worldgen/save phase, and piping that live into a reader makes the server
  itself run roughly 20x slower and can wedge the container log entirely.
  `VERBOSE_LOG=true` bypasses the collapsing for diagnosis without touching how
  the server itself is run. Do not "simplify" this into a live pipe.
- **Windows depot, not Linux (ASA and V Rising).** Neither has a native Linux
  server binary. `run_steamcmd()` passes `+@sSteamCmdForcePlatformType` from
  `STEAM_DEPOT_PLATFORM`, which defaults to `windows` precisely so those two need not
  set it, and the exe runs under Proton. amd64 only — an arm64 image would be
  meaningless.
- **Linux depot, and it must be asked for (Dragonwilds only).** App 4019830
  publishes both. `games/dragonwilds/Dockerfile` sets `STEAM_DEPOT_PLATFORM=linux`;
  without it SteamCMD installs 4.8GB of Windows binaries perfectly cleanly and
  the Linux launch target is simply absent, which reads as a failed download
  rather than a wrong one.
- **That variable is `STEAM_DEPOT_PLATFORM`, never `STEAM_PLATFORM`.**
  `STEAM_PLATFORM` belongs to SteamCMD's own `steamcmd.sh`, which uses it to find
  its binary (`: "${STEAM_PLATFORM:=linux32}"`, then
  `STEAMEXE="${STEAMROOT}/$STEAM_PLATFORM/${STEAMCMD}"`). An image exporting
  `STEAM_PLATFORM=linux` makes SteamCMD look for
  `/serverdata/steamcmd/linux/steamcmd`, fail to find it and exit 1 before doing
  anything — every boot, with one easily-missed line as the only symptom. A unit
  test asserts no image reintroduces the name.
- **`ServerAdminPassword` must be the last `?` argument (ASA).** Anything after
  it is swallowed into the password value. See the ordering in
  `games/ark-survival-ascended/scripts/start-server.sh`.
- **Dash flags, not query params (ASA).** `-WinLiveMaxPlayers=` and `-port=`
  are the real settings; `?MaxPlayers=` and `?Port=` are silently ignored by
  ASA.
- **The config seed is write-once (ASA).** `GameUserSettings.ini` is written
  only when absent. Never make the container rewrite a file the user may have
  edited. Terraria's `serverconfig.txt` is the opposite by design — it is
  regenerated every boot, since Terraria only reads it at startup.
- **`HOME` is repointed at `<serverfiles>/home` (ASA).** `gosu` sets it from
  passwd, so `start-server.sh` overrides it after the privilege drop, not via
  `ENV`. SteamCMD's `depotcache` lives there and holds the manifest an
  incremental update diffs against. On the default `/home/steam` it is lost
  whenever the container is recreated, and the next update dies with
  `Access Denied` on the delta-source manifest because Steam does not issue
  request codes for superseded manifests. Do not move it back.
- **V Rising needs a display (V Rising only).** `VRisingServer.exe` will not
  start without one, headless or not, so the launch goes through `xvfb-run`. Both
  reference containers upstream do the same. Do not "simplify" it away.
- **V Rising's config is never rewritten (V Rising only).** Every
  `ServerHostSettings.json` field has a command-line override that beats the file,
  so the template's fields are passed as launch flags and the seeded JSON is left
  alone forever. Do not "fix" this by making the container write JSON — that is
  what would destroy a user's hand edits.
- **V Rising saves on SIGINT, not SIGTERM (V Rising only).** SIGTERM kills it in
  under half a second with no save at all; SIGINT saves in about a second and exits
  cleanly. Measured, three times, under GE-Proton10-34. Containers elsewhere use
  SIGTERM under plain `wine64`, which behaves differently — do not "fix" this back.
  RCON is not on the shutdown path: its `shutdown` command does save but schedules
  minutes out. The signal must reach `VRisingServer.exe` itself, identified by
  `/proc/<pid>/comm` against the 15-character truncation `VRisingServer.e`. Both
  wrappers — `xvfb-run` and the Proton launcher — carry the exe name on their
  command lines, so `pkill -f` hits them too, and signalling a wrapper orphans the
  game while the log reports a clean stop.
- **Graceful shutdown depends on RCON (ASA).** `SaveWorld` then `DoExit` over
  RCON, then a timed wait, then kill the wine prefix. A hard kill loses world
  state. Terraria has no RCON; its shutdown writes `exit` into a FIFO console
  instead (`games/terraria/scripts/console.sh`).
- **Dragonwilds rewrites managed ini keys every boot (Dragonwilds only).** It is
  neither ASA's write-once seed nor Terraria's full regeneration. Nothing in that
  game has a command-line override, so the ini is the only channel; but the
  server writes to that file itself (it generates and persists a `ServerGuid`,
  and fills in any missing `ServerName`, `AdminPassword` or `DefaultWorldName`).
  So `set_ini_key()` replaces the five keys the template owns and preserves every
  other byte. Regenerating would destroy the `ServerGuid`; seeding write-once
  would make every template field silently dead after first boot.
- **`set_ini_key()` passes its value through the environment, not `awk -v`
  (Dragonwilds only).** `-v` runs escape processing over the assignment, so
  `-v value='a\fun'` hands awk a formfeed and silently eats two characters. An
  admin password is exactly the sort of value that contains a backslash. Caught
  by a unit test; do not "tidy" it back onto `-v`.
- **Dragonwilds launches the ELF, not `RSDragonwildsServer.sh` (Dragonwilds
  only).** That wrapper does not `exec` — it runs
  `RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping` as a child —
  so a signal sent to it never reaches the game and the shutdown handler would
  report a clean save over a hard kill. Going straight to the binary makes `$!`
  the server and avoids the whole `/proc/<pid>/comm` problem V Rising has.
- **Dragonwilds refuses to start with an empty `OWNER_ID` (Dragonwilds only).**
  The server does not: with `OwnerId` blank it starts, binds 7777/udp and turns
  away every player, so the container looks healthy and serves nobody. Refusing
  is the better failure. Do not "fix" this into a warning.
- **The server aborts under root (Dragonwilds only).** Unreal prints `Refusing to
  run with the root privileges` and exits 134. `start.sh`'s `gosu` drop already
  handles it; a `UID` of 0 would not be.
- **Saves are `Saved/SaveGames/`, capital G (Dragonwilds only).** The game's wiki
  writes `Savegames`. A case-mismatched path would be created as a second empty
  directory beside the real one, silently.
- **Two different Steam ids, and both are required (Valheim only).** `GAME_ID` is
  `896660`, the dedicated server app SteamCMD installs. `SteamAppId` exported
  into the server's own environment is `892970`, the *client* app id, and the
  server does not start without it. The depot's own `start_server.sh` exports
  exactly that, and `steam_appid.txt` beside the binary contains it too. Do not
  "tidy" the two into one number.
- **Linux depot, and it must be asked for (Valheim too).** App 896660 publishes
  both platforms, so `games/valheim/Dockerfile` sets
  `STEAM_DEPOT_PLATFORM=linux`. Same silent failure as Dragonwilds: the wrong
  depot installs cleanly and the launch target is simply absent.
- **Valheim launches the ELF, not `start_server.sh` (Valheim only).** That
  wrapper does not `exec` — its last line restores `LD_LIBRARY_PATH`, which can
  only run after the server has already exited — so a signal sent to it never
  reaches the game. Steam also overwrites that file on every update, which its
  own comment block warns about. Going straight to `valheim_server.x86_64` makes
  `$!` the server. Note `pkill -x` cannot be used on this game as a fallback:
  the name is 20 characters and `pkill` refuses anything over 15.
- **SIGINT, not SIGTERM (Valheim), even though both now save.** Measured
  2026-09-22 on buildid 25390671: SIGINT saved and the whole stop took 4.2s;
  SIGTERM sent straight to the game also saved. The widely repeated claim that
  SIGTERM loses the world is out of date — it came from an Iron Gate tracker
  entry, "dedicated server does not save world on SIGTERM", that is evidently
  fixed. The runner sends INT anyway: it is what Iron Gate's guide documents
  (stop with CTRL+C), it is what every established container sends, and it costs
  nothing. Do not switch to TERM on the strength of the measurement — that would
  be depending on a fix staying fixed.
- **Valheim's `STOP_TIMEOUT` of `120` is a real save window (Valheim only).**
  Unlike Dragonwilds' teardown headroom, this is the *only* save path the
  container has: no RCON, no stdin console, no remote save command. The 4.2s
  measured above was an empty world and is the floor, not the target — the save
  grows with the world, and the number also has to cover a pre-1.0 world's
  one-way format conversion, which takes minutes and corrupts the world if
  interrupted.
- **Valheim has no config file, and nothing here may start writing one.**
  `-savedir` relocates the entire persistent state — `worlds_local/` plus
  `adminlist.txt`, `bannedlist.txt` and `permittedlist.txt` — into one directory,
  and every other setting is a launch flag. That is why this runner has no
  seeding, no regeneration and no ini merging. Confirmed against a real boot.
- **Modifier flags are emitted preset, then modifier, then setkey (Valheim
  only).** A preset resets every slider it covers and the server parses left to
  right, so a `-modifier` before a `-preset` is silently discarded.
  `build_modifier_flags()` fixes the order so a user cannot get it wrong, and an
  unrecognised name or value is fatal because the server's own response is to
  ignore it and hand you a normal world.
- **`in_list()` word-splits on `IFS` (Valheim only).** Splitting the template's
  comma-separated fields with a function-scoped `local IFS=','` leaves `IFS` set
  for everything the function goes on to call, which collapses `in_list`'s
  space-separated haystack into one token and rejects every valid value. Caught
  on the first real boot. The fields are split with `IFS=',' read -ra`, which
  scopes `IFS` to the read itself. Do not "tidy" it back.
- **Valheim refuses to start on an unwritable save directory (Valheim only).**
  The server does not: it logs one `UnauthorizedAccessException`, keeps running
  and serves a world out of memory that it can never write, so the container
  looks healthy and loses everything at the next restart. `start.sh`'s ownership
  pass covers the ordinary case; the probe in `check_save_dir_writable()` covers
  a read-only mount or a mismatched `UID`. Its redirect is wrapped in a subshell
  on purpose - a bare `: > file 2>/dev/null` lets the shell print its own
  "Permission denied" on *its* stderr before the command runs, right above the
  explanation. Do not "fix" this into a warning.
- **Worlds live in `worlds_local/`, never `worlds/` (Valheim only).** The
  dedicated server does not read `worlds/` at all, and a world left there
  produces no error — it generates a fresh world and boots looking healthy. The
  runner warns when it finds something world-shaped in the legacy directory.
- **No `libsdl2` in the Valheim image.** App 896660 ships Iron Gate's own
  `docker/Dockerfile` inside the depot, whose entire dependency list is `curl`,
  `libatomic1`, `libpulse-dev` and `libpulse0`. Two widely used Valheim
  containers install SDL anyway; `ldd` against a real install shows neither
  `valheim_server.x86_64` nor `UnityPlayer.so` links against it.
- **Valheim's ports are measured, and 2458 is not one the server binds.** Read
  from `/proc/net/udp` on a real boot: crossplay off binds `GAME_PORT` and
  `GAME_PORT+1`; crossplay on binds `GAME_PORT+1` *only*, which is why a
  crossplay server needs no port forwarding. `GAME_PORT+2` was never bound in
  either mode, and the shipped manual says "the default Port Range that the
  Server uses is 2456-2457". It is published only because the depot's
  `start_server.sh` comment tells users to forward 2456-2458.
- **Read the manual out of the depot, not the web (Valheim).** App 896660 ships
  `Valheim Dedicated Server Manual.pdf` next to the binary, and it is not
  published anywhere online — it is the authority on the flag table, the port
  range, the required packages and the permission files. Extract it with
  `pdftotext` from an installed copy before trusting a web source on any of
  those. It settled two claims that community sources had wrong.
- **Do not validate or rewrite admin IDs (Valheim only).** The manual calls the
  value a Platform User ID, shapes it `[Platform]_[User ID]`, says it is case
  sensitive, and says to take it from the server log or the in-game F2 panel.
  Field reports after 1.0 show a `V_` prefix where the manual's example shows
  `Steam_`, and nobody has documented the change. A wrong ID fails *silently* -
  it is accepted into the file and simply never grants admin - so the container
  passes the three permission files through untouched and the docs tell users to
  copy the value verbatim rather than naming a prefix.
