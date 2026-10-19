# Server Manager

A Godot 4.7 desktop app for hosting multiple **Paper** Minecraft servers on your own machine:
install, configure, start/stop, monitor, back up and update them from one interface.

## Features

- **Multiple servers**, listed in a sidebar with live status. A dashboard shows host CPU/RAM and every server at a glance.
- **New-server wizard**: pick a Minecraft version and the latest Paper build is downloaded from PaperMC, SHA-256 verified, cached and set up. The matching Java runtime is selected automatically and the EULA is accepted explicitly.
- **Lifecycle**: start, graceful stop (with a timeout that escalates to a kill), restart and force kill. Auto-restart after a crash uses back-off and crash-loop protection; servers can also start when the app opens.
- **Live console**: ANSI colours, filter by level or text, command history (↑/↓), Tab completion of commands and player names.
- **Settings editor**: one searchable, categorised form for `server.properties`, Paper's `config/paper-*.yml`, `spigot.yml`, `bukkit.yml` and game rules (PvP, keep inventory, Nether, mob spawning…). Only what applies to the server's Minecraft version is shown; descriptions are in tooltips. An "Edit files" mode edits the raw files. Comments, unknown keys and file layout are preserved. Game rules apply instantly when online, or are queued for the next start.
- **Gameplay defaults in the wizard**: game mode, difficulty, world type, max players, MOTD and seed up front, with every other setting under "More settings". Paper/Spigot/Bukkit values are written before the first boot, and game rules are applied once the world exists.
- **Duplicate** a server (optionally without worlds or plugins). It gets its own ports, and running servers are flushed to disk first.
- **Temporary test runs**: "Start temporary copy" runs a throwaway copy that shows as the same server. When it stops you choose to discard the changes or keep them (the previous files go to the trash). Copies are near-instant on btrfs/XFS (reflink).
- **Resources**: heap size, optional hard memory cap (cgroup), CPU quota, core pinning, process priority, Java runtime, JVM flag presets (Paper-recommended / Aikar), extra arguments, and a preview of the full launch command.
- **Network**: per-server ports with conflict detection. RCON is configured automatically and used for silent TPS and player queries.
- **Events**: per-server rules of the form *when → do*. Triggers: time of day, interval, app start, server online/stopped/crashed, player joined/left, server empty for N minutes, player count reached, TPS below a threshold, computer going to sleep or waking. Rules can be limited to certain weekdays, a time window and the server's state. Actions: start, stop, restart (with in-game countdowns), run a command, broadcast, world or full backup. Example: start Fri–Sun at 18:00 and stop once empty for 15 minutes. Older scheduled tasks are migrated automatically.
- **Start on connect**: while a server is stopped, the app answers on its port. The server shows in players' server lists with an "asleep" MOTD; a join attempt starts it, and the player is asked to reconnect in a few seconds. Optionally a server-list ping is enough to start it. Pair it with a "Stop when empty" event for a fully on-demand server.
- **Import worlds**: a downloaded map (.zip), a singleplayer save or another server's world, via the ⋮ menu, drag-and-drop, or "Start from an existing world" in the wizard. The world is found at any depth and its version checked against the server's (newer worlds are blocked). The Nether/End layout is converted to what the target Paper version expects. Bedrock worlds are refused. You can replace the current world (safety backup first) or add it as a new world, and optionally apply the map's game mode and difficulty.
- **Import existing servers**: detects Paper, Purpur, Spigot, vanilla, modded (refused) and proxies (refused) plus version, build, port, RAM, worlds and plugins. Manage the folder in place or copy it into the servers folder; non-Paper servers can switch to Paper. A server that is already running is re-attached.
- **Re-attaching**: servers keep running if the app closes or crashes ("Quit, leave running" makes this explicit). On the next launch they are found by PID file or process scan and re-attached: console from `logs/latest.log`, commands over RCON, uptime from the process. Only one Server Manager instance can run per settings profile.
- **Desktop notifications** (`notify-send`): always, only when the window isn't focused, or never, with per-category switches (crashes, start/stop, players, start on connect, backups, updates, sleep & shutdown, "Notify me" event actions).
- **Network tab**: LAN and public address, UPnP port forwarding (never the RCON port), an on-demand "Test from the internet" check (mcsrvstat.us), CGNAT/double-NAT diagnosis, firewall hints (ufw/firewalld) and RCON exposure guidance.
- **Logs tab**: browse past sessions (`latest.log` and the gzipped archives) and crash reports, with search and level filters. Crash reports get a summary card with the description, exception, version and a plain-language reason.
- **Worlds tab**: every world in the server with version, seed, size and last played; switch the active world, export a singleplayer-ready `.zip`, reset or regenerate with a new seed (safety backup first), delete, import, and manage datapacks (enable/disable live through RCON).
- **Player lists while offline**: whitelist, operators (with levels), player bans (with reasons) and IP bans can be edited while the server is stopped. UUIDs come from the server's user cache, Mojang (online mode) or the offline-mode algorithm.
- **Server icon**: pick or drop any image, crop it square, and it is scaled down cleanly to Minecraft's 64×64 `server-icon.png`, with a "Pixel art" mode and a server-list preview. GIF/AVIF/HEIC/ICO/TIFF/JXL/PSD are converted with ImageMagick, ffmpeg, vips or similar when installed.
- **Waking from sleep**: after a one-time setup (Preferences → Power, one password prompt; installs a small root helper that can only set the wake alarm and Wi-Fi wake-up, plus a polkit rule so it needs no password afterwards), the computer wakes about 90 s before events with "Wake computer" ticked (Start events by default). Experimental: wake on a player connecting to a start-on-connect server through Wi-Fi wake-on-WLAN (hardware dependent).
- **Interface size**: Automatic or 75–200 % in Preferences, applied live. Server tabs switch to icons only when the window is too narrow for their names.
- **Firewall housekeeping**: rules left open for ports no server uses anymore are listed in the Network tab and can be removed. Rules you added yourself are only removed with an explicit confirmation.
- **Failure reasons**: failed boots and crashes are explained in plain language (port in use, Java too old, out of memory, killed by the memory cap, EULA, missing jar).
- **Power & background**: works with systemd-logind so servers stop cleanly before sleep, shutdown and reboot. A sleep policy (block while players are online, always stop, block while running, or let it sleep) and restart-after-wake are in Preferences. Blocking only blocks sleep; the screen still turns off. Optional start at login (minimized).
- **Players**: online list with op/deop/kick/ban/message, plus whitelist, operator and ban list management.
- **Plugins**: list, enable/disable, delete, install via a file dialog or by dragging `.jar` files onto the window.
- **Backups**: world or full backups. Live backups pause autosave and flush the world first. Includes retention and restore.
- **Updates**: "new build available" detection, one-click Paper update or Minecraft version change (backup first, old jar kept).
- **Safety**: deleting a server requires typing its name and is permanent (nothing goes to the system trash). Restoring a backup or keeping a temporary copy first saves a safety backup of the current worlds to the server's backups. On quit you are asked whether to stop servers (worlds saved) or keep running. Servers left over from a crashed session are detected.

## Running

Open the project in Godot 4.7+ and press Play, or:

```sh
godot --path .
```

Requirements: Linux (resource limits use `systemd-run --user --scope`, `taskset`, `nice`; other
platforms fall back to plain `java` without limits), one or more JDKs (17/21/25 depending on the
Minecraft version), and internet access for downloads. Servers are created in `~/MinecraftServers`
by default (changeable in Settings); backups go to `<servers folder>/_backups/<server>`.

Command-line options (after `--`): `--no-autostart` skips auto-starting servers,
`--profile=<name>` uses a separate settings file.

Notes on Linux desktops: Godot cannot hide its main window or show a tray icon on Linux, so
"keep running in the background" minimizes the window. A suspended computer runs nothing, so
servers can only keep the PC awake (screen-off still works) or be stopped before sleep. logind
limits how long apps may delay sleep/shutdown (5 s by default); Preferences → Power can copy a
one-time command that raises it to 2 minutes. Killing the app with SIGTERM bypasses the clean
stop (Godot cannot catch signals); servers then save via Paper's own shutdown hook.

Shortcuts: `Ctrl+N` new server, `Ctrl+Enter` start/stop current server, ``Ctrl+` `` focus the
console, `Ctrl+Tab` next server.

## Project layout

```
scenes/              all UI is built as scenes (.tscn)
  main/              root scene: sidebar + content + dialogs + tray icon
  sidebar/ dashboard/ server_view/ (header + tabs/) dialogs/ components/
  runtime/server_instance.tscn   one per server: process, monitor, RCON, scheduler, backups
scripts/
  autoload/          AppSettings, JavaRuntimes, PaperApi, Notifier, ServerManager
  data/              ServerConfig, ServerProperties, YamlDoc, PropertySchema, SettingsCatalog,
                     ServerSettings, ScheduleEntry, JavaRuntime
  runtime/           ServerInstance state machine and its child nodes
  platform/          PlatformBackend / LinuxBackend (launch command, /proc stats)
  ui/                scene scripts
  util/              Ansi, LogParser, Fmt
themes/main_theme.tres   single project theme with type variations
tests/               headless unit tests and integration tests
```

Each server's settings live in `<server>/.manager/instance.json` (JSON, so a copied server folder
cannot carry executable resources). App settings are in `user://settings.json`.

## Tests

```sh
# Unit tests (headless, offline)
godot --headless --path . res://tests/test_runner.tscn -- --no-autostart --profile=test

# End-to-end: downloads Paper, boots it in a resource-limited scope, RCON, backup/restore, delete
godot --headless --path . res://tests/integration/integration_test.tscn -- --no-autostart --profile=it --root=/tmp/sm-it

# End-to-end: creation-time settings, game rules, live rule changes, duplicate while running,
# temporary runs (discard + keep). Try --version=1.20.4 for the legacy setting names.
godot --headless --path . res://tests/integration/feature_test.tscn -- --no-autostart --profile=ft --root=/tmp/sm-ft --version=26.3

# End-to-end: timed/condition events and simulated sleep/wake with real inhibitor locks
godot --headless --path . res://tests/integration/events_test.tscn -- --no-autostart --profile=ev --root=/tmp/sm-ev

# End-to-end: start on connect (asleep MOTD, join → boot, back to sleep, wake on ping)
godot --headless --path . res://tests/integration/wake_test.tscn -- --no-autostart --profile=wk --root=/tmp/sm-wk

# More end-to-end suites: reattach_test (run --phase=1 then --phase=2), server_import_test,
# world_import_test (--version=1.21.11|26.3 [--legacy-zip=<map.zip>]), failure_test, port_test,
# worlds_test, player_lists_test, server_icon_test, wake_sleep_test (simulated sleep, no Java)

# UI smoke test with screenshots of every view (needs a display)
godot --path . res://tests/integration/ui_smoke_test.tscn -- --no-autostart --profile=ui --root=/tmp/sm-ui --shots=/tmp/sm-shots
```
