# unraid-game-servers

[![build](https://github.com/blckassassin/unraid-game-servers/actions/workflows/build.yml/badge.svg)](https://github.com/blckassassin/unraid-game-servers/actions/workflows/build.yml)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Dedicated game server containers for Unraid, each with a Community Applications
template. They are ordinary Docker images and run anywhere, but the defaults,
the field names and the documentation are all aimed at Unraid.

> **Looking for the ARK guide?** It moved to
> [games/ark-survival-ascended/README.md](games/ark-survival-ascended/README.md).
> This page used to be that guide, and older installed templates still link here.

## The containers

| Game | Guide | Image | Runs as |
| --- | --- | --- | --- |
| ARK: Survival Ascended | [guide](games/ark-survival-ascended/README.md) | [`ferment9348/ark-survival-ascended`](https://hub.docker.com/r/ferment9348/ark-survival-ascended) | Windows depot under GE-Proton |
| RuneScape: Dragonwilds | [guide](games/dragonwilds/README.md) | [`ferment9348/dragonwilds`](https://hub.docker.com/r/ferment9348/dragonwilds) | Native Linux binary |
| Terraria | [guide](games/terraria/README.md) | [`ferment9348/terraria`](https://hub.docker.com/r/ferment9348/terraria) | Native Linux binary |
| V Rising | [guide](games/v-rising/README.md) | [`ferment9348/v-rising`](https://hub.docker.com/r/ferment9348/v-rising) | Windows depot under GE-Proton + Xvfb |

Each guide is self-contained: everything you need for that container is on its
own page, and none of them assumes you run any of the others.

## Install on Unraid

All four are in **Community Applications** — search the game's name. The
template fills in sensible defaults; the only field you normally must supply is
whatever that game uses to identify you (ARK needs nothing, Dragonwilds needs
your in-game Player ID).

To install by hand instead, each guide carries a `docker run` and a
`docker-compose.yml` you can paste.

## Layout

| Path | What it is |
| --- | --- |
| `games/<slug>/Dockerfile` | Image definition. Built with the repo root as context. |
| `games/<slug>/README.md` | That game's guide, and what its template links to. |
| `games/<slug>/scripts/` | Game-specific scripts, copied to `/opt/scripts`. |
| `games/<slug>/docs/dockerhub.md` | Docker Hub long description, synced by CI on release. |
| `games/<slug>/docker-compose.yml` | Local testing only — uses uid/gid 1000, not Unraid's 99/100. |
| `shared/scripts/` | Common entrypoint, SteamCMD and Proton layers, RCON client. |
| `templates/<slug>.xml` | Community Applications template. |
| `ca_profile.xml` | CA repository profile covering every game here. |
| `tests/` | Plain-assertion unit tests and the Terraria end-to-end test. |
| `tools/icongen/` | Generates the per-game icon PNGs from source art. |

## Working on this

Build any one image from the repo root:

```sh
docker build -f games/dragonwilds/Dockerfile -t dragonwilds-test .
```

The checks that must pass before a change ships:

```sh
shellcheck --severity=warning shared/scripts/*.sh games/*/scripts/*.sh tests/*.sh
python3 -m py_compile shared/scripts/rcon.py
bash tests/unit.sh
bash tests/e2e-terraria.sh terraria-test
```

`AGENTS.md` is the source of truth for build commands, test commands and the
per-game constraints that are easy to "simplify" into a regression. Read it
before changing a runner.

Releases are tagged `<slug>/v<version>` — for example `dragonwilds/v1.1.0`. A
bare `v1.2.3` builds nothing. The tag is what publishes the image and syncs that
game's Docker Hub description.

## Credit

The structure, environment variable naming and general Unraid ergonomics here
are lifted from [ich777's](https://github.com/ich777/docker-steamcmd-server)
game server containers, which were the standard for this on Unraid for years.

## License

MIT — see [LICENSE](LICENSE).
