# RuneScape: Dragonwilds ships a native Linux dedicated server, so this image
# needs none of ASA's or V Rising's Proton, wine or Xvfb machinery. It is the
# first SteamCMD game here that installs a Linux depot rather than a Windows one,
# which is what STEAM_DEPOT_PLATFORM below is for.
FROM debian:trixie-slim

LABEL org.opencontainers.image.title="RuneScape: Dragonwilds Dedicated Server" \
      org.opencontainers.image.description="RuneScape: Dragonwilds dedicated server, native Linux binary, SteamCMD-based, Unraid friendly." \
      org.opencontainers.image.source="https://github.com/blckassassin/unraid-game-servers" \
      org.opencontainers.image.licenses="MIT"

# PROTON_DIR is deliberately not set. shared/scripts/start.sh skips it when
# unset, which is how one entrypoint serves a Proton game and a native one.
ENV DEBIAN_FRONTEND="noninteractive" \
    STEAMCMD_DIR="/serverdata/steamcmd" \
    SERVER_DIR="/serverdata/serverfiles" \
    GAME_ID="4019830" \
    # Linux, not the shared default of windows: app 4019830 publishes both, and
    # the Windows depot is 4.8GB of binaries this image cannot run.
    STEAM_DEPOT_PLATFORM="linux" \
    OWNER_ID="" \
    SERVER_NAME="Dragonwilds Server" \
    WORLD_NAME="Standard" \
    SRV_PWD="" \
    SRV_ADMIN_PWD="" \
    GAME_PORT="7777" \
    GAME_PARAMS_EXTRA="" \
    VALIDATE="" \
    USERNAME="" \
    PASSWRD="" \
    UID="99" \
    GID="100" \
    DATA_PERM="775" \
    UMASK="000" \
    # Not a save window: shutdown does not save (nothing can make it - the game
    # has no RCON, console or save command, and its RequestGameExit save path is
    # the in-game quit UI). This is headroom for the engine teardown, measured at
    # about 2s. The world is protected by a 5-minute autosave instead.
    STOP_TIMEOUT="30"

# lib32gcc-s1 is for SteamCMD, which is a 32-bit binary. The server itself is
# 64-bit and links only against libraries debian:trixie-slim already ships.
RUN apt-get update && \
    apt-get -y upgrade && \
    apt-get -y install --no-install-recommends \
        ca-certificates \
        curl \
        tar \
        procps \
        gosu \
        tini \
        lib32gcc-s1 \
        locales && \
    sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen && \
    useradd -u ${UID} -d /home/steam -m -s /bin/bash steam && \
    mkdir -p ${STEAMCMD_DIR} ${SERVER_DIR} && \
    apt-get -y autoremove && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENV LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en" \
    LC_ALL="en_US.UTF-8"

COPY shared/scripts/ /opt/scripts/
COPY games/dragonwilds/scripts/ /opt/scripts/
RUN chmod -R 755 /opt/scripts

# The server binds three UDP sockets, verified against a live server:
#
#   GAME_PORT   game traffic      LogNet: ... IpNetDriver listening on port 7777
#   8888        world settings    LogDomGameMode: World settings beacon listening
#                 beacon            on port 8888
#   45453       LAN discovery     LogDomLanProbe: SERVER : Socket setup OK
#                 probe             [0.0.0.0:45453]
#
# Both extra ports are compiled constants - neither appears in any ini under
# Saved/Config/LinuxServer, and neither is a literal string in the 219MB shipping
# binary, so they are observable only at runtime.
#
# EXPOSE is documentation, not a gate: `-p` publishes whatever it is told to,
# EXPOSE or no EXPOSE. These lines exist so the ports show up in `docker inspect`
# and in the Unraid UI rather than having to be discovered from a log.
#
# 45453 is deliberately not EXPOSEd. LAN discovery is UDP broadcast and Docker's
# bridge does not forward the host NIC's broadcasts into a container, so
# publishing it would advertise a capability that cannot work. See the README.
EXPOSE 7777/udp
EXPOSE 8888/udp

VOLUME ["/serverdata/steamcmd", "/serverdata/serverfiles"]

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/scripts/start.sh"]
