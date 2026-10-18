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

# UI smoke test with screenshots of every view (needs a display)
godot --path . res://tests/integration/ui_smoke_test.tscn -- --no-autostart --profile=ui --root=/tmp/sm-ui --shots=/tmp/sm-shots
```
