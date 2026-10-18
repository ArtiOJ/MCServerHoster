class_name PropertySchema
extends RefCounted
## Metadata for well-known server.properties keys, used to build typed editors.

enum Type { BOOL, INT, STRING, ENUM, FLOAT }

const CATEGORIES: PackedStringArray = ["General", "Gameplay", "World", "Players & Security", "Network & Performance", "Resource Pack", "Other"]

## Keys the manager owns and rewrites before every start; hidden from the editor.
const MANAGED_KEYS: PackedStringArray = ["server-port", "enable-rcon", "rcon.port", "rcon.password", "broadcast-rcon-to-ops", "query.port"]

## key -> {type, category, label, desc, default, [min, max], [options], [core], [since], [until]}
## "core" keys are shown even before the server has generated its full properties file.
## "since"/"until" gate keys by Minecraft version (until = first version without the key).
const KEYS := {
	"motd": {"type": Type.STRING, "category": "General", "label": "MOTD", "desc": "Message shown in the multiplayer server list. Supports § colour codes.", "core": true, "default": "A Minecraft Server"},
	"max-players": {"type": Type.INT, "category": "General", "label": "Max players", "min": 1, "max": 1000, "desc": "Maximum number of players online at once.", "core": true, "default": "20"},
	"server-ip": {"type": Type.STRING, "category": "Network & Performance", "label": "Bind address", "desc": "Leave empty to listen on all interfaces.", "default": ""},
	"gamemode": {"type": Type.ENUM, "category": "Gameplay", "label": "Default game mode", "options": ["survival", "creative", "adventure", "spectator"], "core": true, "default": "survival"},
	"force-gamemode": {"type": Type.BOOL, "category": "Gameplay", "label": "Force game mode", "desc": "Players join in the default game mode every time.", "default": "false"},
	"difficulty": {"type": Type.ENUM, "category": "Gameplay", "label": "Difficulty", "options": ["peaceful", "easy", "normal", "hard"], "core": true, "default": "easy"},
	"hardcore": {"type": Type.BOOL, "category": "Gameplay", "label": "Hardcore", "desc": "Players are set to spectator mode on death.", "default": "false"},
	"pvp": {"type": Type.BOOL, "category": "Gameplay", "label": "PvP", "desc": "Allow players to damage each other.", "core": true, "default": "true", "until": "1.21.9"},
	"allow-flight": {"type": Type.BOOL, "category": "Gameplay", "label": "Allow flight", "desc": "Do not kick players that fly in survival (needed by some plugins).", "default": "false"},
	"spawn-protection": {"type": Type.INT, "category": "Gameplay", "label": "Spawn protection radius", "min": 0, "max": 1000, "desc": "Radius around spawn non-ops cannot build in. 0 disables.", "default": "16"},
	"enable-command-block": {"type": Type.BOOL, "category": "Gameplay", "label": "Command blocks", "default": "false", "until": "1.21.9"},
	"spawn-monsters": {"type": Type.BOOL, "category": "Gameplay", "label": "Spawn monsters", "default": "true", "until": "1.21.9"},
	"spawn-animals": {"type": Type.BOOL, "category": "Gameplay", "label": "Spawn animals", "default": "true", "until": "1.21.2"},
	"spawn-npcs": {"type": Type.BOOL, "category": "Gameplay", "label": "Spawn villagers", "default": "true", "until": "1.21.2"},
	"allow-nether": {"type": Type.BOOL, "category": "World", "label": "Allow Nether", "default": "true", "until": "1.21.9"},
	"level-name": {"type": Type.STRING, "category": "World", "label": "World folder", "desc": "Name of the world directory. Changing it creates/loads a different world.", "core": true, "default": "world"},
	"level-seed": {"type": Type.STRING, "category": "World", "label": "Seed", "desc": "Only used when a new world is generated.", "core": true, "default": ""},
	"level-type": {"type": Type.ENUM, "category": "World", "label": "World type", "options": ["minecraft:normal", "minecraft:flat", "minecraft:large_biomes", "minecraft:amplified", "minecraft:single_biome_surface"], "default": "minecraft:normal"},
	"generator-settings": {"type": Type.STRING, "category": "World", "label": "Generator settings (JSON)", "default": "{}"},
	"generate-structures": {"type": Type.BOOL, "category": "World", "label": "Generate structures", "default": "true"},
	"max-world-size": {"type": Type.INT, "category": "World", "label": "Max world radius", "min": 1, "max": 29999984, "default": "29999984"},
	"view-distance": {"type": Type.INT, "category": "Network & Performance", "label": "View distance", "min": 2, "max": 32, "desc": "Chunks sent to clients. Big impact on RAM and CPU.", "core": true, "default": "10"},
	"simulation-distance": {"type": Type.INT, "category": "Network & Performance", "label": "Simulation distance", "min": 2, "max": 32, "desc": "Chunks around players that are ticked.", "core": true, "default": "10"},
	"online-mode": {"type": Type.BOOL, "category": "Players & Security", "label": "Online mode", "desc": "Verify accounts with Mojang. Disable only behind a proxy.", "core": true, "default": "true"},
	"white-list": {"type": Type.BOOL, "category": "Players & Security", "label": "Whitelist", "desc": "Only whitelisted players may join.", "core": true, "default": "false"},
	"enforce-whitelist": {"type": Type.BOOL, "category": "Players & Security", "label": "Enforce whitelist", "desc": "Kick non-whitelisted players when the whitelist reloads.", "default": "false"},
	"enforce-secure-profile": {"type": Type.BOOL, "category": "Players & Security", "label": "Enforce secure chat profile", "default": "true"},
	"op-permission-level": {"type": Type.INT, "category": "Players & Security", "label": "Operator permission level", "min": 1, "max": 4, "default": "4"},
	"function-permission-level": {"type": Type.INT, "category": "Players & Security", "label": "Function permission level", "min": 1, "max": 4, "default": "2"},
	"player-idle-timeout": {"type": Type.INT, "category": "Players & Security", "label": "Idle kick (minutes)", "min": 0, "max": 1440, "desc": "0 disables idle kicking.", "default": "0"},
	"hide-online-players": {"type": Type.BOOL, "category": "Players & Security", "label": "Hide online players in server list", "default": "false"},
	"prevent-proxy-connections": {"type": Type.BOOL, "category": "Players & Security", "label": "Block proxy/VPN connections", "default": "false"},
	"network-compression-threshold": {"type": Type.INT, "category": "Network & Performance", "label": "Compression threshold (bytes)", "min": -1, "max": 65535, "default": "256"},
	"rate-limit": {"type": Type.INT, "category": "Network & Performance", "label": "Packet rate limit", "min": 0, "max": 100000, "desc": "Max packets per second per client. 0 disables.", "default": "0"},
	"max-tick-time": {"type": Type.INT, "category": "Network & Performance", "label": "Watchdog max tick time (ms)", "min": -1, "max": 600000, "default": "60000"},
	"entity-broadcast-range-percentage": {"type": Type.INT, "category": "Network & Performance", "label": "Entity broadcast range %", "min": 10, "max": 1000, "default": "100"},
	"sync-chunk-writes": {"type": Type.BOOL, "category": "Network & Performance", "label": "Synchronous chunk writes", "default": "true"},
	"use-native-transport": {"type": Type.BOOL, "category": "Network & Performance", "label": "Native transport (epoll)", "default": "true"},
	"enable-status": {"type": Type.BOOL, "category": "Network & Performance", "label": "Show in server list", "default": "true"},
	"enable-query": {"type": Type.BOOL, "category": "Network & Performance", "label": "GameSpy4 query", "default": "false"},
	"enable-jmx-monitoring": {"type": Type.BOOL, "category": "Network & Performance", "label": "JMX monitoring", "default": "false"},
	"accepts-transfers": {"type": Type.BOOL, "category": "Network & Performance", "label": "Accept transfers", "desc": "Allow players to be transferred here from other servers with /transfer.", "default": "false", "since": "1.20.5"},
	"region-file-compression": {"type": Type.ENUM, "category": "World", "label": "Region file compression", "options": ["deflate", "lz4", "none"], "desc": "Compression used for world region files. lz4 is faster but larger.", "default": "deflate", "since": "1.20.5"},
	"log-ips": {"type": Type.BOOL, "category": "Players & Security", "label": "Log player IPs", "default": "true", "since": "1.20.2"},
	"pause-when-empty-seconds": {"type": Type.INT, "category": "Network & Performance", "label": "Pause when empty (seconds)", "min": -1, "max": 86400, "desc": "Stop ticking the world after it has been empty this long. -1 disables.", "default": "-1", "since": "1.21.2"},
	"resource-pack": {"type": Type.STRING, "category": "Resource Pack", "label": "Resource pack URL", "default": ""},
	"resource-pack-sha1": {"type": Type.STRING, "category": "Resource Pack", "label": "Resource pack SHA-1", "default": ""},
	"resource-pack-prompt": {"type": Type.STRING, "category": "Resource Pack", "label": "Prompt text", "default": ""},
	"require-resource-pack": {"type": Type.BOOL, "category": "Resource Pack", "label": "Require resource pack", "default": "false"},
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
	if value.is_valid_float():
		return Type.FLOAT
	return Type.STRING


static func core_keys() -> PackedStringArray:
	var out := PackedStringArray()
	for k in KEYS:
		if KEYS[k].get("core", false):
			out.append(k)
	return out
