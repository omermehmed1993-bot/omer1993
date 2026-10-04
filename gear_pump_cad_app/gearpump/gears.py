"""Spur gear parameters from a 2D gear outline.

Everything is measured, not assumed, except the split of the base radius
into module and pressure angle (rb = m z cos(alpha) / 2): a gear's shape fixes
rb but not m and alpha separately. The pressure angle is chosen from the
standard values so that the module comes out closest to a standard module,
unless the user fixes it.
"""

from dataclasses import dataclass, asdict

import numpy as np
from shapely.geometry import MultiPolygon, Polygon
from shapely.geometry.polygon import orient

# ISO 54 modules (series I and II), mm
STANDARD_MODULES = np.array([
    0.5, 0.55, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0, 1.125, 1.25, 1.375, 1.5, 1.75,
    2.0, 2.25, 2.5, 2.75, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0, 7.0, 8.0, 9.0,
    10.0, 11.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.0, 25.0])
STANDARD_PRESSURE_ANGLES = [20.0, 14.5, 15.0, 17.5, 22.5, 25.0, 30.0]


def inv(phi):
    """Involute function tan(phi) - phi."""
    return np.tan(phi) - phi


def inv_inverse(y):
    """Solve tan(phi) - phi = y for phi (Newton)."""
    phi = np.cbrt(3.0 * y) if y > 0 else 0.0
    for _ in range(50):
        f = np.tan(phi) - phi - y
        d = np.tan(phi) ** 2
        if d == 0:
            break
        step = f / d
        phi -= step
        if abs(step) < 1e-15:
            break
    return phi


@dataclass
class GearGeometry:
    z: int
    ra: float              # tip radius, mm
    rf: float              # root radius, mm
    rb: float              # base radius (involute fit), mm
    psi_b: float           # angular tooth thickness on the base circle, rad
    tooth_centre0: float   # angle of a tooth centre line in the CAD position, rad
    bore_radius: float     # shaft bore radius, mm (0 if none)
    flank_rms: float       # rms distance of flank points from the fitted involute, mm
    r_form: float = 0.0    # lowest radius of the fitted involute flank, mm
    module: float = 0.0
    alpha_deg: float = 0.0
    x: float = 0.0         # profile shift coefficient
    ha: float = 0.0        # addendum coefficient (ra - r)/m - x
    hf: float = 0.0        # dedendum coefficient (r - rf)/m + x
    r_pitch: float = 0.0   # reference (cutting) pitch radius m z / 2
    tip_thickness: float = 0.0   # tooth thickness on the tip circle, mm

    def thickness_angle(self, r):
        """Angular tooth thickness at radius r (rad)."""
        r = np.asarray(r, dtype=float)
        phi = np.arccos(np.clip(self.rb / r, -1, 1))
        return self.psi_b - 2.0 * inv(phi)

    def as_dict(self):
        return asdict(self)


def _outline(poly):
    if isinstance(poly, MultiPolygon):
        poly = max(poly.geoms, key=lambda g: g.area)
    return orient(Polygon(poly.exterior), 1.0)   # counter-clockwise


def analyse_gear(poly, centre=(0.0, 0.0), alpha_deg=None):
    """Measure a gear from its 2D outline (polygon in mm)."""
    outline = _outline(poly)
    xy = np.asarray(outline.exterior.coords)[:-1] - np.asarray(centre)
    # densify: insert points so the flanks are well sampled
    seg = np.roll(xy, -1, axis=0) - xy
    lens = np.hypot(seg[:, 0], seg[:, 1])
    step = max(np.hypot(*xy.T).max() * 2e-3, 1e-4)
    pts = [xy[i] + np.outer(np.linspace(0, 1, max(int(lens[i] / step), 1),
                                        endpoint=False), seg[i])
           for i in range(len(xy))]
    xy = np.vstack(pts)
    r = np.hypot(xy[:, 0], xy[:, 1])
    phi = np.arctan2(xy[:, 1], xy[:, 0])
    ra, rf = r.max(), r.min()
    h = ra - rf
    # teeth: upward crossings of the mid radius
    above = r > 0.5 * (ra + rf)
    z = int(np.sum(above & ~np.roll(above, 1)))
    if z < 3:
        raise ValueError("Could not count the gear teeth from the section.")
    pitch = 2 * np.pi / z

    # flank points: away from the root fillet and the tip edge
    dr = np.roll(r, -1) - np.roll(r, 1)
    moving = np.abs(dr) > 1e-9
    up, down = moving & (dr > 0), moving & (dr < 0)   # leading / trailing flank (CCW)

    def spread(rb, rising, falling):
        """Circular spread of the involute base angles (0 = perfect fit)."""
        tot = 0.0
        for mask, s in ((rising, 1.0), (falling, -1.0)):
            c = phi[mask] - s * inv(np.arccos(rb / r[mask]))
            tot += 1.0 - np.abs(np.mean(np.exp(1j * z * c)))
        return tot

    def fit_rb(rising, falling):
        if rising.sum() < 10 or falling.sum() < 10:
            raise ValueError("Too few flank points to fit the involute.")
        hi = min(r[rising].min(), r[falling].min()) * 0.99999
        grid = np.linspace(0.3 * ra, hi, 400)
        vals = [spread(v, rising, falling) for v in grid]
        k = int(np.argmin(vals))
        a_, b_ = grid[max(k - 1, 0)], grid[min(k + 1, len(grid) - 1)]
        gr = (np.sqrt(5) - 1) / 2
        for _ in range(80):                   # golden-section refinement
            c_ = b_ - gr * (b_ - a_)
            d_ = a_ + gr * (b_ - a_)
            if spread(c_, rising, falling) < spread(d_, rising, falling):
                b_ = d_
            else:
                a_ = c_
        return 0.5 * (a_ + b_)

    def base_angle(rb, mask, s):
        c = phi[mask] - s * inv(np.arccos(np.clip(rb / r[mask], -1, 1)))
        mean = np.angle(np.mean(np.exp(1j * z * c))) / z
        dev = np.angle(np.exp(1j * z * (c - mean))) / z       # wrapped residual
        return mean, dev

    # stage 1: upper part of the flank, which is involute on any working gear
    band = (r > ra - 0.55 * h) & (r < ra - 0.08 * h)
    rising, falling = band & up, band & down
    rb = fit_rb(rising, falling)
    # stage 2: extend down to the form circle (where the fillet starts) and refit
    rms0 = max(np.sqrt(np.mean(np.concatenate([
        (base_angle(rb, rising, 1.0)[1] * r[rising]) ** 2,
        (base_angle(rb, falling, -1.0)[1] * r[falling]) ** 2]))), 2e-4)
    wide = (r > max(rb * 1.002, rf + 0.05 * h)) & (r < ra - 0.08 * h)
    for mask, sgn in ((up, 1.0), (down, -1.0)):
        cand = wide & mask
        mean = base_angle(rb, mask & band, sgn)[0]
        c = phi - sgn * inv(np.arccos(np.clip(rb / r, -1, 1)))
        dev = np.abs(np.angle(np.exp(1j * z * (c - mean))) / z) * r
        good = cand & (dev < max(4 * rms0, 2e-3))
        # the form circle: lowest radius above which every flank point fits
        bad_r = r[cand & ~good]
        r_form = bad_r.max() if bad_r.size and bad_r.max() < ra - 0.55 * h else (
            rf if not bad_r.size else ra - 0.55 * h)
        good &= r > r_form
        if sgn > 0:
            rising = good
        else:
            falling = good
    rb = fit_rb(rising, falling)
    r_form = float(min(r[rising].min(), r[falling].min()))

    c_r, dev_r = base_angle(rb, rising, 1.0)
    c_f, dev_f = base_angle(rb, falling, -1.0)
    psi_b = (c_f - c_r) % pitch
    tooth_centre0 = c_r + 0.5 * psi_b
    flank_rms = float(np.sqrt(np.mean(np.concatenate([
        (dev_r * r[rising]) ** 2, (dev_f * r[falling]) ** 2]))))

    # shaft bore
    bore = 0.0
    p = max(poly.geoms, key=lambda g: g.area) if isinstance(poly, MultiPolygon) else poly
    if p.interiors:
        ring = np.asarray(max(p.interiors, key=lambda q: Polygon(q).area).coords)
        bore = float(np.mean(np.hypot(*(ring - np.asarray(centre)).T)))

    g = GearGeometry(z=z, ra=float(ra), rf=float(rf), rb=float(rb), psi_b=float(psi_b),
                     tooth_centre0=float(tooth_centre0), bore_radius=bore,
                     flank_rms=flank_rms, r_form=r_form)
    g.tip_thickness = float(ra * g.thickness_angle(ra))
    set_module(g, alpha_deg)
    return g


def set_module(g, alpha_deg=None):
    """Split rb into module and pressure angle; derive x, ha*, hf*."""
    if alpha_deg is None:
        best = None
        for al in STANDARD_PRESSURE_ANGLES:
            m = 2 * g.rb / (g.z * np.cos(np.radians(al)))
            rel = np.min(np.abs(STANDARD_MODULES - m)) / m
            key = rel + (0.0 if al == 20.0 else 0.002)   # prefer 20 deg on ties
            if best is None or key < best[0]:
                best = (key, al)
        alpha_deg = best[1]
    al = np.radians(alpha_deg)
    m = 2 * g.rb / (g.z * np.cos(al))
    r = m * g.z / 2
    s = r * g.thickness_angle(r)                      # tooth thickness at r
    x = (s / m - np.pi / 2) / (2 * np.tan(al))
    g.module, g.alpha_deg, g.r_pitch = float(m), float(alpha_deg), float(r)
    g.x = float(x)
    g.ha = float((g.ra - r) / m - x)
    g.hf = float((r - g.rf) / m + x)
    return g


@dataclass
class PairGeometry:
    a: float                  # centre distance, mm
    alpha_w_deg: float        # working pressure angle
    rw1: float                # operating pitch radii, mm
    rw2: float
    base_pitch1: float        # mm
    base_pitch2: float
    backlash: float           # circumferential, on the operating pitch circle, mm
    contact_ratio: float
    displacement: float       # theoretical geometric displacement, cm^3/rev of the drive gear
    face_width: float

    def as_dict(self):
        return asdict(self)


def analyse_pair(g1, g2, a, b):
    """Mesh quantities of a gear pair at centre distance a, face width b."""
    cos_aw = (g1.rb + g2.rb) / a
    if cos_aw >= 1:
        raise ValueError("Centre distance too small for the base circles: the gears overlap.")
    aw = np.arccos(cos_aw)
    rw1, rw2 = g1.rb / cos_aw, g2.rb / cos_aw
    pb1, pb2 = 2 * np.pi * g1.rb / g1.z, 2 * np.pi * g2.rb / g2.z
    s1 = rw1 * g1.thickness_angle(rw1)
    s2 = rw2 * g2.thickness_angle(rw2)
    backlash = 2 * np.pi * rw1 / g1.z - s1 - s2
    eps = (np.sqrt(g1.ra ** 2 - g1.rb ** 2) + np.sqrt(g2.ra ** 2 - g2.rb ** 2)
           - a * np.sin(aw)) / pb1
    disp = displacement(g1, g2, a, b)
    return PairGeometry(a=float(a), alpha_w_deg=float(np.degrees(aw)), rw1=float(rw1),
                        rw2=float(rw2), base_pitch1=float(pb1), base_pitch2=float(pb2),
                        backlash=float(backlash), contact_ratio=float(eps),
                        displacement=float(disp), face_width=float(b))


def displacement(g1, g2, a, b, n=4001):
    """Theoretical geometric displacement per drive-gear revolution, cm^3.

    Instantaneous flow of an external gear pump (Manring & Kasaragadda 2003):
        Q = b/2 * [w1 (ra1^2 - rho1^2) + w2 (ra2^2 - rho2^2)]
    with rho_i the distance from gear i's centre to the contact point. With
    ideal trapped-volume relief the active contact moves over one base pitch
    centred on the pitch point (u in [-pb/2, pb/2] along the line of action).
    Integrated over one revolution of the drive gear. For identical gears this
    reduces to 2 pi b (ra^2 - rw^2 - pi^2 rb^2 / (3 z^2)).
    """
    cos_aw = (g1.rb + g2.rb) / a
    aw = np.arccos(cos_aw)
    rw1 = g1.rb / cos_aw
    pb = 2 * np.pi * g1.rb / g1.z
    u = np.linspace(-pb / 2, pb / 2, n)
    # pitch point P at (rw1, 0); line of action direction makes angle aw with the y axis
    t = np.array([np.sin(aw), np.cos(aw)])
    px = rw1 + u * t[0]
    py = u * t[1]
    rho1_sq = px ** 2 + py ** 2
    rho2_sq = (px - a) ** 2 + py ** 2
    w1, w2 = 1.0, g1.z / g2.z
    q = 0.5 * b * (w1 * (g1.ra ** 2 - rho1_sq) + w2 * (g2.ra ** 2 - rho2_sq))   # per rad of gear 1
    # u advances by rb1 per radian of gear 1
    trapz = getattr(np, "trapezoid", None) or np.trapz      # numpy 1.x has trapz only
    vol_per_pitch = trapz(q, u) / g1.rb
    return g1.z * vol_per_pitch / 1000.0
