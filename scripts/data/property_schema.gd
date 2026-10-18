class_name PropertySchema
extends RefCounted
## Metadata for well-known server.properties keys, used to build typed editors.

enum Type { BOOL, INT, STRING, ENUM }

const CATEGORIES: PackedStringArray = ["General", "Gameplay", "World", "Players & Security", "Network & Performance", "Resource Pack", "Other"]

## Keys the manager owns and rewrites before every start; hidden from the editor.
const MANAGED_KEYS: PackedStringArray = ["server-port", "enable-rcon", "rcon.port", "rcon.password", "broadcast-rcon-to-ops", "query.port"]

## key -> {type, category, label, desc, [min, max], [options], [core]}
## "core" keys are shown even before the server has generated its full properties file.
const KEYS := {
	"motd": {"type": Type.STRING, "category": "General", "label": "MOTD", "desc": "Message shown in the multiplayer server list. Supports § colour codes.", "core": true},
	"max-players": {"type": Type.INT, "category": "General", "label": "Max players", "min": 1, "max": 1000, "desc": "Maximum number of players online at once.", "core": true},
	"server-ip": {"type": Type.STRING, "category": "Network & Performance", "label": "Bind address", "desc": "Leave empty to listen on all interfaces."},
	"gamemode": {"type": Type.ENUM, "category": "Gameplay", "label": "Default game mode", "options": ["survival", "creative", "adventure", "spectator"], "core": true},
	"force-gamemode": {"type": Type.BOOL, "category": "Gameplay", "label": "Force game mode", "desc": "Players join in the default game mode every time."},
	"difficulty": {"type": Type.ENUM, "category": "Gameplay", "label": "Difficulty", "options": ["peaceful", "easy", "normal", "hard"], "core": true},
	"hardcore": {"type": Type.BOOL, "category": "Gameplay", "label": "Hardcore", "desc": "Players are set to spectator mode on death."},
	"pvp": {"type": Type.BOOL, "category": "Gameplay", "label": "PvP", "desc": "Allow players to damage each other.", "core": true},
	"allow-flight": {"type": Type.BOOL, "category": "Gameplay", "label": "Allow flight", "desc": "Do not kick players that fly in survival (needed by some plugins)."},
	"spawn-protection": {"type": Type.INT, "category": "Gameplay", "label": "Spawn protection radius", "min": 0, "max": 1000, "desc": "Radius around spawn non-ops cannot build in. 0 disables."},
	"enable-command-block": {"type": Type.BOOL, "category": "Gameplay", "label": "Command blocks"},
	"spawn-monsters": {"type": Type.BOOL, "category": "Gameplay", "label": "Spawn monsters"},
	"spawn-animals": {"type": Type.BOOL, "category": "Gameplay", "label": "Spawn animals"},
	"spawn-npcs": {"type": Type.BOOL, "category": "Gameplay", "label": "Spawn villagers"},
	"allow-nether": {"type": Type.BOOL, "category": "World", "label": "Allow Nether"},
	"level-name": {"type": Type.STRING, "category": "World", "label": "World folder", "desc": "Name of the world directory. Changing it creates/loads a different world.", "core": true},
	"level-seed": {"type": Type.STRING, "category": "World", "label": "Seed", "desc": "Only used when a new world is generated.", "core": true},
	"level-type": {"type": Type.ENUM, "category": "World", "label": "World type", "options": ["minecraft:normal", "minecraft:flat", "minecraft:large_biomes", "minecraft:amplified", "minecraft:single_biome_surface"]},
	"generator-settings": {"type": Type.STRING, "category": "World", "label": "Generator settings (JSON)"},
	"generate-structures": {"type": Type.BOOL, "category": "World", "label": "Generate structures"},
	"max-world-size": {"type": Type.INT, "category": "World", "label": "Max world radius", "min": 1, "max": 29999984},
	"view-distance": {"type": Type.INT, "category": "Network & Performance", "label": "View distance", "min": 2, "max": 32, "desc": "Chunks sent to clients. Big impact on RAM and CPU.", "core": true},
	"simulation-distance": {"type": Type.INT, "category": "Network & Performance", "label": "Simulation distance", "min": 2, "max": 32, "desc": "Chunks around players that are ticked.", "core": true},
	"online-mode": {"type": Type.BOOL, "category": "Players & Security", "label": "Online mode", "desc": "Verify accounts with Mojang. Disable only behind a proxy.", "core": true},
	"white-list": {"type": Type.BOOL, "category": "Players & Security", "label": "Whitelist", "desc": "Only whitelisted players may join.", "core": true},
	"enforce-whitelist": {"type": Type.BOOL, "category": "Players & Security", "label": "Enforce whitelist", "desc": "Kick non-whitelisted players when the whitelist reloads."},
	"enforce-secure-profile": {"type": Type.BOOL, "category": "Players & Security", "label": "Enforce secure chat profile"},
	"op-permission-level": {"type": Type.INT, "category": "Players & Security", "label": "Operator permission level", "min": 1, "max": 4},
	"function-permission-level": {"type": Type.INT, "category": "Players & Security", "label": "Function permission level", "min": 1, "max": 4},
	"player-idle-timeout": {"type": Type.INT, "category": "Players & Security", "label": "Idle kick (minutes)", "min": 0, "max": 1440, "desc": "0 disables idle kicking."},
	"hide-online-players": {"type": Type.BOOL, "category": "Players & Security", "label": "Hide online players in server list"},
	"prevent-proxy-connections": {"type": Type.BOOL, "category": "Players & Security", "label": "Block proxy/VPN connections"},
	"network-compression-threshold": {"type": Type.INT, "category": "Network & Performance", "label": "Compression threshold (bytes)", "min": -1, "max": 65535},
	"rate-limit": {"type": Type.INT, "category": "Network & Performance", "label": "Packet rate limit", "min": 0, "max": 100000, "desc": "Max packets per second per client. 0 disables."},
	"max-tick-time": {"type": Type.INT, "category": "Network & Performance", "label": "Watchdog max tick time (ms)", "min": -1, "max": 600000},
	"entity-broadcast-range-percentage": {"type": Type.INT, "category": "Network & Performance", "label": "Entity broadcast range %", "min": 10, "max": 1000},
	"sync-chunk-writes": {"type": Type.BOOL, "category": "Network & Performance", "label": "Synchronous chunk writes"},
	"use-native-transport": {"type": Type.BOOL, "category": "Network & Performance", "label": "Native transport (epoll)"},
	"enable-status": {"type": Type.BOOL, "category": "Network & Performance", "label": "Show in server list"},
	"enable-query": {"type": Type.BOOL, "category": "Network & Performance", "label": "GameSpy4 query"},
	"enable-jmx-monitoring": {"type": Type.BOOL, "category": "Network & Performance", "label": "JMX monitoring"},
	"resource-pack": {"type": Type.STRING, "category": "Resource Pack", "label": "Resource pack URL"},
	"resource-pack-sha1": {"type": Type.STRING, "category": "Resource Pack", "label": "Resource pack SHA-1"},
	"resource-pack-prompt": {"type": Type.STRING, "category": "Resource Pack", "label": "Prompt text"},
	"require-resource-pack": {"type": Type.BOOL, "category": "Resource Pack", "label": "Require resource pack"},
}

## Defaults written for a freshly created server (before its first boot).
const NEW_SERVER_DEFAULTS := {
	"motd": "A Minecraft Server",
	"max-players": "20",
	"gamemode": "survival",
	"difficulty": "easy",
	"pvp": "true",
	"online-mode": "true",
	"white-list": "false",
	"level-name": "world",
	"level-seed": "",
	"view-distance": "10",
	"simulation-distance": "10",
}


static func get_info(key: String) -> Dictionary:
	if KEYS.has(key):
		return KEYS[key]
	return {"type": Type.STRING, "category": "Other", "label": key}


static func is_managed(key: String) -> bool:
	return MANAGED_KEYS.has(key)


## Infers a type for unknown keys from their current value.
static func infer_type(key: String, value: String) -> Type:
	if KEYS.has(key):
		return KEYS[key].type
	if value == "true" or value == "false":
		return Type.BOOL
	if value.is_valid_int():
		return Type.INT
	return Type.STRING


static func core_keys() -> PackedStringArray:
	var out := PackedStringArray()
	for k in KEYS:
		if KEYS[k].get("core", false):
			out.append(k)
	return out
