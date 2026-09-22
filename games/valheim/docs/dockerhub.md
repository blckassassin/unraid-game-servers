# Valheim — dedicated server

Valheim dedicated server, built for Unraid but an ordinary Docker image that runs
anywhere. The game ships a native Linux server binary, so SteamCMD installs it and
it runs directly — no Proton, no wine, no virtual display.

First boot downloads about 2GB and settles at about 2.1GB. A new world generates
in well under a minute.

There is no config file: every setting is a launch flag, so changing one and
restarting takes effect immediately and nothing you edit by hand is overwritten.

- **Guide:** https://github.com/blckassassin/unraid-game-servers/blob/main/games/valheim/README.md
- **Source:** https://github.com/blckassassin/unraid-game-servers
- **Issues:** https://github.com/blckassassin/unraid-game-servers/issues

## Run it

```sh
docker run -d --name valheim \
  -p 2456:2456/udp -p 2457:2457/udp -p 2458:2458/udp \
  -e SERVER_NAME="My Server" \
  -e WORLD_NAME="Dedicated" \
  -e SRV_PWD="atleast5chars" \
  -e UID=99 -e GID=100 \
  --stop-timeout 150 \
  -v /mnt/user/appdata/valheim:/serverdata/serverfiles \
  -v /mnt/user/appdata/steamcmd:/serverdata/steamcmd \
  ferment9348/valheim:latest
```

`--stop-timeout 150` is not optional. See **Stopping safely** below.

## The password rules

Three, all enforced by the server by refusing to start. This image checks them
first so the log tells you which one you broke.

1. At least 5 characters.
2. **The password must not appear anywhere inside the server name.** A server
   called `Jordan's Valheim` with password `valheim` will not start.
3. A server with `PUBLIC=1` must have one. For no password, set `PUBLIC=0`.

## Ports

| Port | What it is |
| --- | --- |
| 2456/udp | Game traffic |
| 2457/udp | Steam query — **this is the one you type into Steam** |
| 2458/udp | Forwarded on Iron Gate's advice |

Steam's View → Servers → Favourites → **Add a server** box wants the **query**
port, 2457, not the game port. That catches nearly everyone once.

Read out of a running container: with crossplay off the server binds 2456 and
2457; with crossplay on it binds 2457 only. 2458 was never seen bound in either
mode — it is published to match the advice in the server's own start script.

To move the port, set the host port, the container port and `GAME_PORT` all to
the same number, with the query port following at plus one. On Unraid the
container port box is greyed out for any port a template supplied, so remove the
Game Port row and add your own — an entry you create yourself has no container
port yet, so Unraid leaves it editable.

## Common settings

| Variable | Default | What it does |
| --- | --- | --- |
| `SERVER_NAME` | `Valheim Server` | Name in the server list |
| `WORLD_NAME` | `Dedicated` | Which world to load or create |
| `SRV_PWD` | *(empty)* | Join password — see the rules above |
| `PUBLIC` | `1` | `0` hides the server from the list |
| `CROSSPLAY` | `false` | `true` for the PlayFab backend |
| `GAME_PORT` | `2456` | Port the server binds |
| `PRESET` | *(empty)* | `normal` `casual` `easy` `hard` `hardcore` `immersive` `hammer` |
| `MODIFIERS` | *(empty)* | e.g. `combat=hard,raids=none` |
| `SETKEYS` | *(empty)* | e.g. `nomap,passivemobs` |
| `SAVE_INTERVAL` | *(1800)* | Seconds between autosaves |
| `BACKUP_COUNT` | *(4)* | Server's own backups to keep |
| `STOP_TIMEOUT` | `120` | Seconds to wait for the shutdown save |
| `UID` / `GID` | `99` / `100` | Unraid's `nobody:users` |

A misspelled preset, modifier or toggle **stops the container** with a message
listing the valid values, because the server's own response to one is to ignore
it silently and hand you a normal world.

## Crossplay

`CROSSPLAY=true` moves the server to the PlayFab backend. Console players can
then join, and no port forwarding is needed because traffic is relayed. In
exchange the server is listed in the in-game **Community servers** list and not
in the Steam server browser — expected, not a fault — and BepInEx mods are
reported not to load.

## Where your world lives

Everything persistent is under one directory, `savedir`, inside the game files
volume: `worlds_local/<World Name>/` plus `adminlist.txt`, `bannedlist.txt` and
`permittedlist.txt`.

Two things worth knowing. Worlds go in `worlds_local/`, never `worlds/` — the
server does not read the latter and will quietly generate a new world instead of
telling you. And an admin ID is the Platform User ID copied verbatim from the
in-game F2 panel or the server log, case sensitive; a bare SteamID64 is accepted
into the file and then silently ignored, with no error anywhere.

## Stopping safely

The shutdown save is the only save this container can ask for — Valheim has no
RCON, no console and no remote save command, so there is no fallback if the stop
is cut short.

Measured: a stop took 4.2 seconds on a freshly generated world and wrote it
correctly. A real world takes longer and keeps growing, which is why
`STOP_TIMEOUT` defaults to 120.

Docker's default stop grace is 10 seconds, which would kill the server partway
through that save. Pass `--stop-timeout 150`, or on Unraid raise the container
stop timeout to at least 150 — there it is a single global setting, so check it
after an Unraid update.

## Memory

About 3GB idle, 6–8GB for a busy long-running world; 1.4GB was resident right
after generating a world with nobody connected. Memory use grows over time, a
long-reported trait of this server, so a scheduled nightly restart is worth
setting up. That is safe, because the stop saves.

## Volumes

| Path | What it holds |
| --- | --- |
| `/serverdata/serverfiles` | The server, your world and the permission lists |
| `/serverdata/steamcmd` | SteamCMD itself — small, shareable |

## Source and support

Built from https://github.com/blckassassin/unraid-game-servers — issues and
questions there. MIT licensed.
