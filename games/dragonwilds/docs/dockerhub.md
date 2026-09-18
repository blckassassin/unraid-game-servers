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
  -p 8888:8888/udp \
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
      - "8888:8888/udp"
    environment:
      OWNER_ID: "your-player-id"
      SERVER_NAME: "My Server"
    volumes:
      - ./data/serverfiles:/serverdata/serverfiles
      - ./data/steamcmd:/serverdata/steamcmd
```

## Ports

The server binds three UDP sockets:

| Port         | Publish?  | Purpose                                            |
| ------------ | --------- | -------------------------------------------------- |
| `GAME_PORT`  | **Yes**   | Game traffic, and the port players are sent to.    |
| `8888`       | Optional  | World settings beacon. Compiled constant.          |
| `45453`      | No        | LAN discovery. Cannot work under bridge — see below.|

There is no query port. Whether clients need to reach 8888 is untested; nothing
has been reported broken without it.

### Changing the port

**The host port, the container port and `GAME_PORT` must all be the same
number.**

```bash
docker run -d --name dragonwilds \
  -p 7780:7780/udp \
  -p 8888:8888/udp \
  -e GAME_PORT=7780 \
  -e OWNER_ID="your-player-id" \
  -v /path/to/serverfiles:/serverdata/serverfiles \
  -v /path/to/steamcmd:/serverdata/steamcmd \
  ferment9348/dragonwilds:latest
```

This is the game's behaviour, not a Docker convention. The server advertises the
port it **binds**:

```
LogRedpointEOSNetworking: Verbose: User '(dedicated server)' is now listening on
Internet address '0.0.0.0:7777' with 0 developer addresses.
```

The EOS session carries no port attribute of its own, so players joining from the
in-game browser are sent to `<public ip>:<bind port>`. A port mapping cannot
translate that. Publish 7780 against a server bound to 7777 and the world is
listed, reports ready and heartbeats fine while every join goes to 7777.

Bridge networking on a non-default port is fully supported. `--net=host` also
works and leaves one number instead of three.

On Unraid, the **Container Port** box of every port a template supplied is greyed
out, so your number will not go in it. Remove the **Game Port** entry and add your
own Port entry with both sides set to your number — an entry you create yourself
stays editable. The README has the steps.

### LAN discovery under bridge

UDP 45453 is the LAN discovery probe. It is broadcast-based and a Docker bridge
does not carry the host NIC's LAN broadcasts, so it cannot work and publishing it
changes nothing. On a LAN use the in-game **Worlds → Direct** tab with
`host:port`, which needs game 0.11.1 or newer.

The **Public** tab may also stay empty from inside your own LAN, because the
session advertises your public IP and reaching it from inside needs NAT hairpin.
Test from outside before assuming a fault.

## Common settings

| Variable            | Default              | What it does                              |
| ------------------- | -------------------- | ----------------------------------------- |
| `OWNER_ID`          | empty                | **Required.** Your in-game Player ID.     |
| `SERVER_NAME`       | `Dragonwilds Server` | Name in the server browser.               |
| `WORLD_NAME`        | `Standard`           | World and save-file name, and most likely what players type to find you. |
| `SRV_ADMIN_PWD`     | empty                | Admin password. Blank means the server generates one and prints it in the log. |
| `SRV_PWD`           | empty                | Join password. Blank means open.          |
| `GAME_PORT`         | `7777`               | The port the server binds **and advertises**. Must equal both sides of the mapping. |
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
