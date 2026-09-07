# V Rising — dedicated server

A V Rising dedicated server. V Rising ships no Linux server binary, so this pulls
the Windows depot with SteamCMD and runs it under GE-Proton, with a virtual
display because the binary will not start without one.

First boot downloads about 2GB and then builds a Proton prefix. It can sit quiet
for several minutes before the log shows anything. That is normal.

Built for Unraid, but it is an ordinary container and runs anywhere.

```bash
docker run -d --name v-rising \
  -p 27015:27015/udp \
  -p 27016:27016/udp \
  --stop-timeout 75 \
  -e SERVER_NAME="My Server" \
  -e MAX_PLAYERS=40 \
  -v /path/to/serverfiles:/serverdata/serverfiles \
  -v /path/to/steamcmd:/serverdata/steamcmd \
  ferment9348/v-rising:latest
```

Or with compose:

```yaml
services:
  v-rising:
    image: ferment9348/v-rising:latest
    restart: unless-stopped
    stop_grace_period: 75s
    ports:
      - "27015:27015/udp"
      - "27016:27016/udp"
    environment:
      SERVER_NAME: "My Server"
      MAX_PLAYERS: "40"
    volumes:
      - ./data/serverfiles:/serverdata/serverfiles
      - ./data/steamcmd:/serverdata/steamcmd
```

## Ports

| Port    | Proto | Purpose                                                   |
| ------- | ----- | --------------------------------------------------------- |
| `27015` | UDP   | Game traffic. Required, and the one to forward.            |
| `27016` | UDP   | Steam query. Without it the server runs and never appears in the browser. |
| `25575` | TCP   | RCON. Only expose it if you administer from outside the host. |

To move the game port, the container port, the host port and `GAME_PORT` must all
be the same number. Docker cannot tell the server what its host port is, so if
`GAME_PORT` differs from the container port nothing reaches the server, and if it
differs from the host port the log reports a port players cannot use. Same for the
query pair and `QUERY_PORT`.

## Common settings

| Variable         | Default           | What it does                                 |
| ---------------- | ----------------- | -------------------------------------------- |
| `SERVER_NAME`    | `V Rising Server` | Name in the server browser.                  |
| `WORLD_NAME`     | `world1`          | Save directory name. Changing it starts a new world; the old one stays on disk. |
| `MAX_PLAYERS`    | `40`              | Player slots, up to 128.                     |
| `SRV_PWD`        | empty             | Join password. Blank means open.             |
| `SRV_ADMIN_PWD`  | empty             | RCON password. Blank disables RCON entirely. |
| `GAME_PORT`      | `27015`           | Game port the server binds.                  |
| `QUERY_PORT`     | `27016`           | Steam query port.                            |
| `STOP_TIMEOUT`   | `60`              | Seconds to wait for a save-and-exit.         |
| `PROTON_VERSION` | `GE-Proton10-34`  | The GE-Proton build to run under.            |
| `UID` / `GID`    | `99` / `100`      | Unraid's `nobody:users`. Use `1000:1000` elsewhere. |

## Every other setting works too

The server reads its own `VR_`-prefixed environment variables, and they override
the config file. So `-e VR_FPS=45` sets the server framerate, `-e VR_LAN_MODE=true`
enables LAN mode, and anything in
[Stunlock's documentation](https://github.com/StunlockStudios/vrising-dedicated-server-instructions)
works the same way, whether or not it has a named variable above.

## Worth knowing

- **Your config edits survive.** On first boot the container seeds
  `save-data/Settings/` from the defaults the server ships with, and then never
  writes those files again. `ServerGameSettings.json` — the gameplay balance
  knobs — it never touches at all. The settings above reach the server as launch
  options instead, so both can be right at once.
- **Stopping saves the world.** Give the container a stop timeout of at least 75
  seconds (`--stop-timeout 75`, or `stop_grace_period: 75s`). Docker's default is
  10, which fires mid-save. RCON is not involved, so a server with no admin
  password still stops cleanly.
- **RCON is an admin tool, not a requirement.** With `SRV_ADMIN_PWD` set:
  `docker exec v-rising /opt/scripts/rcon-cli.sh announce "Restarting in 5"`.
- **A CPU without AVX is handled.** `lib_burst_generated.dll` aborts the server on
  one, so the container moves it aside and says so in the log.
- **amd64 only.** It is a Windows binary under Proton; an arm64 image would build
  and not run.

Source, issues and the full guide:
<https://github.com/blckassassin/unraid-game-servers>
