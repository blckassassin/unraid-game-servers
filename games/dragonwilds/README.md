# RuneScape: Dragonwilds — dedicated server for Unraid

Unlike the [ARK](../../README.md) and [V Rising](../v-rising/README.md) containers
in this repo, Dragonwilds ships a real Linux server binary. There is no Proton,
no wine and no virtual display here — SteamCMD pulls the Linux depot and the
server runs natively.

First boot downloads about 1.5GB and settles at about 5GB on disk, then generates
a world, which takes a few minutes.

## You need your Owner ID before this will run

The server requires your in-game Player ID and there is no way for a container to
work it out. Open RuneScape: Dragonwilds, go to **Settings**, and it is at the
bottom of that menu with a copy button next to it. Paste it into `OWNER_ID`.

This container **refuses to start** without one. That is deliberate, and it is not
what the server itself does: with `OwnerId` empty the server starts anyway, binds
its port, and turns away every player, printing

```
The [OwnerId] for this server is empty.
An OwnerId is required for normal Server operation.
Update the config and restart to continue
```

into a log nobody reads, because from the outside the container looks perfectly
healthy. A container that stops and says why is the better failure.

## Get the image

```sh
docker pull ferment9348/dragonwilds:latest
```

Or build it yourself, from the repo root:

```sh
docker build -f games/dragonwilds/Dockerfile -t dragonwilds .
```

## Install on Unraid

It is in Community Applications as **RuneScape-Dragonwilds**. Everything below
maps to a field in that template; the variable names are what you would use with
`docker run`.

## Ports

| Port   | Protocol | What for                                            |
| ------ | -------- | --------------------------------------------------- |
| `7777` | UDP      | Game traffic. The only port the server binds.        |

There is no separate query port — 7777/udp is the whole of it, verified with
`ss -lunp` against a running server, which shows exactly one socket. Discovery is
not the Steam master server; the server registers itself and players find it in
the in-game browser. A second instance on the same box conventionally uses 7778.

**If you also run the ARK container on this box, its game port is 7777 too** and
Docker refuses to start the second container. Move one of them.

To change the port, three numbers have to agree: the container port, the host
port, and `GAME_PORT`. Docker cannot tell the server what its host port is, so if
`GAME_PORT` differs from the container port nothing reaches the server, and if it
differs from the host port the log reports a number players cannot use.

## Configuration

| Variable            | Default              | What it does                                   |
| ------------------- | -------------------- | ---------------------------------------------- |
| `OWNER_ID`          | empty                | **Required.** Your in-game Player ID.          |
| `SERVER_NAME`       | `Dragonwilds Server` | The server's own name. See below.              |
| `WORLD_NAME`        | `Standard`           | World and save-file name, and probably what players type to find you. See below. |
| `SRV_ADMIN_PWD`     | empty                | Admin password. See below.                     |
| `SRV_PWD`           | empty                | Join password. Blank means open.               |
| `GAME_PORT`         | `7777`               | The port the server binds.                     |
| `GAME_PARAMS_EXTRA` | empty                | Appended to the launch line verbatim.          |
| `STOP_TIMEOUT`      | `30`                 | Seconds to wait for the engine to exit. Not a save window — see below. |
| `VALIDATE`          | empty                | `true` makes SteamCMD verify every file.       |

### How your config file is treated

Dragonwilds keeps everything in one file:

```
RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini
```

and unlike V Rising, none of its settings have a command-line equivalent. The ini
is the only channel, so the container writes to it.

It writes **five keys and nothing else**, on every start:

| ini key            | comes from      |
| ------------------ | --------------- |
| `OwnerId`          | `OWNER_ID`      |
| `ServerName`       | `SERVER_NAME`   |
| `DefaultWorldName` | `WORLD_NAME`    |
| `AdminPassword`    | `SRV_ADMIN_PWD` |
| `WorldPassword`    | `SRV_PWD`       |

Every other line in that file is left exactly as it was — including the
`ServerGuid` the server generates for itself on first boot, the `;METADATA`
header, and anything a future game build adds or you add by hand.

Two consequences, and they are the whole bargain:

- **Changing a field here and restarting works.** It is not a one-time seed.
- **Hand-editing one of those five keys does not stick.** The field wins on the
  next start. Change them here, not in the file.

The file is only ever written while the server is stopped, which matters: the
game's own wiki notes that edits made while it is running are lost, because the
server rewrites the file itself.

### Admin password

Anyone who enters this password in the game's **Pause Menu → Settings → Server
Management** tab becomes an admin on your server, and stays one until the password
changes.

Leave `SRV_ADMIN_PWD` blank and the server invents a random one on first boot and
prints it in the log:

```
LogDomServerSettings: Generated missing AdminPassword: YXPHC6S6YR8JW8KA
```

Setting one yourself is easier than going to find that.

### Which name do players actually search for?

Probably `WORLD_NAME`, not `SERVER_NAME`. Community and hosting-provider
documentation is consistent that a public server is found under **Worlds →
Public** by typing the world name exactly, case-sensitive, and a Direct IP tab
was only added in 0.11.1.4. Console players cannot enter an IP at all.

Flagging it as "probably" because it is the one claim here not verified against a
running server — the session this container publishes carries both names
(`Vip_ServerName` and `SlotName` in the log), so which one the in-game browser
matches on is not something the server side can settle. If players cannot find
you, try setting `WORLD_NAME` to the name you are telling them to search for.

### World Name is not a rename

`WORLD_NAME` names the world created on first boot and the save file it uses,
`Saved/SaveGames/<name>.sav`. Changing it later points the server at a different
save; if that file does not exist, a new world is generated. The old one stays on
disk and setting the name back returns to it. Nothing is renamed and nothing is
deleted.

Note the spelling of that directory: **`SaveGames`**, with a capital G. The game's
wiki writes it `Savegames`, which does not match what the server actually creates.

### Starting over with a fresh world

Stop the container, delete the save, start it again:

```sh
rm /mnt/user/appdata/dragonwilds/RSDragonwilds/Saved/SaveGames/Standard.sav
```

The server generates a new world using the current `WORLD_NAME` on the next start.
There is no container setting for this on purpose — a flag that deletes worlds is
a footgun, and this is one command.

### Player cap

Dragonwilds caps a server at 6 players, and that limit is not in
`DedicatedServer.ini` — it lives in the engine's own game config. There is no
field for it here because there is nothing useful to set it to. If you want to
try raising it, two other containers pass it as a launch argument, which you can
do through `GAME_PARAMS_EXTRA`:

```
-ini:Game:[/Script/Engine.GameSession]:MaxPlayers=8
```

Whether a value above 6 actually works is unverified, by them and by this repo.

## Stopping safely

**Stopping the container does not save. The most you can lose is 5 minutes.**

Two measured facts drive everything here:

- The server **autosaves every 5 minutes**, exactly, whether or not anyone is
  connected. Measured over a 20 minute run: saves at +300s, +600s, +900s and
  +1200s, each 300 seconds apart to the second.
- **Neither SIGINT nor SIGTERM saves.** The container sends SIGINT, the engine
  performs a full orderly teardown and exits in about two seconds, and the save
  file is untouched — byte-identical mtime and size across the stop.

So a stop costs you whatever happened since the last autosave: at most five
minutes, on average about two and a half.

### Why there is no save on shutdown

The game does have a save-on-exit path — `RequestGameExit`, a staged sequence
that logs `RequestGameExit : Server saving World and Player state` before tearing
the session down. But it is Blueprint-exposed and driven from the game's own UI:
it is the **in-game quit flow**. A POSIX signal never reaches it. A signal goes to
Unreal's `FUnixPlatformMisc::RequestExit`, which shuts the engine down without
touching the game's persistence layer.

Dragonwilds has no RCON, no console and no save command, so there is no way for
this container — or any container — to ask the server to save first. This is a
property of the game, not a gap in this image.

### Getting a clean stop anyway

**Have players quit out through the game menu before you stop the container.**
That runs `RequestGameExit`, which saves. If nobody is connected, the last
autosave is at most 5 minutes old and a stop is cheap.

If you want a tighter bound than 5 minutes, restart on a schedule shortly after
an autosave, or simply accept it — for a survival server with a handful of
players this is a small window.

### Stop timeout

`STOP_TIMEOUT` defaults to 30 seconds. That is not a save window, because there is
no save; it is headroom for the engine's teardown, which measured about 2 seconds
on a small world and could be slower on a large one on spinning disks.

Raise Unraid's own container stop timeout to at least 45 seconds so the teardown
is not cut short by Docker's 10 second default. With compose that is
`stop_grace_period: 45s`.

There is no RCON, so there is no second shutdown path, no `rcon-cli.sh` in this
image, and no admin commands from the host. Admin actions are in-game only.

## Editing the config over SMB

The config lives at
`/mnt/user/appdata/dragonwilds/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini`.
`UMASK=000` keeps it writable over the share. Remember that the five managed keys
above get overwritten on the next start — everything else you put in there stays.

## Troubleshooting

**The container exits immediately saying `OWNER_ID` is empty.** That is the guard
described at the top. Fill in the Owner ID field.

**The log says `Refusing to run with the root privileges` and the server aborts
with code 134.** Unreal will not run as root. Set `UID` and `GID` to a non-zero
user — 99 and 100 on Unraid.

**The server binary is missing after SteamCMD finishes.** Check free space first;
the install needs about 5GB. If there is space, check that `STEAM_DEPOT_PLATFORM` is
`linux` — with `windows` SteamCMD installs the Windows depot perfectly cleanly and
the Linux binary is simply not in it.

**SteamCMD says `Failed to install app '4019830' (Missing configuration)` on a
brand new install.** That is SteamCMD's own first-run bootstrap and it happens
roughly one run in two against an empty steamcmd directory. The runner retries
once automatically; the second pass works.

**The server is running but nobody can join.** Check UDP 7777 is forwarded, and
check the log for the Owner ID message above.

## License

MIT, same as the rest of this repo.
