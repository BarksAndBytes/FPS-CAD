extends RefCounted
## Turns what someone typed into a value for the CAD core, and values back into text, in the
## document's units. Plain numbers use the document's units (degrees for angles); anything else
## is an expression the core evaluates ("25 mm", "width / 2", "90 deg").

const SCALE := {"mm": 0.001, "cm": 0.01, "m": 1.0, "in": 0.0254}


static func length_scale(units: String) -> float:
	return SCALE.get(units, 0.001)


## Text → JSON value: a number in SI (metres, radians) or an expression string.
static func parse(text: String, units: String, angle := false) -> Variant:
	var t := text.strip_edges().replace("−", "-")
	if t.is_valid_float():
		return deg_to_rad(float(t)) if angle else float(t) * length_scale(units)
	return t


## Value (SI number or expression) → text for an input field.
static func show(value: Variant, units: String, angle := false) -> String:
	if value is String:
		return value
	var v: float = rad_to_deg(float(value)) if angle else float(value) / length_scale(units)
	return ("%.4f" % v).rstrip("0").rstrip(".")


## x to `digits` significant figures, with thousands separators and no trailing zeros:
## 1234567 → "1,235,000", 12.5 → "12.5", 0.000123456 → "0.0001235".
static func significant(x: float, digits := 4) -> String:
	if x == 0.0 or not is_finite(x):
		return "0"
	var e := floori(log(absf(x)) / log(10.0))
	var decimals := clampi(digits - 1 - e, 0, 9)
	var text: String
	if decimals > 0:
		text = ("%." + str(decimals) + "f") % x
		text = text.rstrip("0").rstrip(".")
	else:
		var step := pow(10.0, e - digits + 1)
		text = "%d" % int(roundf(x / step) * step)
	var neg := text.begins_with("-")
	var body := text.trim_prefix("-")
	var whole := body.get_slice(".", 0)
	var frac := body.substr(whole.length())
	var grouped := ""
	for i in whole.length():
		if i > 0 and (whole.length() - i) % 3 == 0:
			grouped += ","
		grouped += whole[i]
	return ("-" if neg else "") + grouped + frac


## A volume in m³ as text in the document's units (mm³, cm³, m³, in³).
static func volume_text(v: float, units: String) -> String:
	var u: String = units if SCALE.has(units) else "mm"
	return "%s %s³" % [significant(v / pow(length_scale(u), 3)), u]


## An area in m² as text in the document's units.
static func area_text(a: float, units: String) -> String:
	var u: String = units if SCALE.has(units) else "mm"
	return "%s %s²" % [significant(a / pow(length_scale(u), 2)), u]


## A mass in kg: grams below 1 kg.
static func mass_text(kg: float) -> String:
	if absf(kg) < 1.0:
		return "%s g" % significant(kg * 1000.0)
	return "%s kg" % significant(kg)
