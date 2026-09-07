# V Rising — dedicated server for Unraid

V Rising ships no Linux server binary, so this container pulls the Windows depot
with SteamCMD and runs `VRisingServer.exe` under GE-Proton — the same approach as
the [ARK: Survival Ascended](../../README.md) container in this repo. It also runs
the server under a virtual display, because the binary will not start without one
even headless.

First boot downloads about 2GB and then builds a Proton prefix, which can sit
quiet for several minutes before anything appears in the log. That is normal.

## Get the image

```sh
docker pull ferment9348/v-rising:latest
```

Or build it yourself, from the repo root:

```sh
docker build -f games/v-rising/Dockerfile -t v-rising .
```

## Install on Unraid

It is in Community Applications as **V-Rising**. Everything below maps to a field
in that template; the variable names are what you would use with `docker run`.

## Ports

| Port    | Protocol | What for                                                  |
| ------- | -------- | --------------------------------------------------------- |
| `27015` | UDP      | Game traffic. Required, and the one to forward.            |
| `27016` | UDP      | Steam query. Forward it too, or the server runs fine and never appears in the browser. |
| `25575` | TCP      | RCON. Only expose this if you administer from outside the box. |

**If you also run the ARK container on this server, its Query Port defaults to
27015 as well** and Docker refuses to start the second container. Change one of
them. ARK's is the safer one to move: its 27015 is vestigial, since ASA's
discovery goes through EOS.

To move the game port, three numbers have to agree: the container port, the host
port, and `GAME_PORT`. Docker cannot tell the server what its host port is, so if
`GAME_PORT` differs from the container port nothing reaches the server, and if it
differs from the host port the log reports a number players cannot use. The same
applies to the query pair and `QUERY_PORT`.

## Configuration

The template's fields are passed to the server as launch options on every start,
so changing one and restarting takes effect immediately.

| Variable            | Default           | What it does                                    |
| ------------------- | ----------------- | ----------------------------------------------- |
| `SERVER_NAME`       | `V Rising Server` | Name in the server browser.                     |
| `SERVER_DESC`       | empty             | Description in the browser's details panel.     |
| `WORLD_NAME`        | `world1`          | Save directory name. See below.                 |
| `MAX_PLAYERS`       | `40`              | Player slots. 128 is the documented maximum.    |
| `MAX_ADMINS`        | `4`               | Admins who can join a full server.              |
| `SRV_PWD`           | empty             | Join password. Blank means open.                |
| `SRV_ADMIN_PWD`     | empty             | RCON password. Blank disables RCON entirely.    |
| `GAME_PORT`         | `27015`           | Game port the server binds.                     |
| `QUERY_PORT`        | `27016`           | Steam query port.                               |
| `RCON_PORT`         | `25575`           | RCON port, used only with an admin password.    |
| `GAME_PRESET`       | empty             | A preset from `GameSettingPresets`, e.g. `StandardPvP`. |
| `DIFFICULTY_PRESET` | empty             | `Difficulty_Easy`, `Difficulty_Normal`, `Difficulty_Brutal`. |
| `LIST_ON_STEAM`     | `true`            | Register on the Steam server list.              |
| `LIST_ON_EOS`       | `true`            | Register on the EOS list, where the client looks by default. |
| `SECURE`            | `true`            | VAC protection.                                 |
| `STOP_TIMEOUT`      | `60`              | Seconds to wait for a save-and-exit.            |
| `PROTON_VERSION`    | `GE-Proton10-34`  | The GE-Proton build to run under.               |

### Every other setting works too, without a field for it

The server reads its own `VR_`-prefixed environment variables, and those override
the config file. So anything in
[Stunlock's documentation](https://github.com/StunlockStudios/vrising-dedicated-server-instructions)
is reachable by adding a variable in the template, whether or not it appears in
the table above:

| Add a variable | With a value | And you get                    |
| -------------- | ------------ | ------------------------------ |
| `VR_FPS`       | `45`         | A server framerate target of 45. |
| `VR_LAN_MODE`  | `true`       | LAN mode.                      |
| `VR_SAVE_INTERVAL` | `300`    | An autosave every 5 minutes.   |

That is the answer to "can I set X" for every X: yes, name it `VR_<SETTING>` and
the server picks it up.

### Your config edits are never overwritten

On first boot the container copies the two settings files the server ships with
into `save-data/Settings/`, and after that it never writes them again — not on
restart, not on update. `ServerGameSettings.json`, which holds the ~60 gameplay
balance knobs, the container never touches at all: edit it freely and restart.

This is why the template's fields are launch options rather than file rewrites.
Both can be right at once, and neither clobbers the other.

### Save Name is not a rename

Changing `WORLD_NAME` points the server at a different save directory. If that
directory does not exist, a new world is generated — the old one stays on disk
under `save-data/Saves/` and setting the name back returns to it. Nothing is
renamed and nothing is deleted.

## Sending console commands

RCON is off unless you set an admin password. With one set:

```sh
docker exec V-Rising /opt/scripts/rcon-cli.sh announce "Restarting in 5 minutes"
docker exec V-Rising /opt/scripts/rcon-cli.sh "shutdown 60,30,10 Server restarting"
docker exec V-Rising /opt/scripts/rcon-cli.sh version
```

The full command list is `help`, `announce`, `announcerestart`, `shutdown`,
`cancelshutdown`, `name`, `description`, `password`, `version` and `time`.

## Stopping safely

V Rising saves when it receives a shutdown signal, so a normal `docker stop` or
the Unraid stop button is safe. `STOP_TIMEOUT` (default 60) is how long the
container waits for that save before forcing the issue.

**Raise Unraid's own container stop timeout to at least 75 seconds.** Docker's
default is 10, and if that fires first it kills the container mid-save. The
setting is under Settings → Docker.

You do not need RCON for this. The shutdown path signals the server directly, so
a server with no admin password still saves cleanly.

## Troubleshooting

**Nothing in the log at all, for a long time.** First boot is genuinely slow: 2GB
of download, then a Proton prefix build. If it stays silent well past that, the
Proton build is the first suspect — this repo has been bitten by exactly that
before, on ARK. Set `DEBUG=true` and restart to capture wine and Proton output,
and check `PROTON_VERSION` is `GE-Proton10-34`.

**The server starts but is not in the server browser.** Check the query port:
`27016` has to be forwarded as well as the game port, and `LIST_ON_EOS` /
`LIST_ON_STEAM` have to be `true`.

**A CPU without AVX.** Handled automatically. `lib_burst_generated.dll` is
compiled for AVX and aborts the server on a CPU that lacks it, so the container
moves it aside and says so in the log.

## License

MIT, same as the rest of this repo.
