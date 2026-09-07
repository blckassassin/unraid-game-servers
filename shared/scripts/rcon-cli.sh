#!/bin/bash
# Run an RCON command against the server in this container.
#
#   docker exec ARK-Survival-Ascended /opt/scripts/rcon-cli.sh SaveWorld
#   docker exec ARK-Survival-Ascended /opt/scripts/rcon-cli.sh "Broadcast Restarting in 5"
#   docker exec ARK-Survival-Ascended /opt/scripts/rcon-cli.sh ListPlayers

if [ $# -lt 1 ]; then
    echo "usage: $(basename "$0") <rcon command> [more commands...]"
    exit 2
fi

# No default port here. 27020 is ASA's, and this file is now shared - a game
# whose RCON_PORT went missing would quietly talk to the wrong port instead of
# saying so. Every image sets it, so an empty value is a bug worth reporting.
if [ -z "${RCON_PORT:-}" ]; then
    echo "RCON_PORT is not set; this image should define it" >&2
    exit 2
fi

exec python3 /opt/scripts/rcon.py 127.0.0.1 "${RCON_PORT}" "${SRV_ADMIN_PWD}" "$@"
