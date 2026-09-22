# Valheim — dedicated server for Unraid

A Valheim dedicated server in a container. The game ships a native Linux server
binary, so SteamCMD installs it and it runs directly — no Proton, no wine, no
virtual display.

First boot downloads about 2GB and settles at about 2.1GB on disk. Generating a
new world takes well under a minute.

The ports, the save layout, the shutdown behaviour and the startup numbers below
were read off a real running server, and where that disagreed with the published
advice this page says so. The rest — mods, crossplay's effect on them, and how
memory behaves over weeks — comes from Iron Gate's own manual and from long-lived
community servers, and is marked where it matters.

## Get the image

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

There is a `docker-compose.yml` beside this file you can paste instead. It uses
uid/gid 1000 for an ordinary Linux host; Unraid wants 99/100.

## Install on Unraid

It is in **Community Applications** — search for Valheim. The template fills in
sensible defaults. The one field you must supply is **Server Password**, unless
you set **Public** to 0.

Then raise the container stop timeout. See [Stopping safely](#stopping-safely) —
this matters more here than for most game servers.

## The password rules

Three of them, and all three are enforced by the server itself by refusing to
start. This container checks them before launching so you get a sentence saying
which one you broke, instead of one terse line somewhere in the startup log.

1. **At least 5 characters.**
2. **The password must not appear anywhere inside the server name.** This is the
   one that catches people. A server called `Jordan's Valheim` with the password
   `valheim` will not start, and nothing about the error makes that obvious.
3. **A server with Public set to 1 must have a password.** There is no such thing
   as a listed server that anyone can walk into. If you want no password, set
   Public to 0 and hand out the address instead.

The container's check for rule 2 is case-sensitive, because nothing documents
whether the server's own check is. If your password appears in the name only
when you ignore case, you get a note in the log rather than a refusal — if the
server then declines to start anyway, that note is the thing to act on.

## Ports

Three UDP ports, numbered from the game port:

| Port | What it is |
| --- | --- |
| 2456 | Game traffic |
| 2457 | Steam query — **this is the one you type into Steam** |
| 2458 | Forwarded on Iron Gate's advice; see below |

**To add the server to your Steam favourites, use 2457, not 2456.** Steam's
View → Servers → Favourites → Add a server box wants the query port. Typing the
game port there is the single most common reason someone cannot find their own
server.

Reading the bound sockets out of a running container gave this:

- **Crossplay off** — the server binds 2456 and 2457.
- **Crossplay on** — the server binds 2457 only.

2458 was never seen bound in either mode, and Iron Gate's own manual — the PDF
that ships inside the server download — says plainly that "the default Port Range
that the Server uses is 2456-2457". The only thing that asks for 2458 is a
comment in the server's own `start_server.sh`. The template publishes it to match
that comment, since doing so costs nothing if the port is free, but on the
evidence you can remove the row.

### Changing the port

The host port, the container port and **Server Port** must all be the same
number. Set the game port to 2500 and you want 2500 in all three places, with
the query port following at 2501.

#### On Unraid, replace the Game Port row instead of editing it

Unraid greys out the Container Port box for every port a template supplied, so
you cannot simply type a new number into it. Replace the row instead:

1. Click **Remove** on the Game Port row.
2. Click **Add another Path, Port, Variable, Label or Device**.
3. Choose **Port**, set **Container Port** and **Host Port** both to your number,
   and set Protocol to UDP.
4. Do the same for the Query Port row, using your number plus 1.
5. Set the **Server Port** variable to the same number.
6. Apply.

A port entry you create yourself has no container port yet, so Unraid leaves it
editable. This is all in the Unraid web UI — no terminal, and nothing to toggle
in settings.

#### If a template update puts the stock row back

You will then have two entries: yours, which works, and the stock one, which
nothing is listening on. Remove the stock one and Apply.

### Crossplay changes which ports matter

With **Crossplay** set to true the server moves to the PlayFab backend. That
means:

- It no longer binds the game port at all, and **no port forwarding is needed** —
  traffic is relayed.
- It is listed in the in-game **Community servers** list and **not** in the Steam
  server browser. That is expected, not a fault, and it is the thing people
  report as "my server disappeared".
- Console players can join. They cannot join a Steam-backend server.
- BepInEx mods are reported not to load under crossplay.

Iron Gate's own shipped `start_server.sh` passes `-crossplay` by default now, so
this is worth a thought rather than an assumption. The template ships with it
off, which keeps the familiar Steam server browser behaviour.

## Configuration

There is no config file. Every setting is passed to the server as a launch flag,
so changing a field and restarting takes effect immediately, and nothing you
edit by hand is ever overwritten by this container.

Your world and the three permission lists live under one directory:

```
<appdata>/savedir/
  adminlist.txt
  bannedlist.txt
  permittedlist.txt
  worlds_local/
    <World Name>/
      _main.N.db2      the world
      _main.N.fwl2     metadata and seed
      _main.N.chunks   chunk index
      *.chunk          terrain
      _main.N.ok       written last, marks the save complete
```

`N` counts up by one each time the server saves. The server writes `_main.N.ok`
last and only then removes the generation before it, which is what makes a
half-written save impossible to mistake for a finished one.

### World modifiers

Valheim 1.0's world modifier system is exposed as three fields.

**World Preset** — one of `normal`, `casual`, `easy`, `hard`, `hardcore`,
`immersive`, `hammer`. Leave blank for normal.

**World Modifiers** — a comma-separated list of `name=value`:

| Name | Values |
| --- | --- |
| `combat` | `veryeasy` `easy` `hard` `veryhard` |
| `deathpenalty` | `casual` `veryeasy` `easy` `hard` `hardcore` |
| `resources` | `muchless` `less` `more` `muchmore` `most` |
| `raids` | `none` `muchless` `less` `more` `muchmore` |
| `portals` | `casual` `hard` `veryhard` |

For example: `combat=hard,raids=none,portals=casual`.

Each list leaves out its own normal setting on purpose — you name a modifier only
to move it away from normal, and there is no spelling for "normal".

**World Toggles** — a comma-separated list of any of `nobuildcost`,
`playerevents`, `passivemobs`, `nomap`. Blank means all off.

A name or value that is not in these lists **stops the container** with a message
listing what is valid. That is deliberate: the server's own response to a
modifier it does not recognise is to ignore it silently, which would hand you a
normal-difficulty world with nothing to explain why.

A preset resets every individual modifier it covers, so order matters. The
container always emits the preset first and your individual modifiers after it,
so your specific choices win and you cannot get the ordering wrong.

### Admins, bans and the permitted list

Three plain text files in `savedir`, one ID per line. The server creates them
empty on first boot.

**Use the ID exactly as the game shows it, and do not retype it.** Iron Gate's
own manual calls it the Platform User ID, gives its shape as
`[Platform]_[User ID]`, says it is **case sensitive**, and tells you to get it
either from the server log or from the in-game **F2** panel. Copy it from one of
those two places verbatim.

What it is *not* is a bare SteamID64. That is what pre-1.0 guides tell you to
use, and it is accepted into the file and then **silently ignored** — no error,
no log line, you simply are not an admin. If admin commands do nothing, this is
the first thing to check.

The prefix itself is worth not guessing at. The manual's example shape is
`Steam_`, while several projects shipped fixes after 1.0 for IDs arriving with a
`V_` prefix instead. Whichever your copy of the game hands you is the right one —
this container passes the file through untouched and validates nothing, so the
value you paste is the value the server sees.

Assume a restart is needed after editing these. Sources disagree about whether
the server re-reads them live, and being wrong in this direction costs you one
restart.

**`permittedlist.txt` is an allowlist and it locks out everyone not on it.** Iron
Gate's own wording is that adding one person to the permitted list bans everyone
else. A single stray entry will shut out every other player, including you. Leave
it empty unless you specifically want a closed server.

Admins use the in-game **F5** console for `kick`, `ban` and `save`. There is no
RCON and no remote console — see [Stopping safely](#stopping-safely) for why that
matters.

### World Name is not a rename

**World Name** picks which world the server loads, and creates it if it does not
exist. Changing it after first boot starts a *new* world. The old one stays on
disk and setting the name back returns to it. Nothing is renamed and nothing is
deleted.

### Starting over with a fresh world

Either set World Name to something new, or stop the container and delete
`savedir/worlds_local/<World Name>/`. Take a copy first if there is any chance
you want it back.

### Bringing an existing world in

Put it in `savedir/worlds_local/`. **Not `worlds/`** — the dedicated server does
not read that directory at all, and if your world is not in `worlds_local` the
server will not complain. It will quietly generate a brand new world and start up
looking perfectly healthy. That is the usual story behind "my world disappeared".
This container warns in the log if it finds something world-shaped in `worlds/`.

If the world was last played before Valheim 1.0, **copy it somewhere safe first**.
The first 1.0 load converts it to the new folder format, that conversion is
one-way, it can take several minutes, and interrupting it corrupts the world. Back
up before the first boot, not after — by the time the server is up, the one-way
door has already closed.

Characters are stored on each player's own machine, never on the server, so
worlds are the only thing there is to migrate.

## Stopping safely

**The shutdown save is the only save this container can ask for.** Valheim has no
RCON, no stdin console and no remote save command, so unlike most game servers
there is no second mechanism and nothing to fall back on if the stop goes wrong.

Measured on a real server: a stop took **4.2 seconds** end to end and the world
was written. That was an empty, freshly generated world — a real one with
explored terrain and buildings takes longer, and keeps growing.

The server also autosaves every 30 minutes by default, which you can shorten with
**Save Interval**. An ungraceful kill costs you whatever happened since the last
autosave.

### Stop timeout

Two numbers, and **both** have to be right:

- **Stop Timeout** in this template — how long the container waits for the server
  to finish saving. Default 120.
- **Unraid's own container stop timeout** — set this to at least **150**.

Docker's default grace period is 10 seconds. If you leave it there, Docker kills
the server partway through its save no matter what Stop Timeout says, and on
Unraid this is a single global setting rather than a per-container one. It is
worth checking after an Unraid update.

If a stop ever hits the timeout, the log says so plainly and tells you to raise
both numbers.

## Backups

The server has its own backup system and the template exposes it: **Backups to
Keep**, **First Backup Interval** and **Later Backup Interval**. Defaults are 4
backups, the first after 2 hours and the rest every 12.

These live beside the world in `savedir/worlds_local`, which means they protect
you from a corrupted save but not from losing that disk. Copy them somewhere else
for that. Do not point any backup tool *into* `worlds_local` — a backup that
lands inside the world directory ends up backing up the previous backups.

## Memory

Budget about **3GB** for an idle server and **6–8GB** for a busy long-running
world. Measured here: 1.4GB resident immediately after generating a world, with
nobody connected.

Memory use grows over time. This is a known, long-reported trait of this server
rather than anything about this container, and the usual answer is a scheduled
nightly restart — Unraid can do that on a schedule. A restart is safe as long as
the stop timeout is set correctly, because the stop saves the world.

Do not schedule a restart during a pre-1.0 world's first conversion. That takes
minutes and interrupting it corrupts the world.

CPU matters more as clock speed than as core count; the server is largely
single-threaded.

## Mods

There is no mod installer here, and none is needed: the server directory is bind
mounted, so installing BepInEx is a matter of unzipping it next to
`valheim_server.x86_64`. Mods then go in `BepInEx/plugins/`.

Every client must run the same mods as the server. Mods are reported not to load
at all when crossplay is on.

## Editing files over SMB

`UMASK` defaults to `000` and `Data Permissions` to `775`, which keeps the save
directory and the three permission lists editable over an Unraid share. Set UID
and GID to 99 and 100 so the files belong to `nobody:users` as the rest of Unraid
expects.

## Troubleshooting

**The container stops immediately and the log mentions the password.** One of the
three password rules. The log says which.

**The container stops with a message about a modifier or preset.** A typo in
World Preset, World Modifiers or World Toggles. The message lists the valid
values.

**I cannot find my server in Steam.** If Crossplay is on, that is expected —
it is in the in-game Community servers list instead. If it is off, check you
added the **query** port (game port plus 1) in Steam's Add a server box, not the
game port.

**My world is gone / it generated a new one.** The world was probably in
`worlds/` rather than `worlds_local/`, or World Name does not match the folder
name. Nothing is deleted by either mistake — stop the container, put the world in
`savedir/worlds_local/`, set World Name to match, and start it again.

**Admin commands do nothing.** The ID in `adminlist.txt` is almost certainly a
bare SteamID64. Use the `V_`-prefixed value from the in-game F2 panel and
restart.

**Nobody can join, including me, and there is no error.** Check
`permittedlist.txt` is empty. Anything in it locks out everyone else.

**The server binary is missing after a SteamCMD run.** Check free space on the
appdata path; the install needs about 2.1GB. Set **Validate Files** to `true` for
one start to have SteamCMD repair the install.

**It lost time on a stop.** The stop timeout. Raise both Stop Timeout and
Unraid's own container stop timeout, as described above.

## License

MIT — see [LICENSE](../../LICENSE).
