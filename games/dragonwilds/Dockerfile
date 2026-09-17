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

# 7777/udp game traffic. This is the only port the container publishes, but NOT
# the only socket the server binds: it also binds a hardcoded 8888/udp world
# settings beacon and an ephemeral high port, neither of which is mapped.
# start-server.sh's EXPOSED_PORT must track this number - a unit test asserts it.
EXPOSE 7777/udp

VOLUME ["/serverdata/steamcmd", "/serverdata/serverfiles"]

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/scripts/start.sh"]
