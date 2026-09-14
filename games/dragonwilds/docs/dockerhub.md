# RuneScape: Dragonwilds — dedicated server

A RuneScape: Dragonwilds dedicated server. The game ships a real Linux server
binary, so unlike this author's ARK and V Rising images there is no Proton and no
wine here — SteamCMD pulls the Linux depot and the server runs natively.

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

| Port   | Proto | Purpose                                       |
| ------ | ----- | --------------------------------------------- |
| `7777` | UDP   | Game traffic. The only port the server binds.  |

There is no query port — Dragonwilds lists through EOS, not through Steam.

To move it, the container port, the host port and `GAME_PORT` must all be the same
number. Docker cannot tell the server what its host port is, so if `GAME_PORT`
differs from the container port nothing reaches the server, and if it differs from
the host port the log reports a port players cannot use.

## Common settings

| Variable            | Default              | What it does                              |
| ------------------- | -------------------- | ----------------------------------------- |
| `OWNER_ID`          | empty                | **Required.** Your in-game Player ID.     |
| `SERVER_NAME`       | `Dragonwilds Server` | Name in the server browser.               |
| `WORLD_NAME`        | `Standard`           | World and save-file name, and most likely what players type to find you. |
| `SRV_ADMIN_PWD`     | empty                | Admin password. Blank means the server generates one and prints it in the log. |
| `SRV_PWD`           | empty                | Join password. Blank means open.          |
| `GAME_PORT`         | `7777`               | The port the server binds.                |
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
