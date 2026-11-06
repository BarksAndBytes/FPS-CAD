extends RefCounted
## Turns what someone typed into a value for the CAD core, and values back into text, in the
## document's units. Plain numbers use the document's units (degrees for angles); anything else
## is an expression the core evaluates ("25 mm", "width / 2", "90 deg").

const SCALE := {"mm": 0.001, "cm": 0.01, "m": 1.0, "in": 0.0254, "ft": 0.3048}
const MASS := {"g": 0.001, "kg": 1.0, "lb": 0.45359237}  # kg per unit
const PSI := 6894.757293168  # Pa
## The standard unit systems (as in most CAD tools): a length and a mass unit; time is seconds.
const SYSTEMS := [
	{id = "MMGS", length = "mm", mass = "g", name = "millimetre, gram, second"},
	{id = "CGS", length = "cm", mass = "g", name = "centimetre, gram, second"},
	{id = "MKS", length = "m", mass = "kg", name = "metre, kilogram, second"},
	{id = "IPS", length = "in", mass = "lb", name = "inch, pound, second"},
	{id = "FPS", length = "ft", mass = "lb", name = "foot, pound, second"},
]


## The unit system with this length and mass unit, or {} when they don't make a standard one.
static func system_of(length: String, mass: String) -> Dictionary:
	for s in SYSTEMS:
		if s.length == length and s.mass == mass:
			return s
	return {}


## "MMGS (mm, g)", or "mm, kg" for a mix that isn't a standard system.
static func system_label(length: String, mass: String) -> String:
	var s := system_of(length, mass)
	return "%s (%s, %s)" % [s.id, length, mass] if not s.is_empty() else "%s, %s" % [length, mass]


static func imperial(units: String) -> bool:
	return units == "in" or units == "ft"


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


## A mass in kg, in the part's mass unit (g, kg or lb); with no unit, grams below 1 kg.
static func mass_text(kg: float, unit := "") -> String:
	if MASS.has(unit):
		return "%s %s" % [significant(kg / MASS[unit]), unit]
	if absf(kg) < 1.0:
		return "%s g" % significant(kg * 1000.0)
	return "%s kg" % significant(kg)


## A density in kg/m³ the way the unit system writes it: g/cm³, kg/m³, lb/in³ or lb/ft³.
static func density_text(kg_m3: float, units: String, mass: String) -> String:
	if mass == "lb":
		var per := "ft" if units == "ft" else "in"
		return "%s lb/%s³" % [significant(kg_m3 / MASS.lb * pow(SCALE[per], 3), 4), per]
	if mass == "g":
		return "%s g/cm³" % significant(kg_m3 / 1000.0, 4)
	return "%s kg/m³" % significant(kg_m3, 4)


## A density typed in the unit system's density unit, back to kg/m³.
static func density_from(value: float, units: String, mass: String) -> float:
	if mass == "lb":
		var per := "ft" if units == "ft" else "in"
		return value * MASS.lb / pow(SCALE[per], 3)
	if mass == "g":
		return value * 1000.0
	return value


## A stress or modulus in Pa: MPa or GPa, or ksi / Msi in inch and foot units.
static func stress_text(pa: float, units: String) -> String:
	if imperial(units):
		var psi := pa / PSI
		return "%s Msi" % significant(psi / 1e6, 3) if psi >= 1e6 else "%s ksi" % significant(psi / 1000.0, 3)
	return "%s GPa" % significant(pa / 1e9, 3) if pa >= 1e9 else "%s MPa" % significant(pa / 1e6, 3)
