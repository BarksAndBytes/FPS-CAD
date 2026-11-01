extends RefCounted
## 2D geometry for the sketch editing tools (trim, extend, offset, fillet, the 3-point and tangent
## shapes): every sketch entity seen as one primitive (a segment, a circular arc or a polyline),
## with intersections between them and positions along them.
##
## Primitives are Dictionaries:
##   {t = "seg", a, b}                       a straight piece, parameter 0 at a to 1 at b
##   {t = "arc", c, r, a0, sweep}            counter-clockwise from angle a0 through sweep
##                                           (sweep = TAU for a full circle); parameter = angle
##                                           travelled from a0
##   {t = "poly", pts}                       a sampled curve (ellipse, spline); parameter =
##                                           distance travelled along it

const EPS := 1e-9


static func seg(a: Vector2, b: Vector2) -> Dictionary:
	return {t = "seg", a = a, b = b}


static func arc(c: Vector2, r: float, a0: float, sweep: float) -> Dictionary:
	return {t = "arc", c = c, r = r, a0 = a0, sweep = sweep}


static func poly(pts: PackedVector2Array) -> Dictionary:
	return {t = "poly", pts = pts}


## Counter-clockwise sweep from start s to end e about centre c (a full turn when they meet).
static func sweep_of(c: Vector2, s: Vector2, e: Vector2) -> float:
	var sw := fposmod((e - c).angle() - (s - c).angle(), TAU)
	return TAU if sw < 1e-12 else sw


# ---------- intersections ----------

## Every point where p and q cross or touch.
static func hits(p: Dictionary, q: Dictionary) -> Array:
	if p.t == "poly":
		return _poly_hits(p, q)
	if q.t == "poly":
		return _poly_hits(q, p)
	if p.t == "seg" and q.t == "seg":
		var x: Variant = seg_seg(p.a, p.b, q.a, q.b)
		return [] if x == null else [x]
	if p.t == "seg":
		return _on_arc(q, line_circle(p.a, p.b, q.c, q.r, true))
	if q.t == "seg":
		return _on_arc(p, line_circle(q.a, q.b, p.c, p.r, true))
	return _on_arc(q, _on_arc(p, circle_circle(p.c, p.r, q.c, q.r)))


static func _poly_hits(p: Dictionary, q: Dictionary) -> Array:
	var out := []
	var pts: PackedVector2Array = p.pts
	for i in pts.size() - 1:
		for x in hits(seg(pts[i], pts[i + 1]), q):
			var dup := false
			for y in out:
				if (y as Vector2).distance_to(x) < 1e-9:
					dup = true
			if not dup:
				out.append(x)
	return out


## Segment ab against segment cd, ends included; null when they miss or run parallel.
static func seg_seg(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> Variant:
	var r := b - a
	var s := d - c
	var den := r.cross(s)
	var scale := maxf(r.length() * s.length(), 1e-30)
	if absf(den) < 1e-12 * scale:
		return null
	var t := (c - a).cross(s) / den
	var u := (c - a).cross(r) / den
	var tol := 1e-9
	if t < -tol or t > 1.0 + tol or u < -tol or u > 1.0 + tol:
		return null
	return a + r * t


## The infinite lines through ab and cd; null when parallel.
static func line_line(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> Variant:
	var r := b - a
	var s := d - c
	var den := r.cross(s)
	if absf(den) < 1e-12 * maxf(r.length() * s.length(), 1e-30):
		return null
	return a + r * ((c - a).cross(s) / den)


## Line through ab against a circle; bounded to the segment when segment_only.
static func line_circle(a: Vector2, b: Vector2, c: Vector2, r: float, segment_only: bool) -> Array:
	var d := b - a
	var f := a - c
	var A := d.dot(d)
	if A < 1e-30:
		return []
	var B := 2.0 * f.dot(d)
	var C := f.dot(f) - r * r
	var disc := B * B - 4.0 * A * C
	var out := []
	if disc < -1e-12 * A * r * r:
		return out
	disc = maxf(disc, 0.0)
	var sq := sqrt(disc)
	for t in ([(-B - sq) / (2.0 * A)] if sq < 1e-12 * sqrt(A) * maxf(r, 1e-12) else [(-B - sq) / (2.0 * A), (-B + sq) / (2.0 * A)]):
		if not segment_only or (t >= -1e-9 and t <= 1.0 + 1e-9):
			out.append(a + d * t)
	return out


static func circle_circle(c1: Vector2, r1: float, c2: Vector2, r2: float) -> Array:
	var d := c1.distance_to(c2)
	if d < 1e-12 or d > r1 + r2 + 1e-9 or d < absf(r1 - r2) - 1e-9:
		return []
	var a := (r1 * r1 - r2 * r2 + d * d) / (2.0 * d)
	var h := sqrt(maxf(r1 * r1 - a * a, 0.0))
	var u := (c2 - c1) / d
	var m := c1 + u * a
	if h < 1e-12:
		return [m]
	return [m + u.orthogonal() * h, m - u.orthogonal() * h]


## Keeps the points that lie on the arc's sweep (all of them for a full circle).
static func _on_arc(p: Dictionary, pts: Array) -> Array:
	if p.t != "arc" or float(p.sweep) >= TAU - 1e-12:
		return pts
	var out := []
	for x in pts:
		var u := fposmod(((x as Vector2) - p.c).angle() - float(p.a0), TAU)
		if u <= float(p.sweep) + 1e-9 or u >= TAU - 1e-9:
			out.append(x)
	return out


# ---------- positions along a primitive ----------

## Where x (on or near p) is along p: 0..1 on a segment, angle from the start on an arc, distance
## travelled along a polyline.
static func param(p: Dictionary, x: Vector2) -> float:
	match p.t:
		"seg":
			var d: Vector2 = p.b - p.a
			return (x - p.a).dot(d) / maxf(d.length_squared(), 1e-30)
		"arc":
			return fposmod((x - p.c).angle() - float(p.a0), TAU)
	var pts: PackedVector2Array = p.pts
	var best := INF
	var at := 0.0
	var run := 0.0
	for i in pts.size() - 1:
		var q := Geometry2D.get_closest_point_to_segment(x, pts[i], pts[i + 1])
		if q.distance_to(x) < best:
			best = q.distance_to(x)
			at = run + pts[i].distance_to(q)
		run += pts[i].distance_to(pts[i + 1])
	return at


## Length of p's parameter range (1 for a segment).
static func span(p: Dictionary) -> float:
	match p.t:
		"seg":
			return 1.0
		"arc":
			return float(p.sweep)
	var pts: PackedVector2Array = p.pts
	var run := 0.0
	for i in pts.size() - 1:
		run += pts[i].distance_to(pts[i + 1])
	return run


static func distance(p: Dictionary, x: Vector2) -> float:
	match p.t:
		"seg":
			return x.distance_to(Geometry2D.get_closest_point_to_segment(x, p.a, p.b))
		"arc":
			var u := fposmod((x - p.c).angle() - float(p.a0), TAU)
			if float(p.sweep) >= TAU - 1e-12 or u <= float(p.sweep):
				return absf(x.distance_to(p.c) - float(p.r))
			var s: Vector2 = p.c + Vector2.from_angle(float(p.a0)) * float(p.r)
			var e: Vector2 = p.c + Vector2.from_angle(float(p.a0) + float(p.sweep)) * float(p.r)
			return minf(x.distance_to(s), x.distance_to(e))
	var pts: PackedVector2Array = p.pts
	var best := INF
	for i in pts.size() - 1:
		best = minf(best, x.distance_to(Geometry2D.get_closest_point_to_segment(x, pts[i], pts[i + 1])))
	return best


# ---------- constructions ----------

## Centre of the circle through three points; null when they are in a line.
static func circumcentre(a: Vector2, b: Vector2, c: Vector2) -> Variant:
	var d := 2.0 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
	var scale := maxf(a.distance_squared_to(b), maxf(b.distance_squared_to(c), a.distance_squared_to(c)))
	if absf(d) < 1e-9 * scale:
		return null
	var a2 := a.length_squared()
	var b2 := b.length_squared()
	var c2 := c.length_squared()
	return Vector2((a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
		(a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)


## Centre of the arc that leaves p heading along unit direction t and passes through q; null when
## q is straight ahead (or behind).
static func tangent_centre(p: Vector2, t: Vector2, q: Vector2) -> Variant:
	var n := Vector2(-t.y, t.x)  # left of t, in the sketch's y-up plane
	var d := q - p
	var den := 2.0 * d.dot(n)
	if absf(den) < 1e-9 * maxf(d.length(), 1e-12):
		return null
	return p + n * (d.length_squared() / den)


## Mirror image of x in the line through a and b.
static func reflect(x: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var d := (b - a).normalized()
	var v := x - a
	return a + d * (2.0 * v.dot(d)) - v


## Points a centripetal Catmull-Rom curve passes through, for previewing a spline while it is drawn
## (the finished spline is drawn from the core's own curve).
static func preview_spline(pts: Array, closed: bool) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := pts.size()
	if n < 2:
		return out
	var count := n if closed else n - 1
	for i in count:
		var p0: Vector2 = pts[(i - 1 + n) % n] if (closed or i > 0) else pts[0] * 2.0 - pts[1]
		var p1: Vector2 = pts[i]
		var p2: Vector2 = pts[(i + 1) % n]
		var p3: Vector2 = pts[(i + 2) % n] if (closed or i + 2 < n) else p2 * 2.0 - p1
		for k in 12:
			var s := k / 12.0
			var s2 := s * s
			var s3 := s2 * s
			out.append(0.5 * ((2.0 * p1) + (-p0 + p2) * s + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * s2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * s3))
	out.append(pts[0] if closed else pts[n - 1])
	return out
