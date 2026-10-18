class_name Ansi
extends RefCounted
## Converts ANSI SGR escape sequences and Minecraft section-sign colour codes
## into RichTextLabel BBCode, or strips them to plain text.

const PALETTE: PackedStringArray = [
	"#4b5263", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#d7dae0",
	"#7f848e", "#ff7b86", "#b5e890", "#ffd68a", "#7cc4ff", "#e09cff", "#7fdbe6", "#ffffff",
]

## Minecraft legacy colour codes (§0-§f) mapped to readable colours on a dark background.
const MC_COLORS := {
	"0": "#4b5263", "1": "#5c7cfa", "2": "#40c057", "3": "#22b8cf", "4": "#e03131", "5": "#ae3ec9",
	"6": "#fab005", "7": "#adb5bd", "8": "#7f848e", "9": "#748ffc", "a": "#69db7c", "b": "#66d9e8",
	"c": "#ff6b6b", "d": "#f783ac", "e": "#ffe066", "f": "#ffffff",
}

static var _re_sgr := RegEx.create_from_string("\\x1b\\[([0-9;]*)m")
static var _re_any_escape := RegEx.create_from_string("\\x1b\\[[0-9;?]*[A-Za-z]")
static var _re_mc := RegEx.create_from_string("§[0-9a-fk-orA-FK-OR]")


static func strip(text: String) -> String:
	text = _re_any_escape.sub(text, "", true)
	text = _re_mc.sub(text, "", true)
	return text.replace("\r", "")


static func escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")


## Converts a line containing ANSI and/or § codes into BBCode.
## [param default_color] is applied when the line carries no colour of its own.
static func to_bbcode(text: String, default_color := "") -> String:
	text = text.replace("\r", "")
	# Normalise § codes into the same colour stream as ANSI by handling them in one pass.
	var out := ""
	var color := ""
	var bold := false
	var open_color := false
	var open_bold := false
	var i := 0
	var length := text.length()
	var segment := ""

	while i < length:
		var c := text[i]
		var code_color := ""
		var code_reset := false
		var code_bold := false
		var consumed := 0

		if c == "\u001b" and i + 1 < length and text[i + 1] == "[":
			out += _flush(segment, color, bold, default_color)
			segment = ""
			var m := _re_sgr.search(text, i)
			if m != null and m.get_start() == i:
				consumed = m.get_end() - i
				var parsed := _parse_sgr(m.get_string(1), color, bold)
				color = parsed.color
				bold = parsed.bold
			else:
				var other := _re_any_escape.search(text, i)
				consumed = (other.get_end() - i) if other != null and other.get_start() == i else 1
			i += consumed
			continue
		elif c == "§" and i + 1 < length:
			var k := text[i + 1].to_lower()
			if MC_COLORS.has(k):
				code_color = MC_COLORS[k]
			elif k == "r":
				code_reset = true
			elif k == "l":
				code_bold = true
			if code_color != "" or code_reset or code_bold or "kmno".contains(k):
				out += _flush(segment, color, bold, default_color)
				segment = ""
				if code_color != "":
					color = code_color
					bold = false
				elif code_reset:
					color = ""
					bold = false
				elif code_bold:
					bold = true
				i += 2
				continue
		segment += c
		i += 1

	out += _flush(segment, color, bold, default_color)
	return out


static func _flush(segment: String, color: String, bold: bool, default_color: String) -> String:
	if segment.is_empty():
		return ""
	var s := escape_bbcode(segment)
	var col := color if color != "" else default_color
	if bold:
		s = "[b]" + s + "[/b]"
	if col != "":
		s = "[color=" + col + "]" + s + "[/color]"
	return s


static func _parse_sgr(params: String, color: String, bold: bool) -> Dictionary:
	var parts := params.split(";") if params != "" else PackedStringArray(["0"])
	var idx := 0
	while idx < parts.size():
		var n := parts[idx].to_int()
		if n == 0:
			color = ""
			bold = false
		elif n == 1:
			bold = true
		elif n == 22:
			bold = false
		elif n >= 30 and n <= 37:
			color = PALETTE[n - 30]
		elif n >= 90 and n <= 97:
			color = PALETTE[n - 90 + 8]
		elif n == 39:
			color = ""
		elif n == 38 and idx + 1 < parts.size():
			var mode := parts[idx + 1].to_int()
			if mode == 2 and idx + 4 < parts.size():
				color = "#" + Color8(parts[idx + 2].to_int(), parts[idx + 3].to_int(), parts[idx + 4].to_int()).to_html(false)
				idx += 4
			elif mode == 5 and idx + 2 < parts.size():
				color = _xterm256(parts[idx + 2].to_int())
				idx += 2
		idx += 1
	return {"color": color, "bold": bold}


static func _xterm256(n: int) -> String:
	if n < 16:
		return PALETTE[n]
	if n >= 232:
		var v := 8 + (n - 232) * 10
		return "#" + Color8(v, v, v).to_html(false)
	n -= 16
	var steps := [0, 95, 135, 175, 215, 255]
	return "#" + Color8(steps[n / 36], steps[(n / 6) % 6], steps[n % 6]).to_html(false)
