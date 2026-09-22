# Valheim ships a native Linux dedicated server, so this image needs none of
# ASA's or V Rising's Proton, wine or Xvfb machinery. It is the second SteamCMD
# game here to install a Linux depot rather than a Windows one, which is what
# STEAM_DEPOT_PLATFORM below is for.
FROM debian:trixie-slim

LABEL org.opencontainers.image.title="Valheim Dedicated Server" \
      org.opencontainers.image.description="Valheim dedicated server, native Linux binary, SteamCMD-based, Unraid friendly." \
      org.opencontainers.image.source="https://github.com/blckassassin/unraid-game-servers" \
      org.opencontainers.image.licenses="MIT"

# PROTON_DIR is deliberately not set. shared/scripts/start.sh skips it when
# unset, which is how one entrypoint serves a Proton game and a native one.
ENV DEBIAN_FRONTEND="noninteractive" \
    STEAMCMD_DIR="/serverdata/steamcmd" \
    SERVER_DIR="/serverdata/serverfiles" \
    GAME_ID="896660" \
    # Linux, not the shared default of windows: app 896660 publishes both, and
    # the Windows depot has no binary this image can run.
    STEAM_DEPOT_PLATFORM="linux" \
    SERVER_NAME="Valheim Server" \
    WORLD_NAME="Dedicated" \
    # No default password on purpose. The server refuses to start with -public 1
    # and no password, and a shipped default is a password nobody changes.
    SRV_PWD="" \
    PUBLIC="1" \
    CROSSPLAY="false" \
    GAME_PORT="2456" \
    PRESET="" \
    MODIFIERS="" \
    SETKEYS="" \
    SAVE_INTERVAL="" \
    BACKUP_COUNT="" \
    BACKUP_SHORT="" \
    BACKUP_LONG="" \
    GAME_PARAMS_EXTRA="" \
    VALIDATE="" \
    USERNAME="" \
    PASSWRD="" \
    UID="99" \
    GID="100" \
    DATA_PERM="775" \
    UMASK="000" \
    # A real save window, unlike Dragonwilds' teardown headroom. Valheim saves
    # on SIGINT and has no other save path at all - no RCON, no console - so
    # this number is the only thing standing between a stop and a lost world.
    # 120 matches what the long-running community container documents for its
    # own --stop-timeout, and it also covers the minutes-long one-way world
    # conversion a pre-1.0 save performs on its first 1.0 boot.
    STOP_TIMEOUT="120"

# lib32gcc-s1 is for SteamCMD, which is a 32-bit binary. The server itself is
# 64-bit and ships its own Steam libraries under linux64/.
#
# libatomic1 and libpulse0 are the only two extras it needs, and that is not a
# guess: app 896660 ships Iron Gate's own Dockerfile at docker/Dockerfile inside
# the depot, and its entire dependency list is curl, libatomic1, libpulse-dev
# and libpulse0. Note what is NOT there - libsdl2. Two widely used Valheim
# containers install it anyway; nothing in valheim_server.x86_64 or
# UnityPlayer.so links against it, checked with ldd against a real install.
# libpulse-dev is the headers package and the runtime one is enough here.
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
        libpulse0 \
        libatomic1 \
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
COPY games/valheim/scripts/ /opt/scripts/
RUN chmod -R 755 /opt/scripts

# Three consecutive UDP ports, all derived from GAME_PORT. Iron Gate documents
# the first two - "Valheim uses the specified Port AND specified Port+1" - and
# the comment block in the shipped start_server.sh tells you to forward all of
# 2456-2458.
#
# What the server actually binds, read out of /proc/net/udp on a real boot of
# buildid 25390671 on 2026-09-22:
#
#   crossplay off:  2456 and 2457
#   crossplay on:   2457 only
#
# Two things there are worth knowing. 2458 was never bound in either mode, so
# the third port is forwarding advice rather than an observed listener - it is
# EXPOSEd anyway because Iron Gate says to forward it and publishing an unbound
# port costs nothing. And a crossplay server does not bind the game port at all,
# which is the documented reason its traffic needs no forwarding: PlayFab
# relays it.
#
# EXPOSE is documentation, not a gate: `-p` publishes whatever it is told to.
# These lines exist so the ports show up in `docker inspect` and in the Unraid
# UI rather than having to be discovered from a log.
EXPOSE 2456/udp
EXPOSE 2457/udp
EXPOSE 2458/udp

VOLUME ["/serverdata/steamcmd", "/serverdata/serverfiles"]

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/scripts/start.sh"]
