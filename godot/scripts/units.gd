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
