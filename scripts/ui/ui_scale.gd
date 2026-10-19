class_name UiScale
extends RefCounted
## Interface size. Scales the whole UI, including embedded dialogs and popups, through
## the root window's content_scale_factor, and keeps the window's minimum size in step
## so the scaled layout still fits.

## Choices offered in Preferences; 0 = automatic.
const OPTIONS: Array[float] = [0.0, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
## Smallest window (in unscaled UI units) the layout is designed for; tall enough for the
## New Server wizard (640) plus its title bar.
const BASE_MIN_SIZE := Vector2i(1100, 720)


## Factor for "Automatic": the desktop's own scale when it reports one (Wayland, macOS),
## otherwise derived from the screen's DPI.
static func automatic_factor(screen_scale: float, dpi: int) -> float:
	if screen_scale > 1.0:
		return screen_scale
	if dpi >= 192:
		return 2.0
	if dpi >= 144:
		return 1.5
	if dpi >= 120:
		return 1.25
	return 1.0


## Largest factor at which the minimum layout still fits on a screen of [param usable] size.
static func max_factor(usable: Vector2i) -> float:
	if usable.x <= 0 or usable.y <= 0:
		return 3.0
	var fit := minf(float(usable.x) / BASE_MIN_SIZE.x, float(usable.y) / BASE_MIN_SIZE.y)
	return maxf(floorf(fit * 20.0) / 20.0, 0.5)


## The factor actually used for [param setting] (0 = automatic), capped to what fits.
static func effective(setting: float, screen_scale: float, dpi: int, usable: Vector2i) -> float:
	var factor := automatic_factor(screen_scale, dpi) if setting <= 0.0 else setting
	return minf(factor, max_factor(usable))


## Human-readable name of an option, e.g. "Automatic (125 %)" or "150 %".
static func option_label(setting: float, automatic: float) -> String:
	if setting <= 0.0:
		return "Automatic (%d %%)" % roundi(automatic * 100.0)
	return "%d %%" % roundi(setting * 100.0)


## Factor "Automatic" resolves to on the window's current screen.
static func current_automatic(window: Window) -> float:
	var screen := window.current_screen
	return automatic_factor(DisplayServer.screen_get_scale(screen), DisplayServer.screen_get_dpi(screen))


## Applies [member AppSettings.ui_scale] (or [param setting] when given) to [param window].
## Returns the factor in use.
static func apply(window: Window, setting := -1.0) -> float:
	if setting < 0.0:
		setting = AppSettings.ui_scale
	var screen := window.current_screen
	var usable := DisplayServer.screen_get_usable_rect(screen).size
	var factor := effective(setting, DisplayServer.screen_get_scale(screen), DisplayServer.screen_get_dpi(screen), usable)
	window.content_scale_factor = factor
	var min_size := Vector2i(ceili(BASE_MIN_SIZE.x * factor), ceili(BASE_MIN_SIZE.y * factor))
	if usable.x > 0 and usable.y > 0:
		min_size = min_size.min(usable)
	window.min_size = min_size
	return factor
