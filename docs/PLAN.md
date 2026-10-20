# Minecraft Server Manager — Project Plan

A Godot 4.7 desktop application (GDScript) for installing, configuring, running and
monitoring multiple local **Paper** Minecraft servers from one clean interface.

---

## 1. Environment findings (verified 2026-10-18)

| Item | Finding | Impact |
|---|---|---|
| Godot | 4.7.2 stable, GDScript (no .NET) | Typed GDScript, `class_name`, `%UniqueName` nodes |
| `OS.execute_with_pipe(path, args, blocking)` | Returns `{stdio, stderr, pid}`; **non-blocking bidirectional pipe confirmed working** | Read console output and write commands without a native extension |
| Working directory | `execute_with_pipe` has **no cwd parameter** | Launch via `env -C <server_dir> …` (exec chain keeps the same PID) |
| Java | JDK 17, 21, 25, 27 installed under `/usr/lib/jvm` | Per-server Java selection is required (MC 1.17→16, 1.18–1.20.4→17, 1.20.5+→21, 26.x→25) |
| PaperMC API | Fill API v3: `https://fill.papermc.io/v3/projects/paper[/versions/{v}[/builds/latest]]` | Gives version list, **minimum Java version, recommended JVM flags**, build channel, jar URL and **SHA-256** |
| CPU/RAM limiting | `systemd-run --user --scope` works (cgroups v2: cpu, cpuset, memory), `taskset`, `nice`, `ionice` present | Real CPU quota / core pinning / hard memory cap per server |
| Built-ins | `ZIPPacker`, `HashingContext`, `StatusIndicator` (tray), `OS.move_to_trash` | Backups, checksum verify, tray icon, safe deletion — no addons needed |
| Host | 8 threads, 30 GB RAM | Sliders scale to detected host resources |

---

## 2. Feature scope

### Core (required)
- **Multiple servers** listed in a sidebar with live status; click to switch.
- **Install** a new server via a wizard: pick MC version → latest stable Paper build is downloaded
  (SHA-256 verified, cached), `eula.txt` + `server.properties` written, Java auto-selected.
- **Delete** a server (must be stopped; type-the-name confirmation; moved to system trash by default).
- **Start / Stop / Restart / Kill** with a proper state machine and graceful `stop` + timeout → kill.
- **Live console**: colored output, command input with history (↑/↓) and Tab completion, search, autoscroll toggle.
- **Server settings**: typed form for `server.properties` (port, MOTD, gamemode, difficulty, max players,
  view distance, whitelist, PvP, …) plus raw-text fallback; unknown keys and comments preserved.
- **Resource allocation**: RAM (`-Xms/-Xmx`), CPU core count / core pinning / CPU quota %, process
  priority, optional hard memory cap — all validated against host capacity.
- **Auto-restart on crash** with back-off and crash-loop protection; **auto-start on app launch**.
- **Ports**: per-server port with conflict detection (other managed servers + OS-level bind test).

### Extended ("reasonable customizations")
- **Monitoring**: CPU %, RAM (RSS), uptime, players online, TPS; history graphs; all-servers dashboard with host totals.
- **Scheduled tasks**: daily/interval restarts with in-game countdown broadcasts, scheduled commands, scheduled backups.
- **Backups**: world or full-server zip (safe `save-off` / `save-all flush` / `save-on` while running), retention policy, restore.
- **Paper updates**: "new build available" badge, one-click update (old jar kept for rollback), MC version upgrade with warning.
- **Plugins**: list / enable / disable / delete `.jar`s, drag-and-drop install onto the window.
- **Players**: online list, op / deop / kick / ban, whitelist + ops + bans editors.
- **JVM**: flag presets (Paper-recommended from API / Aikar's / none) + custom extra args.
- **Java runtime manager**: detected JDKs with versions; per-server override.
- **App shell**: system tray (keep servers running while window closed), toast notifications (crash, restart, backup done),
  open server folder, copy connect address (LAN IP:port), keyboard shortcuts, remembered UI state.

### Stretch (later, optional)
- Detach/reattach: servers survive app exit; reattach on next launch via PID file + RCON + `logs/latest.log` tail.
- Plugin search/install from Hangar / Modrinth.
- Built-in file browser / YAML editor for `paper-global.yml`, `bukkit.yml`, etc.
- Import an existing server folder; clone a server.
- Windows/macOS platform backends.

---

## 3. Architecture

Godot conventions applied throughout: **autoloads for global services**, **scenes as composable UI
components**, **signals up / calls down**, **custom `Resource` classes for data**, typed GDScript,
`%UniqueName` node access, a single project `Theme` (no ad-hoc per-node overrides), `Timer` nodes instead of
polling in `_process`, worker `Thread`s + `Mutex` + `call_deferred` for blocking work, and
`low_processor_usage_mode` so the manager itself idles near 0 % CPU.

### 3.1 Autoloads (global services)

| Autoload | Responsibility |
|---|---|
| `AppSettings` | App preferences (servers root dir, defaults, on-exit behaviour, console limits, accent colour). Persists to `user://settings.json`. |
| `JavaRuntimes` | Detects JDKs (`/usr/lib/jvm`, `JAVA_HOME`, `PATH`), runs `java -version`, picks the best match for a required major version. |
| `PaperApi` | Fill v3 client (`HTTPRequest`): versions, builds, Java requirements, recommended flags; jar download with progress, SHA-256 verify, shared cache. |
| `ServerManager` | Registry of `ServerInstance` nodes; create / import / delete; start-all / stop-all; app-exit orchestration. Emits `server_added`, `server_removed`, `server_state_changed`. |
| `Notifier` | Toasts + tray notifications. |

### 3.2 Data (Resources / RefCounted)

- `ServerConfig extends Resource` — id, display name, icon colour, MC version, Paper build, java path,
  `ram_min_mb`, `ram_max_mb`, `memory_hard_cap`, `cpu_cores`, `cpu_affinity`, `cpu_quota_pct`, `nice`,
  JVM preset + extra args, port, auto-start, auto-restart (+ max retries / window), schedules, backup policy,
  RCON port/password. Serialized to JSON (`to_dict` / `from_dict`) at `<server>/.manager/instance.json`
  — JSON rather than `.tres` so a copied server folder can never carry executable script resources.
- `ServerProperties extends RefCounted` — parse/write `server.properties` **preserving order, comments and unknown keys**.
- `PropertySchema` — table of known keys: type, range/options, category, description, "requires restart".
- `ScheduleEntry extends Resource` — kind (restart / command / backup), interval or daily time, warning offsets.
- `JavaRuntime extends RefCounted` — path, major version, vendor.

### 3.3 Runtime (per server, all children of `ServerManager`)

```
ServerManager (autoload Node)
└── ServerInstance (Node)            # one per server; owns config + state machine
    ├── ServerProcess (Node)         # launch, pipe I/O, exit detection
    ├── ResourceMonitor (Timer)      # /proc/<pid>/stat + status sampling → CPU %, RSS
    ├── RconClient (Node)            # StreamPeerTCP RCON for silent queries (tps, list)
    ├── TaskScheduler (Timer)        # scheduled restarts / commands / backups
    └── BackupService (Node)         # zip on worker thread
```

**State machine:** `STOPPED → STARTING → RUNNING → STOPPING → STOPPED`, plus `CRASHED`, `INSTALLING`, `UPDATING`.
- `STARTING → RUNNING` when the console prints `Done (…)! For help, type "help"`.
- Exit without a requested stop → `CRASHED` → auto-restart with back-off (e.g. 5 s, 15 s, 60 s); give up after
  N crashes within a window and notify.
- Stop = write `stop` to stdin, wait (configurable, default 60 s), then terminate/kill.

**Launch command (Linux backend):**
```
systemd-run --user --scope --quiet -p CPUQuota=<q>% [-p MemoryMax=<cap>] --
  env -C <server_dir>
  taskset -c <cores> nice -n <n>
  <java> -Xms<min>M -Xmx<max>M -XX:ActiveProcessorCount=<cores> <preset flags> <extra>
  -Dterminal.jline=false -Dterminal.ansi=true -jar paper.jar --nogui
```
Every wrapper `exec`s, so the PID returned by Godot is the JVM's PID → monitoring works directly.
Wrappers are only added when the corresponding limit is enabled; the hard memory cap defaults to
`Xmx + overhead` so the kernel never OOM-kills a healthy JVM. Command building lives behind a
`PlatformBackend` interface so a Windows backend can be added later.

**Console I/O:** non-blocking pipe drained on a short `Timer` (≈50 ms) into a line splitter → `line_received`
signal → bounded ring buffer (default 5 000 lines) that the console view renders. ANSI → BBCode conversion,
plus log-level colouring (`INFO`/`WARN`/`ERROR`) and player join/leave detection.

**RCON:** enabled automatically on a localhost-only port with a random password; used for TPS / player
queries so metric polling never clutters the visible console.

### 3.4 On-disk layout

```
~/MinecraftServers/                 (configurable "servers root")
├── survival-a1b2/
│   ├── paper.jar  eula.txt  server.properties  plugins/  world/ …
│   └── .manager/instance.json      (ServerConfig) + old jars for rollback
└── _backups/survival-a1b2/2026-10-18_03-00-00_world.zip
user://settings.json                (AppSettings, list of known server dirs)
user://cache/jars/<sha256>.jar      (shared download cache)
```

### 3.5 Project file structure

```
res://
├── assets/icons/*.svg               play, stop, restart, kill, plus, trash, folder, …
├── themes/main_theme.tres           dark theme, accent colour, type variations
├── scripts/
│   ├── autoload/   app_settings.gd  java_runtimes.gd  paper_api.gd  server_manager.gd  notifier.gd
│   ├── data/       server_config.gd  server_properties.gd  property_schema.gd  schedule_entry.gd  java_runtime.gd
│   ├── runtime/    server_instance.gd  server_process.gd  resource_monitor.gd  rcon_client.gd
│   │               task_scheduler.gd  backup_service.gd  log_parser.gd  download_task.gd
│   ├── platform/   platform_backend.gd  linux_backend.gd
│   └── util/       ansi_to_bbcode.gd  format.gd  slug.gd
├── scenes/
│   ├── main/main.tscn                                   root layout
│   ├── sidebar/server_list.tscn  server_list_item.tscn
│   ├── dashboard/dashboard.tscn                         "All servers" overview
│   ├── server_view/server_view.tscn  server_header.tscn
│   │   └── tabs/ overview  console  properties  resources  automation  players  plugins  backups (.tscn each)
│   ├── dialogs/ new_server_wizard  delete_server_dialog  app_settings_dialog  quit_dialog
│   └── components/ stat_card  line_graph  property_row  toast  slider_field
└── tests/ run_tests.gd + test_*.gd                      headless: godot --headless --script tests/run_tests.gd
```

---

## 4. UI layout

```
┌──────────────────────┬────────────────────────────────────────────────────────────────┐
│  ⛏ Server Manager    │  ● Survival            1.21.11 · Paper #42      [▶ Start] [⟳] [■] [⚠ Kill] │
│ ──────────────────── │  RUNNING · up 3h12m · 4/20 players · 19.98 TPS · CPU 23% · RAM 3.1/6 GB    │
│ ▣ Dashboard          │ ─────────────────────────────────────────────────────────────── │
│ ──────────────────── │ [Overview][Console][Settings][Resources][Automation][Players][Plugins][Backups]
│ ● Survival    4/20   │                                                                  │
│ ● Creative    0/10   │ [15:02:11 INFO]: Steve joined the game                            │
│ ○ Modded test        │ [15:02:40 WARN]: Can't keep up! Is the server overloaded?        │
│ ✕ Minigames (crash)  │ …                                                                │
│                      │                                                                  │
│ [+ New Server]       │ > say hello█                                     [Send]          │
│ [⚙ Settings]         │                                                                  │
└──────────────────────┴────────────────────────────────────────────────────────────────┘
```
Status dot colours: green running, amber starting/stopping, grey stopped, red crashed, blue installing.

**New Server wizard:** Name & colour → Version (list from API, toggle to show pre-releases, support status
& Java requirement shown) → Resources & port (pre-filled from defaults, live validation) → Gameplay basics
(gamemode, difficulty, max players, MOTD, seed, online-mode) → EULA checkbox with link → progress view
(download → verify → write files) → "Start now?".

---

## 5. Implementation phases

Each phase ends in a runnable app and passing headless tests.

| # | Phase | Deliverables |
|---|---|---|
| 0 | **Foundation** | `git init`; project settings (Compatibility renderer, low-processor mode, window size/min size, `auto_accept_quit=false`); folder structure; theme + icons; autoload stubs; headless test runner |
| 1 | **Data & services** | `ServerConfig`, `AppSettings`, `ServerProperties` (round-trip tests), `PropertySchema`, `JavaRuntimes`, `PaperApi` + verified, cached downloads |
| 2 | **Process runtime** | `PlatformBackend`/`LinuxBackend` command builder (tests), `ServerProcess` pipe I/O, `ServerInstance` state machine, graceful stop/kill, crash detection + auto-restart, quit handling. Integration test: install & boot a real Paper server headlessly |
| 3 | **UI shell** | Main layout, sidebar list, server header + controls, Console tab, New Server wizard, Delete dialog, App Settings dialog |
| 4 | **Configuration UI** | Settings (properties) tab, Resources tab with host-aware sliders, Automation tab, port validation |
| 5 | **Monitoring** | `ResourceMonitor`, `RconClient`, line graphs, Overview tab, Dashboard |
| 6 | **Extended features** | Backups, scheduled tasks, Paper updates, Plugins tab, Players tab, tray + notifications |
| 7 | **Polish** | Shortcuts, persisted UI state, error/empty states, README |

---

## 6. Risks & mitigations

| Risk | Mitigation |
|---|---|
| App closes while servers run (stdin pipe lost) | Quit dialog: *Stop all gracefully* (default) / *Minimize to tray* / *Cancel*. True detach is a stretch goal. |
| Wrong Java version → server won't boot | Java requirement read from Paper API; auto-select; block start with a clear message if none fits. |
| Two servers on one port | Validation against managed servers + bind test before start. |
| Over-allocating RAM | Sliders capped at host RAM; warning when total allocation of running servers exceeds host minus a reserve. |
| Corrupt/partial download | Download to temp file → SHA-256 verify → atomic move. |
| Corrupt backup of a live world | `save-off` + `save-all flush` (wait for confirmation) before zipping; `save-on` afterwards, even on failure. |
| UI stalls | All network / zip / process-probe work async or on worker threads. |
| Accidental deletion | Server must be stopped, type-name confirmation, `OS.move_to_trash` by default. |

---

## 7. Decisions (accepted 2026-10-18)

1. Server lifetime on app exit: ask (stop all gracefully / keep running in background); servers left over from a crashed session are detected via a PID file and can be stopped from the UI.
2. Platform: Linux-first behind `PlatformBackend`.
3. Servers root: `~/MinecraftServers`, changeable in Settings.
4. Version control: git.

## 8. Status

Phases 0–7 implemented. Remaining stretch goals: full detach/reattach (console via log tail + RCON),
Hangar/Modrinth plugin search, in-app YAML config editor, import of existing non-managed servers,
Windows/macOS backends.

## 9. Wake the computer from sleep (built; needs a real sleep test by the user)

Findings on the user's machine: RTC `rtc_cmos` with alarm support, suspend mode `deep`;
Wi-Fi (wlan0, phy0) supports WoWLAN magic packet + 1 pattern (≤128 bytes, offset 0); Ethernet
enp12s0 unplugged; `rtcwake`, `pkexec`, `iw` available.

- One-time setup (one password prompt, explicit button in Preferences → Power): install a
  root-owned helper `/usr/local/libexec/server-manager-wake` (validates args; `alarm <epoch>|clear`
  writes /sys/class/rtc/rtc0/wakealarm; `wowlan <phy> on <pattern>|off` runs `iw phy … wowlan`) and
  a polkit action (`/usr/share/polkit-1/actions/…wake.policy`, exec.path annotation,
  allow_active=yes) so later calls need no password. Offer removal too.
- Scheduled wake: per-event "Wake computer" flag (default on for Start). On PrepareForSleep(true)
  set the RTC alarm to the earliest flagged timed event − ~90 s; clear it after wake. Hold the sleep
  delay lock whenever such events exist (even with no server running).
- Connect wake (experimental): WoWLAN magic-packet + one pattern matching a TCP SYN to the
  server's port in 802.3 form: dst MAC, ethertype 08:00, byte 14 = 45, byte 23 = 06, bytes 36–37 =
  port, byte 47 = 02, everything else wildcard ("-"). One pattern only → one port (wildcard the port
  if several servers use start-on-connect). Works only if the platform keeps Wi-Fi powered in S3;
  must be verified by the user with a real sleep test. Pair with start-on-connect.
- Tests: pattern builder, wake-time computation, helper argument validation, PowerManager with a
  mock helper path (no real sleep in automated tests).

## 10. Remote access (built and tested: every tab, uploads, preferences, keys)

Another person running Server Manager connects to this computer with an **access key**
(a shared secret) and controls servers according to the key's role.

**Roles**
- *System admin*: every server plus computer-wide actions (create, duplicate, delete servers).
  On the client, the sidebar's host switcher swaps "This computer" for the remote computer.
- *Server admin*: only the servers listed on the key, and only server-level actions (start/stop,
  console, settings, Paper updates, icon, temporary runs). Their servers appear in the client's
  sidebar under **Remote servers**. Never: Java executable / JVM arguments (would run arbitrary
  programs), firewall/router, app preferences, creating or deleting servers.
  (Plugins they upload run code as the host user — the key dialog warns about that.)

**Security**
- Transport: TLS (mbedTLS via StreamPeerTLS) with the host's self-signed certificate (RSA 2048,
  `user://remote/`, mode 600). The client pins it.
- Getting the certificate: a plain "bootstrap" exchange returns the certificate plus
  HMAC-SHA256(secret, "cert" ‖ client nonce ‖ PEM). Only someone with the key can produce it,
  so a man in the middle cannot slip in its own certificate. Re-done automatically if the
  pinned certificate stops matching.
- Authentication inside TLS: host nonce, client nonce, HMAC proofs both ways, compared in
  constant time. Keys are 256-bit random, so offline guessing is not a concern.
- Rate limiting: 5 failed attempts from an address → blocked for 15 min; handshake timeout
  10 s; at most 8 unauthenticated connections; 4 KB frame limit before authentication.
- Every request is checked against the key's role and server list on the host; revoking a
  key or removing a server from it disconnects/updates live sessions. Remote actions are
  logged in the server console as "[Remote · name]".
- Secrets are stored in `user://remote/*.json` (mode 600).

**Protocol** (after the 1-byte mode prefix 'B' bootstrap / 'T' TLS): frames are a 4-byte
little-endian length + UTF-8 JSON. Requests `{id, op, server?, args}` → `{re, ok, result|error}`;
events `{ev, server?, …}` pushed by the host (server snapshot, stats, console batches,
added/removed, progress of long operations). Protocol version must match.

**Code structure**
- `ServerHandle` (base of `ServerInstance` and `RemoteServer`): state, signals and the
  operations the UI uses. Local calls return immediately; remote ones `await` the host.
- Host: `RemoteAccess` autoload (keys, certificate, listener) → `RemoteSession` per client.
- Client: `RemoteHosts` autoload (saved computers) → `RemoteLink` per computer → `RemoteServer`
  proxies. `ServerSource` is the common base of `ServerManager` and `RemoteLink` (server lists).
- Tabs opt in with `remote_ready` (all of them now); a tab without it would be hidden for
  remote servers.

**Phase 1** (done): keys, connections, sidebar sections, host switcher; header controls,
Overview, Console, Settings; Paper update, temporary-run decisions, icon; remote create/delete
for system admins.

**Phase 2** (done):
- One request path for every tab: `ServerHandle.call_op(op, args, on_progress)`. Local servers
  run `ServerOps.run(instance, op, args, ctx)` directly; remote ones send the same op to the
  host, whose session checks the role and runs the same `ServerOps` code. Results are plain
  JSON-safe dictionaries, so tabs render local and remote servers the same way.
- `ServerHandle.data_changed(area)` ("plugins", "backups", "worlds", "lists", "logs") tells
  open views to reload; the host forwards it to every session that sees the server.
- File transfers in chunks (512 KB, acknowledged, so pings and other requests keep flowing):
  `upload_begin/chunk/end` stage a file on the host (per session, deleted when the session ends);
  ops then take upload ids, never host paths. Downloads (`download_chunk/close`) serve files an
  op registered (backup zips, world exports). Folders are zipped on the client before upload.
- Server admins (their servers only): plugins (upload, enable, delete), worlds (upload/import,
  switch, reset, delete, export/download, datapacks), backups (create, restore, delete,
  download), logs, player lists, automation rules, resources (RAM/CPU/priority/port) and the
  network tab's read-only status plus the reachability test.
  Not for server admins: Java executable, JVM/server arguments, "wake the computer" on rules,
  UPnP forwarding, firewall rules, DHCP note, app preferences, other servers, access keys.
- System admins: everything a local user can do: all of the above plus Java/JVM settings,
  UPnP, firewall (the password prompt appears on the host's screen), Preferences of the host
  (servers folder, defaults, sleep/wake, start at login, Java runtimes, the host's
  notifications), importing a server (uploaded as a zip) and managing the host's access keys.
  Display-only preferences (interface size, console length) stay per computer.
- Waking a sleeping host (both roles): with "Wake on connection" on and remote access enabled,
  the host's Wi-Fi wake pattern also watches the remote-access port (any port when several are
  wanted; the card takes one pattern). The welcome tells clients the Wi-Fi MAC when this is ready;
  "Wake" (server header, remote dashboard, the computer's row) sends magic packets and reconnects
  every 3 s for up to 2 min. It only wakes; starting is separate. Remote requests hold an idle
  inhibitor for 10 min so the woken computer doesn't doze off while someone works on it.

## 11. Distribution and Windows support

**Packages** (`packaging/build.sh` → `dist/`): an Arch package (`packaging/arch/PKGBUILD`,
binary in /opt/server-manager, `server-manager` command, desktop entry, icons; depends on a
`java-runtime`), a plain Linux tarball, a Windows installer (NSIS, per-user, no admin rights:
Start menu and optional desktop shortcut, uninstaller that also removes the login entry and the
wake-up task, keeps settings and servers) and a portable Windows zip. Exports embed the .pck;
icons are rendered from icon.svg by `packaging/make_icons.gd`.

**Windows backend** (`WindowsBackend`, untested on real Windows so far):
- Servers start from `.manager\launch.cmd` (cd into the folder, then Java; `start /b /wait` adds
  priority and core pinning). Stats, kills and re-attaching follow the cmd.exe to its java.exe.
- One PowerShell helper per app run reports host/process stats and sleep/wake events once a
  second and keeps the computer awake (SetThreadExecutionState) while sleep should be blocked.
- No CPU quota or hard memory cap. Windows can't delay sleep for an app: servers pause while it
  sleeps; event wake-ups are a scheduled task with "wake to run"; connection wake-ups are
  Wake-on-LAN magic packets (the adapter must allow them).
- Windows Firewall: checks for port or Java rules in the background, adds and removes the app's
  own rules (group "Server Manager") through a UAC prompt. Toast notifications, login autostart
  through the user's Run key.

## 12. Permissions (LuckPerms)

A Permissions tab per server (local and remote, server admins and up) manages LuckPerms:
groups (weight, prefix, parents, permissions), players (groups, permissions, promote/demote)
and tracks (order). "Install LuckPerms" downloads the latest Paper build from luckperms.net.

- **Reading:** `/lp export <unique name>` over RCON, then the app reads and deletes the gzip JSON
  file. Player names come from the export or usercache.json.
- **Changing:** `/lp` commands over RCON, built from validated changes (names, nodes, contexts
  and durations can't inject other arguments). LuckPerms' replies never reach RCON, so each
  batch is followed by an export and every change is checked against it; ones that didn't take
  effect are reported.
- **Stopped servers:** LuckPerms keeps its data in H2, which only it can read, so the last export
  (`.manager/luckperms.json`) is shown read-only until the server runs again.
- Verified with LuckPerms 5.5.87 on Paper 26.3 (`tests/integration/luckperms_test.gd`,
  `permissions_ui_test.gd`).

## 13. Plugin browser (Modrinth)

Plugins tab → **Get plugins** searches Modrinth (relevance, downloads, recently updated, newest)
for Paper, Spigot and Bukkit plugins (Paper runs all three) for the server's Minecraft version.

- Search filters apply to whole projects, so each result is checked for a version with a
  Paper-compatible loader that lists the server's version; results without one are left out.
- Plugins Server Manager integrates with (`ModrinthApi.INTEGRATIONS`, e.g. LuckPerms → Permissions
  tab) are listed first and install from their official source.
- Installing runs on the server's computer (`plugin_install_modrinth`, server admins and up): the
  newest compatible release, checked by SHA-1, plus required plugins (3 levels deep); an installed
  copy of the same project is replaced (update). Installed jars are recognised by hash.
- The Permissions tab's **Browse…** lists permissions declared in the installed plugins'
  plugin.yml, Minecraft's commands (from `minecraft:help`) and Paper's/LuckPerms' main ones.

## 14. Chunky (chunk pre-generation)

A Chunky tab (shown with an Install button until Chunky is installed from Modrinth) starts
tasks on a running server: generate an area (Chunky's nine shapes, centred on spawn, the world
border's centre or coordinates), fill the world border, or **load existing chunks only** (Chunky's
`world` pattern: it visits the chunks saved in the region files and generates nothing new, for
maps surrounded by void). Tasks show progress (from Chunky's console lines), can be paused,
continued and cancelled, and continue after a restart. **Trim** deletes chunks outside (or inside)
an area after a world backup; the server must restart afterwards.

- Worlds use Paper's Bukkit names: `<level>`, `<level>_nether`, `<level>_the_end`, and
  `<level>_<namespace>_<dimension>` for extra dimensions (verified with an imported dimension).
- Commands answer over RCON. Cancel asks for `/chunky confirm`, which the app sends; a cancelled
  task's thread still logs "stopped", which must not bring it back.
- Verified with Chunky 1.5.3 on Paper 26.3 (`tests/integration/chunky_test.gd`).
