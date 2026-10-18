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

## 7. Open decisions (recommended defaults in **bold**)

1. **Server lifetime on app exit:** **ask, defaulting to graceful stop-all; tray mode keeps them running** — vs. full detach/reattach from day one.
2. **Platform:** **Linux-first behind a `PlatformBackend` abstraction** — vs. Linux + Windows from the start.
3. **Servers root:** **`~/MinecraftServers` (changeable in settings)** — vs. hidden inside Godot's `user://`.
4. **Version control:** **`git init` in Phase 0.**
