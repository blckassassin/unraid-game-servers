# Design: RuneScape: Dragonwilds dedicated server

Date: 2026-09-14
Slug: `dragonwilds`
Status: implemented and smoke-tested

## Goal

A fourth game in this monorepo: a RuneScape: Dragonwilds dedicated server
container for Unraid, published as `ferment9348/dragonwilds` and listed in
Community Applications alongside the other three.

Reference material is the game's own wiki page,
https://dragonwilds.runescape.wiki/w/Dedicated_Servers/Linux, treated as a
guideline. It documents a bare-metal systemd install; three of the things it
prescribes are wrong for a container and are handled differently below.

## Verified facts

Read straight out of Steam with `app_info_print 4019830` on 2026-09-14:

```
"name"      "RuneScape: Dragonwilds Dedicated Server"
"type"      "Tool"
"parent"    "1374490"
"oslist"    "windows,linux"
"osarch"    "64"
"freetodownload"  "1"

launch/1: executable "RSDragonwildsServer.sh"   oslist linux
depot 3501791  oslist linux   size 5356955523   download 1636107216
depot 4019831  oslist windows size 4812044577   download 1597722880
branch public  buildid 24574222
```

So, in order of how much they change the design:

- **There is a native Linux depot.** This is the first SteamCMD game here that
  needs no Proton at all — ASA and V Rising both exist only as Windows depots.
  No `proton.sh`, no wine prefix, no Xvfb, no `lib_burst_generated.dll`
  workaround, no `steamclient.so` bridge.
- **About 5.0 GB installed, 1.5 GB to download.** Heavier than Terraria's 46 MB,
  lighter than ASA's ~13 GB. Too heavy for a CI end-to-end test; this stays a
  manual smoke check like ASA and V Rising.
- **`freetodownload` and anonymous login work.** No Steam account, so `USERNAME`
  and `PASSWRD` exist only for parity with the other templates.
- **It is a `Tool` whose parent is 1374490.** Nothing depends on this; noted so
  nobody later "fixes" `GAME_ID` to the parent app.

From the wiki:

- Launch line is `RSDragonwildsServer.sh -log -NewConsole -Port=7777`.
- Game traffic is **UDP 7777**, and that is the only port it names.
- Config is `RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini`, and it
  does not exist until the server has run once.
- Mandatory config keys, without which the server will not start: `OwnerId`,
  `ServerName`, `DefaultWorldName`, `AdminPassword`. `WorldPassword` is optional.
- `OwnerId` is the operator's in-game Player ID, from the bottom of the in-game
  Settings menu. There is no way for the container to derive it.
- Editing the ini while the server runs loses the edit; the server rewrites it.
- Saves are `RSDragonwilds/Saved/Savegames/`. The newest `.sav` is loaded; an
  empty folder means a new world is generated.
- Ctrl+C is how the wiki stops the first manual run, i.e. **SIGINT**.

Already-confirmed inherited behaviour: the very first `app_update` on a cold
SteamCMD directory failed with `Failed to install app '4019830' (Missing
configuration)` and installed nothing, then succeeded on the next pass. That is
the intermittent first-run bootstrap `update_game()` in `shared/scripts/steamcmd.sh`
already retries for, so this game inherits the fix without any new code.

### Verified by booting it, 2026-09-14

Every item below was settled by installing the depot and running the server, not
by reading about it. Several contradict the wiki.

1. **The ini's real shape.** A first run with no config generates:

   ```ini
   ;METADATA=(Diff=true, UseCommands=true)
   [/Script/Dominion.DedicatedServerSettings]
   AdminPassword=YXPHC6S6YR8JW8KA
   OwnerId=
   ServerGuid=CE0871C643CA4D38A7F89D83DAB8C6B1
   ServerName=Server-44208
   WorldPassword=
   DefaultWorldName=World-35188
   ```

   One section, flat keys. A hand-written ini IS honoured — the server reads it
   and only fills in what is missing.

2. **The server writes to that file itself**, which settles the config strategy:

   ```
   LogDomServerSettings: Generated missing DefaultWorldName: World-35188
   LogDomServerSettings: Generated missing AdminPassword: YXPHC6S6YR8JW8KA
   LogDomServerSettings: Generated missing ServerName: Server-44208
   LogDomServerSettings: Generated missing ServerGuid: CE0871C643CA4D38A7F89D83DAB8C6B1
   ```

   `ServerGuid` in particular is generated once and must survive. Regenerating the
   file would destroy it.

3. **An empty `OwnerId` does not stop the server.** It prints

   ```
   The [OwnerId] for this server is empty.
   An OwnerId is required for normal Server operation.
   Update the config and restart to continue
   ```

   and then carries on initialising, binds 7777/udp and sits there serving
   nobody. This is why the runner refuses to start rather than warning: a
   container that looks healthy and turns away every player is the worse outcome.

4. **The server refuses to run as root.** `Refusing to run with the root
   privileges`, then an abort with exit 134. `start.sh`'s existing `gosu` drop
   already covers it, but a `UID` of 0 would not.

5. **`RSDragonwildsServer.sh` does not `exec`.** It is four lines: resolve its own
   directory, `chmod +x` the ELF, then run
   `RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping RSDragonwilds "$@"`
   as a child. Signalling the wrapper would therefore leave the game running.
   The runner launches the ELF directly instead, which makes `$!` the server and
   sidesteps the entire `/proc/<pid>/comm` problem V Rising has.

6. **Only UDP 7777 is bound.** `ss -lunp` against a running server shows exactly
   one socket, `0.0.0.0:7777`, and nothing on TCP. There is no Steam query port
   because listing goes through EOS — the binary ships `libEOSSDK-Linux-Shipping.so`
   and the log shows `RedpointEOSNetDriver` doing the listening.

7. **Saves are `Saved/SaveGames/`, with a capital G**, not `Savegames` as the wiki
   writes it, and the file is `<DefaultWorldName>.sav`.

8. **RAM**: about 510MB at engine init, about 1GB with a world loaded. 4GB is a
   sane floor for the template's `<Requires>`.

9. **`-log` puts the engine log on stdout**, so this runner needs no log tail.
   Startup is a few thousand lines and then it goes quiet — nowhere near the
   volume that forced Terraria's collapsing filter.

10. **SteamCMD's first-run failure reproduces here.** The very first `app_update`
    on a cold steamcmd directory failed with `Failed to install app '4019830'
    (Missing configuration)` having installed nothing, then succeeded on the next
    pass. That is exactly what `update_game()` already retries for, so this game
    inherits the fix with no new code.

### Shutdown and saving: settled

Measured over a 20 minute run on 2026-09-14, then corroborated against the
server binary's own debug symbols.

**Autosave runs every 300 seconds, exactly**, whether or not a player is
connected:

```
AUTOSAVE at +300s / +600s / +900s / +1200s     each 300s apart to the second
```

**Neither SIGINT nor SIGTERM saves.** Pre-shutdown and post-shutdown the save
file is byte-identical - same mtime, same size - and the server exits in about
two seconds. The two signals are otherwise indistinguishable: their shutdown
sequences diff clean apart from the return code (130 against 143), and both are a
full orderly Unreal teardown ending `RequestExit(bForce=false)`.

The binary explains why. There IS a save-on-exit path,
`UDominionNetworkSubsystem::RequestGameExit`, a staged sequence
(`_Start`, `_ServerPersistenceResult`, `_DestroySession`, `_SessionDestroyed`,
`_Complete`) whose second stage logs `RequestGameExit : Server saving World and
Player state for %s`. But it is `exec`-exposed - Blueprint-callable, driven from
the game's UI - so it is the **in-game quit flow**. A signal never reaches it; a
signal lands on `FUnixPlatformMisc::RequestExit`, a different function that does
not touch persistence.

Save triggers on `ADominionGameMode` are all player and world events:
`PostLogin`, `PreLogout`, `StartPlayerSleep`, `PlayerSleepDelayComplete`,
`RequestSaveGame`, `ScheduleSaveGame`, gated by `CanSave`. There is no `EndPlay`
or exit hook on the game mode at all.

**So the exposure is bounded at five minutes** and there is nothing a container
can do to shorten it: no RCON, no stdin console (probed directly - `help`,
`Save`, `SaveGame`, `SaveWorld`, `DomSave`, `Dominion.Save`, `stat fps` and
`quit` were all ignored, and `quit` did not stop the server), and no save
command. Players quitting through the game menu before a stop lose nothing.

`STOP_TIMEOUT` was therefore reduced from 90 to 30: it is headroom for a ~2s
engine teardown, not a save window, and the matching stop-grace guidance dropped
from 105s to 45s.

Two earlier readings in this document were wrong and are corrected here. The
first was that an idle server proved nothing because nothing was dirty - autosave
fires regardless, so the idle test was simply too short. The second was that
`CheckShouldPauseGameNoClient` and `Requested pausing as we have no player
connected` meant an empty server accrues nothing worth saving; the pause is real
but autosaves continue through it, so it protects nothing.

### Still open

- Whether a dirty world is flushed on shutdown (above). Needs a real client.
- Whether the server has an autosave interval. Four minutes idle produced no
  periodic save, which proves nothing either way about a world with players in it.
Closed, negatively: **the server accepts no console commands on stdin.** Probed
with a held FIFO on the server's stdin against a running world — `help`,
`stat fps`, `SaveGame`, `Save`, `SaveWorld`, `DomSave`, `Dominion.Save` and
`quit`. Nothing was acknowledged in the log, nothing was written, and `quit` did
not stop the server. So Terraria's FIFO-console pattern is not available here,
there is no way to ask for a save before stopping, and the signal is the only
shutdown channel there is. Do not spend time re-testing this.

## 1. Shared code: one change, `STEAM_DEPOT_PLATFORM`

`run_steamcmd()` in `shared/scripts/steamcmd.sh` hardcodes
`+@sSteamCmdForcePlatformType windows`, which was right when every SteamCMD game
here was a Windows depot run under Proton. Given that flag, Dragonwilds would
install the wrong 4.8 GB of Windows binaries.

```bash
local platform="${STEAM_DEPOT_PLATFORM:-windows}"
local args=( "+@sSteamCmdForcePlatformType" "${platform}" ... )
```

The default stays `windows` so neither existing Dockerfile changes, and the
Dragonwilds image sets `STEAM_DEPOT_PLATFORM=linux`. Two unit assertions cover both
branches, because the failure mode is silent: the wrong depot installs cleanly
and the launch script is simply absent afterwards.

Nothing else is shared. `proton.sh` is not sourced. `rcon.py` is not used —
Dragonwilds has no RCON.

## 2. `games/dragonwilds/`

```
Dockerfile              debian:trixie-slim, SteamCMD, no Proton
docker-compose.yml      local testing, uid/gid 1000
scripts/start-server.sh the runner
docs/dockerhub.md       Docker Hub long description
README.md               the game's guide
```

Base image is `debian:trixie-slim` to match the others. The GLIBC 2.38 reason
that forced trixie on the Proton images does not apply here, but there is no
reason to diverge. Packages: `ca-certificates curl tar procps gosu tini
lib32gcc-s1 locales` — `lib32gcc-s1` for SteamCMD itself, which is a 32-bit
binary, not for the server, which is 64-bit.

`STEAMCMD_DIR` and `SERVER_DIR` are set and `PROTON_DIR` is not, which is
already how `shared/scripts/start.sh` distinguishes a Proton game from a
non-Proton one.

Saves and config both live under `SERVER_DIR`, so there is one volume for game
files and one for SteamCMD, exactly like ASA.

## 3. Config: managed keys, rewritten every boot

The decision that shapes the runner. Dragonwilds has no command-line override
for any of its mandatory settings — unlike V Rising, where every setting has a
flag that beats the file, which is what lets that container never write config at
all. Here the ini is the only channel.

The three patterns already in this repo, and why each is wrong here:

- ASA seeds **write-once**. Right for ASA, because the server rewrites
  `GameUserSettings.ini` itself on shutdown. Wrong here: changing Server Name in
  the Unraid template would silently do nothing forever after first boot.
- Terraria **regenerates the whole file** every boot. Safe there because Terraria
  only ever reads `serverconfig.txt`. Wrong here: it would destroy the
  `ServerGuid` and admin list the server writes into its own ini.
- V Rising **never writes config**, passing everything as flags. Not available:
  there are no flags.

So: **rewrite only the managed keys, in place, on every boot.**

Managed keys, all from template fields:

| ini key            | env var         |
| ------------------ | --------------- |
| `OwnerId`          | `OWNER_ID`      |
| `ServerName`       | `SERVER_NAME`   |
| `DefaultWorldName` | `WORLD_NAME`    |
| `AdminPassword`    | `SRV_ADMIN_PWD` |
| `WorldPassword`    | `SRV_PWD`       |

Every other key in the file — `ServerGuid`, the admin list, anything a future
build adds, anything the operator hand-adds — is preserved byte for byte.

The mechanism is one function, `set_ini_key <file> <section> <key> <value>`:

- Replaces the value if the key already exists in the target section.
- Appends the key at the end of that section if the section exists without it.
- Creates the section and the key if neither exists.
- Leaves every other line untouched.

It is a single `awk` pass into a temp file, then a rename. It is also the only
non-trivial logic in this container, so it is where the unit tests go: key
present, key absent from an existing section, section absent entirely, empty
file, a value containing spaces and `=`, and an unmanaged key surviving all of
the above.

The documented consequence, which goes in the README and the template: a hand
edit to one of those five keys is overwritten on the next start, because the
template field is the source of truth for them. Everything else in the file is
yours.

Editing is done while the server is stopped, which the runner guarantees by
writing before launch and never touching the file again afterwards.

## 4. `OWNER_ID` is mandatory and cannot be defaulted

The server will not start without it, and the container cannot know it. Left
empty, the outcome without a guard is an Unreal process that exits immediately
and an Unraid `--restart unless-stopped` that hammers it forever — the same
silent-boot-loop failure class this repo has already been bitten by twice.

So the runner checks it explicitly and refuses, with a message that says where
to find the value:

```
---OWNER_ID is not set, and the server will not start without it---
---It is your in-game Player ID, at the bottom of the in-game Settings menu---
---There is a copy button next to it. Paste it into the Owner ID field.---
```

The check runs **after** the SteamCMD install, not before, for two reasons: the
5 GB download finishes while the operator goes to look their ID up, and the
message is then the last thing in the log rather than buried above an install.

## 5. Launch

```
RSDragonwildsServer.sh -log -Port=${GAME_PORT} ${GAME_PARAMS_EXTRA}
```

`-log` is what makes an Unreal server write to stdout, which is the whole reason
this runner needs no log-file tail — contrast ASA, which tails an engine log, and
Terraria, which needs a file plus a collapsing filter. If the boot shows Unreal's
output is heavy enough to matter, the Terraria treatment is the known remedy;
that is a measurement, not a prediction.

`-NewConsole` from the wiki's line is dropped unless the boot shows it does
something on Linux. It reads as a Windows console flag.

`GAME_PARAMS_EXTRA` is appended verbatim, same as V Rising, as the escape hatch
for anything without a field.

## 6. Shutdown

SIGINT, on the strength of the wiki using Ctrl+C, then a wait bounded by
`STOP_TIMEOUT`, then SIGKILL. Which signal actually saves is measured on the
smoke boot — both are tried, and the README records the finding the way V
Rising's does.

If `RSDragonwildsServer.sh` forks rather than `exec`s, the signal has to reach
the ELF and not the wrapper, and the V Rising runner's `/proc/<pid>/comm`
approach is the precedent to copy. If it `exec`s, `$!` is the server and the
handler is five lines.

`STOP_TIMEOUT` defaults to `90`. Unreal world saves on a survival map are not
quick, and unlike Terraria there is no reason to squeeze under Docker's 10 s
default grace — the template and compose file both raise the outer grace, and the
README says to.

No RCON, so no second shutdown path and no `rcon-cli.sh` in this image.

## 7. Ports

| Port   | Proto | What for                                 |
| ------ | ----- | ---------------------------------------- |
| `7777` | UDP   | Game traffic. The only one the wiki names. |

7777/udp is also ASA's game port, so the two containers collide on a default
Unraid box. The README and template say so and name Dragonwilds as the one to
move, since ASA's port is the more entrenched of the two.

As with the other games, moving the port means three numbers agreeing: container
port, host port, and `GAME_PORT`. Anything the smoke boot reveals bound beyond
7777 gets added to this table and to `EXPOSE`.

## 8. Template, CA, docs, icon

- `templates/dragonwilds.xml`, following `v-rising.xml` field for field. Owner ID
  is a required, unmasked field with the in-game instructions in its description.
  Admin Password and World Password are masked.
- `ca_profile.xml` — the profile says "Three servers are maintained here" and
  describes the Proton/native split. It becomes four, and Dragonwilds joins
  Terraria on the native-Linux side. The CA registration name itself is pinned to
  the old repository name and is not touched.
- `dragonwilds.png` / `dragonwilds.svg` at the repo root, generated by a new
  `tools/icongen/dragonwilds.py` reusing `build.py`'s writers, as `terraria.py`
  and `vrising.py` already do.
- `games/dragonwilds/README.md` and `docs/dockerhub.md`.
- Root `README.md` is ASA's guide and is not touched, per the existing constraint.
- `AGENTS.md` says "Three games live here today" and describes two categories.
  It becomes four games in three categories: Proton (ASA, V Rising), native Linux
  with SteamCMD (Dragonwilds), native Linux without SteamCMD (Terraria).

## 9. CI

One entry in the `ALL` list in `.github/workflows/build.yml`, with `slug`,
`title`, `description` and `tagline`. No new job and no e2e step — the install is
too heavy, as for ASA and V Rising.

`tests/unit.sh` has a hardcoded `for slug in ark-survival-ascended terraria
v-rising` loop for the template-target check. Dragonwilds is added there, plus
the tag-extraction assertions and the CI-list assertion each game gets.

## 10. Testing

- `shellcheck --severity=warning` over the new runner, with the rest.
- `bash tests/unit.sh`, extended with: `set_ini_key()`'s six cases, the
  `STEAM_DEPOT_PLATFORM` default and override, Dragonwilds' tag extraction, its
  presence in the CI list, and its template targets existing in its Dockerfile.
- No CI end-to-end test.
- A manual smoke boot that settles every item in "Not verified" above and is what
  gates the first `dragonwilds/v*` tag.

## 11. Deliberately not building

- **RCON or any console.** The game has none. A FIFO console like Terraria's
  needs a server that reads stdin commands; nothing suggests this one does.
- **A world-reset switch.** `rm -rf Savegames/*` is the wiki's own answer and it
  is one command over the share. A container flag that deletes worlds is a
  footgun with no upside.
- **Backups.** The wiki's systemd unit backs the ini up around updates because
  SteamCMD `validate` can clobber it. Worth re-examining only if the smoke boot
  shows `validate` actually does that here; `VALIDATE` is off by default, and the
  runner rewrites the managed keys after the install runs, so the ordering
  already covers the common case.
- **A second config file.** Only `DedicatedServer.ini` is documented.

## 12. One collision worth its own heading

`run_steamcmd()`'s new variable is `STEAM_DEPOT_PLATFORM`, not the obvious
`STEAM_PLATFORM`. That name is already SteamCMD's:

```sh
: "${STEAM_PLATFORM:=linux32}"
STEAMEXE="${STEAMROOT}/$STEAM_PLATFORM/${STEAMCMD}"
```

The first version of this work used `STEAM_PLATFORM`, and the container therefore
sent SteamCMD looking for `/serverdata/steamcmd/linux/steamcmd`, which does not
exist. SteamCMD exited 1 before doing anything, on every boot, leaving one line
buried in the startup noise:

```
Couldn't find steamcmd at /serverdata/steamcmd/linux/steamcmd, exiting
```

A fresh install would never have downloaded the game at all. It was invisible
during development only because the depot was already on disk from an earlier
manual install, so the runner's "continuing with the files already on disk"
branch covered for it. Found by building the image and running it; a unit test
now asserts no image reintroduces the name.

## 13. Smoke test, 2026-09-14

Against the built image, with the depot already installed and a fresh SteamCMD
directory:

- SteamCMD resolves `linux32/steamcmd`, reports
  `"@sSteamCmdForcePlatformType" = "linux"`, and `App '4019830' already up to date`.
- With `OWNER_ID` empty the container refuses to start and prints the guard.
- With it set, the ini comes out exactly right. Given an admin password of
  `pa$$ & word\test` — every character that would break a `sed`-based
  implementation — and a hand-added unmanaged key:

  ```ini
  ;METADATA=(Diff=true, UseCommands=true)
  [/Script/Dominion.DedicatedServerSettings]
  AdminPassword=pa$$ & word\test
  OwnerId=0123456789ABCDEF0123456789ABCDEF
  ServerGuid=CE0871C643CA4D38A7F89D83DAB8C6B1
  ServerName=Smoke Test Server
  WorldPassword=
  DefaultWorldName=E2E
  SomeFutureKey=keepme
  ```

  The password is verbatim, `ServerGuid` survived, and `SomeFutureKey` survived.
- The world loads, and `podman stop` produces `---Shutdown requested---`, a full
  orderly engine teardown ending `RequestExit(bForce=false, ReturnCode=130)`,
  `---Server stopped---`, and container exit 0 in about two seconds.

One cosmetic note: the runner's own `---` messages can interleave mid-line with
the server's stdout, because both write to the same unbuffered stream. Terraria's
file-plus-reader arrangement would avoid it and is explicitly worse for every
other reason, so this stays.

## 14. Blocking before the first `dragonwilds/v*` tag

The code is done and tested as far as this host can take it. What is left needs a
real player:

1. Confirm on a live server that a world with unsaved changes IS flushed when the
   container stops. This is the one open risk, it is documented in the runner and
   in section 6, and it cannot be settled without a client connecting.
2. Confirm a real `OwnerId` is accepted and that the owner gets owner privileges
   in game — the smoke test used a well-formed but fictional ID, which the server
   accepted without resolving it (`OwnerGuid[] OwnerName[]` in the log).
3. Confirm the server appears in the in-game browser through EOS.

If (1) turns out badly there is no clean remedy available in the container: there
is no RCON, no stdin console, and no save command of any kind, so the only lever
left would be raising the autosave frequency if the game ever exposes one.

## 15. Independent research, reconciled 2026-09-14

A parallel documentation sweep (game wiki, three existing community containers,
four hosting providers) was reconciled against the boots above. It agreed on
every point the boots had settled — the `[/Script/Dominion.DedicatedServerSettings]`
header, the `LinuxServer` path, 7777/udp alone, no RCON, and the
`-Linux-Shipping` binary being what the other containers exec directly too.

It corrected or added four things, now reflected in the docs and template:

- **`DefaultWorldName` is probably what players search for**, not `ServerName`,
  case-sensitive, under Worlds → Public. Console players cannot enter an IP at
  all. Not verifiable from the server side — the published session carries both
  names (`Vip_ServerName` and `SlotName`) — so the docs say "probably" and tell
  people what to try if players cannot find them.
- **Player cap is 6**, and it is not in `DedicatedServer.ini` — it lives in the
  engine's game config. Two containers pass
  `-ini:Game:[/Script/Engine.GameSession]:MaxPlayers=N`; whether a value above 6
  does anything is unverified by them and by us. Documented via
  `GAME_PARAMS_EXTRA` rather than given a field, since there is no known-good
  value to offer.
- **RAM is roughly 2GB plus 1GB per player**, so 8GB for a full server. The
  template's `<Requires>` said 4GB and now says this.
- **Save-on-shutdown is undocumented everywhere**, and all three existing
  containers simply assume SIGTERM works. That independently confirms the open
  question in section 6 is a real gap in the world's knowledge rather than a gap
  in ours, and it is why the template, README and Docker Hub page now decline to
  promise a save rather than repeating the assumption.

Three of its claims are contradicted by direct measurement here and were not
adopted: the install is **5.0GB**, not the ~10GB the hosting docs quote;
`crashpad_handler` already carries its executable bit in the current depot; and
the server's own generated ini uses `;METADATA=(Diff=true, UseCommands=true)`
rather than a `[SectionsToSave]` block, so that block is optional. `set_ini_key()`
preserves either.

One piece of prior art worth knowing before any CA submission:
**`hunterl31/dragonwilds-server`** is already an Unraid container with its own CA
template and profile. That is a packaging decision, not a technical one.
