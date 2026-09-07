# Trixie, not bookworm: GE-Proton links against GLIBC_2.38 and bookworm ships
# 2.36, so wine fails to load ntdll.so and the server exits code 1.
FROM debian:trixie-slim

LABEL org.opencontainers.image.title="V Rising Dedicated Server" \
      org.opencontainers.image.description="V Rising dedicated server (Windows binary via GE-Proton), SteamCMD-based, Unraid friendly." \
      org.opencontainers.image.source="https://github.com/blckassassin/unraid-game-servers" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND="noninteractive" \
    STEAMCMD_DIR="/serverdata/steamcmd" \
    SERVER_DIR="/serverdata/serverfiles" \
    PROTON_DIR="/serverdata/serverfiles/proton" \
    DATA_PATH="/serverdata/serverfiles/save-data" \
    GAME_ID="1829350" \
    SERVER_NAME="V Rising Server" \
    SERVER_DESC="" \
    WORLD_NAME="world1" \
    GAME_PORT="27015" \
    QUERY_PORT="27016" \
    RCON_PORT="25575" \
    MAX_PLAYERS="40" \
    MAX_ADMINS="4" \
    SRV_PWD="" \
    SRV_ADMIN_PWD="" \
    GAME_PRESET="" \
    DIFFICULTY_PRESET="" \
    LIST_ON_STEAM="true" \
    LIST_ON_EOS="true" \
    SECURE="true" \
    GAME_PARAMS_EXTRA="" \
    PROTON_TESTED="GE-Proton10-34" \
    PROTON_VERSION="GE-Proton10-34" \
    VALIDATE="" \
    USERNAME="" \
    PASSWRD="" \
    UID="99" \
    GID="100" \
    DATA_PERM="775" \
    UMASK="000" \
    STOP_TIMEOUT="60" \
    LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:/usr/lib32" \
    DEBUG="false" \
    WINEDEBUG="-all" \
    PROTON_USE_WINED3D="1" \
    PROTON_NO_ESYNC="0" \
    PROTON_NO_FSYNC="0"

# Same set as ASA, plus xvfb/xauth/winbind: V Rising will not start without a
# display, headless or not. Both reference containers wrap it in Xvfb.
RUN apt-get update && \
    apt-get -y upgrade && \
    apt-get -y install --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        tar \
        xz-utils \
        bzip2 \
        unzip \
        procps \
        net-tools \
        jq \
        gosu \
        tini \
        python3 \
        python3-minimal \
        lib32gcc-s1 \
        libatomic1 \
        libfreetype6 \
        libgl1 \
        libvulkan1 \
        libx11-6 \
        libxext6 \
        libxrandr2 \
        libnss3 \
        libgnutls30 \
        libglib2.0-0 \
        libdbus-1-3 \
        libudev1 \
        xvfb \
        xauth \
        winbind \
        locales && \
    sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen && \
    useradd -u ${UID} -d /home/steam -m -s /bin/bash steam && \
    mkdir -p ${STEAMCMD_DIR} ${SERVER_DIR} ${PROTON_DIR} && \
    apt-get -y autoremove && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENV LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en" \
    LC_ALL="en_US.UTF-8"

COPY shared/scripts/ /opt/scripts/
COPY games/v-rising/scripts/ /opt/scripts/
RUN chmod -R 755 /opt/scripts

# 27015/udp game traffic (required)
# 27016/udp Steam query port - needed for the server to appear in the browser
# 25575/tcp RCON, only if you administer remotely
EXPOSE 27015/udp 27016/udp 25575/tcp

# PROTON_DIR and DATA_PATH both live inside SERVER_DIR, so neither may be
# declared here: a nested VOLUME would shadow the parent mount.
VOLUME ["/serverdata/steamcmd", "/serverdata/serverfiles"]

# No -g here on purpose: process-group signalling would SIGTERM the wine
# processes directly and defeat the save-then-exit handler in start-server.sh.
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/scripts/start.sh"]
