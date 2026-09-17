# RuneScape: Dragonwilds — dedicated server

A RuneScape: Dragonwilds dedicated server. The game ships a real Linux server
binary, so there is no Proton and no wine — SteamCMD pulls the Linux depot and
the server runs natively.

First boot downloads about 1.5GB and settles at about 5GB on disk, then generates
a world, which takes a few minutes.

Built for Unraid, but it is an ordinary container and runs anywhere.

## You need your Owner ID first

The server requires your in-game Player ID. Open RuneScape: Dragonwilds, go to
**Settings**, and it is at the bottom of that menu with a copy button next to it.

This container refuses to start without one. The server itself does not — with
`OwnerId` empty it starts, binds its port and turns away every player, which looks
identical to a healthy container from the outside.

```bash
docker run -d --name dragonwilds \
  -p 7777:7777/udp \
  --stop-timeout 45 \
  -e OWNER_ID="your-player-id" \
  -e SERVER_NAME="My Server" \
  -v /path/to/serverfiles:/serverdata/serverfiles \
  -v /path/to/steamcmd:/serverdata/steamcmd \
  ferment9348/dragonwilds:latest
```

Or with compose:

```yaml
services:
  dragonwilds:
    image: ferment9348/dragonwilds:latest
    restart: unless-stopped
    stop_grace_period: 45s
    ports:
      - "7777:7777/udp"
    environment:
      OWNER_ID: "your-player-id"
      SERVER_NAME: "My Server"
    volumes:
      - ./data/serverfiles:/serverdata/serverfiles
      - ./data/steamcmd:/serverdata/steamcmd
```

## Ports

| Port   | Proto | Purpose                                            |
| ------ | ----- | -------------------------------------------------- |
| `7777` | UDP   | Game traffic. The one to forward.                  |
| `8888` | UDP   | World settings beacon. Hardcoded, not published.   |

There is no query port. `7777/udp` is the only port this container publishes.

A running server also binds `8888/udp` — its world settings beacon, logged as
`World settings beacon listening on port 8888` — and an ephemeral high port. The
beacon's number is hardcoded and cannot be moved. Whether any client needs to
reach it is untested; nothing has been reported broken without it.

### Changing the port

Change the host side of the mapping and nothing else — the left-hand number in
`-p 7780:7777/udp`. The server always binds 7777 inside the container and the
mapping points at 7777, so the two cannot disagree.

Leave `GAME_PORT` at 7777 on a bridge network. It is the port the server binds
*inside* the container, not the port players use. Setting it to anything else
gives a server that starts, logs cleanly and reports healthy while Docker
forwards to 7777 with nothing listening there. The container warns if it sees
that combination.

**Host networking is the exception** — no mapping, no container port, so
`GAME_PORT` is the only number there is:

```bash
docker run -d --name dragonwilds --network host \
  -e GAME_PORT=7780 \
  -e OWNER_ID="your-player-id" \
  -v /path/to/serverfiles:/serverdata/serverfiles \
  -v /path/to/steamcmd:/serverdata/steamcmd \
  ferment9348/dragonwilds:latest
```

On Unraid, set Network Type to `host`. The trade is no network isolation, and
8888 lands on the host too, so one instance per box.

## Common settings

| Variable            | Default              | What it does                              |
| ------------------- | -------------------- | ----------------------------------------- |
| `OWNER_ID`          | empty                | **Required.** Your in-game Player ID.     |
| `SERVER_NAME`       | `Dragonwilds Server` | Name in the server browser.               |
| `WORLD_NAME`        | `Standard`           | World and save-file name, and most likely what players type to find you. |
| `SRV_ADMIN_PWD`     | empty                | Admin password. Blank means the server generates one and prints it in the log. |
| `SRV_PWD`           | empty                | Join password. Blank means open.          |
| `GAME_PORT`         | `7777`               | The port the server binds *inside* the container. Leave it on bridge. |
| `STOP_TIMEOUT`      | `30`                 | Seconds to wait for the engine to exit. Not a save window. |
| `VALIDATE`          | empty                | `true` makes SteamCMD verify every file.  |
| `UID` / `GID`       | `99` / `100`         | Unraid's defaults. Neither may be 0 — the server refuses to run as root. |

## How your config is treated

Everything lives in `RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini`,
and none of it has a command-line equivalent, so the container writes to that file.

It writes exactly five keys on every start — `OwnerId`, `ServerName`,
`DefaultWorldName`, `AdminPassword` and `WorldPassword` — and leaves every other
line alone, including the `ServerGuid` the server generates for itself.

So changing a setting here and restarting takes effect, and anything else you put
in that file survives. The other side of it: hand-editing one of those five keys
does not stick, because the environment variable wins on the next start.

## Stopping safely

**Stopping does not save. The most you can lose is 5 minutes.**

The server autosaves every 5 minutes exactly, connected players or not — measured
over a 20 minute run, saves landing at +300s, +600s, +900s and +1200s. Neither
SIGINT nor SIGTERM saves: the engine tears down cleanly in about two seconds and
the save file comes through byte-identical.

That is a property of the game. Its save-on-exit path (`RequestGameExit`) is the
in-game quit flow, which a signal cannot reach, and there is no RCON, no console
and no save command, so no container can request a save first.

For a clean stop, have players quit out through the game menu — that does save.

`STOP_TIMEOUT` (default 30) is headroom for the engine teardown, not a save
window. Set the container stop timeout to at least 45 seconds.

## Volumes

| Path                      | What                                                     |
| ------------------------- | -------------------------------------------------------- |
| `/serverdata/serverfiles` | The server, your worlds and your config. About 5GB.       |
| `/serverdata/steamcmd`    | SteamCMD itself. Small, shareable with other containers.  |

## Source and support

https://github.com/blckassassin/unraid-game-servers

Full documentation is in
[games/dragonwilds/README.md](https://github.com/blckassassin/unraid-game-servers/blob/main/games/dragonwilds/README.md).
