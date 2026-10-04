"""Gear rotation and the volumes / areas an external gear pump model needs.

Conventions (all in the 2D gear frame of cad.PumpSection, mm):
  * drive gear (gear 1) centred at (0, 0), driven gear (gear 2) at (a, 0);
  * `direction` = +1 when the drive gear turns counter-clockwise in this
    frame, -1 when clockwise; the driven gear turns the other way;
  * the drive gear's leading flanks push the driven gear (backlash is taken
    up on the driving side, found by rotating the driven gear backwards
    until the flanks touch);
  * chamber angle psi: position of a tooth space centre, measured from the
    line of centres (pointing at the other gear) in the gear's own direction
    of rotation, 0..360 deg. psi = 0 is the space in the middle of the mesh.
  * with direction = +1 the teeth come out of the mesh on the +y side, which
    is therefore the suction (inlet) side; the outlet is on -y.

Tooth space volume (TSV): fluid between two adjacent tooth centre lines,
inside the tip circle, less what the other gear's teeth fill when the space
is in the mesh (the usual control volume of lumped gear pump models).

Port areas: a space is open to a port over the part of its tip opening
(the arc between the two tip lands) that is not sealed by the housing bore
and not inside the other gear's tip circle. The open arc is measured on
several sections across the face width (so a drilled port of diameter
smaller than the face width is integrated correctly) and summed as
arc length x slice thickness.

Trapped volume: while two tooth pairs are in contact (contact ratio > 1)
the fluid between the two contacts is cut off from both ports.
"""

from dataclasses import dataclass, field

import numpy as np
import shapely
from shapely import affinity
from shapely.geometry import LineString, MultiPolygon, Point, Polygon, box
from shapely.ops import unary_union


def _filled(poly):
    if isinstance(poly, MultiPolygon):
        poly = max(poly.geoms, key=lambda g: g.area)
    return Polygon(poly.exterior)


def _parts(geom):
    if geom.is_empty:
        return []
    if hasattr(geom, "geoms"):
        return [g for g in geom.geoms if isinstance(g, Polygon) and not g.is_empty]
    return [geom] if isinstance(geom, Polygon) else []


def _wedge(centre, a0, a1, r, n=64):
    t = np.linspace(a0, a1, n)
    pts = [tuple(centre)] + [(centre[0] + r * np.cos(v), centre[1] + r * np.sin(v)) for v in t]
    return Polygon(pts)


def _disk(centre, r, n=2048):
    return Point(*centre).buffer(r, quad_segs=n // 4)


@dataclass
class PortMap:
    """Open / sealed classification of one gear's tip circle on one section."""
    phi: np.ndarray            # global angle grid around the gear centre, rad
    open_pos: np.ndarray       # True where open to the +y side chamber
    open_neg: np.ndarray       # True where open to the -y side chamber
    sealed: np.ndarray         # True where the housing seals the tip
    clearance: np.ndarray      # distance tip circle -> housing, mm
    tip_clearance: float       # median clearance over the sealing arc, mm
    threshold: float           # clearance above which the tip counts as open, mm


@dataclass
class KinematicsResult:
    direction: int
    delta0: float                       # driven gear backlash take-up angle, rad
    psi_deg: np.ndarray                 # chamber angle grid, deg
    V1: np.ndarray                      # drive gear TSV, mm^3
    V2: np.ndarray                      # driven gear TSV, mm^3
    A_in1: np.ndarray                   # drive gear TSV -> inlet area, mm^2
    A_out1: np.ndarray
    A_in2: np.ndarray                   # driven gear TSV -> inlet area, mm^2
    A_out2: np.ndarray
    theta_mesh_deg: np.ndarray          # drive gear angle over one tooth pitch, deg
    V_trap: np.ndarray                  # trapped volume, mm^3 (0 when none)
    n_trap: np.ndarray                  # number of trapped pockets at each angle
    contact_gap_min: np.ndarray         # smallest flank gap at each mesh angle, mm
    D_cv: float                         # displacement from TSV variation, cm^3/rev
    tip_clearance1: float               # h_r drive gear, mm (mid section)
    tip_clearance2: float
    seal_arc1_deg: float                # longest sealing arc of the housing, deg
    seal_arc2_deg: float
    seal_teeth1: float                  # teeth inside the sealing arc
    seal_teeth2: float
    open_arcs: dict = field(default_factory=dict)   # for plotting
    slice_levels: np.ndarray = None     # sections used across the face width, mm
    warnings: list = field(default_factory=list)


class PumpKinematics:
    """Rotate the two gears of a pump section and measure the chambers."""

    def __init__(self, gear1_poly, gear2_poly, g1, g2, a, face_width,
                 direction=1, contact_tol=0.005):
        self.P1 = _filled(gear1_poly)
        self.P2 = _filled(gear2_poly)
        self.g1, self.g2 = g1, g2
        self.a = float(a)
        self.b = float(face_width)
        self.s = 1 if direction >= 0 else -1
        self.contact_tol = contact_tol
        self.C1 = (0.0, 0.0)
        self.C2 = (self.a, 0.0)
        self.ratio = g1.z / g2.z
        self.D1 = _disk(self.C1, g1.ra)
        self.D2 = _disk(self.C2, g2.ra)
        self.U = self.D1.union(self.D2)
        # the tip circles overlap in the mesh: split the overlap (lens) on the
        # line through the two tip circle intersections, so every bit of fluid
        # belongs to exactly one gear's tooth space
        self.x_r = (self.a ** 2 + g1.ra ** 2 - g2.ra ** 2) / (2 * self.a)
        big = 4 * (self.a + g1.ra + g2.ra)
        self.H1 = box(-big, -big, self.x_r, big)
        self.H2 = box(self.x_r, -big, big, big)
        # tooth space 0 of each gear in its CAD position (between tooth 0 and 1)
        self.pitch1 = 2 * np.pi / g1.z
        self.pitch2 = 2 * np.pi / g2.z
        self.c1 = g1.tooth_centre0 + self.pitch1 / 2      # space centre angles
        self.c2 = g2.tooth_centre0 + self.pitch2 / 2
        self.S1 = (_wedge(self.C1, g1.tooth_centre0, g1.tooth_centre0 + self.pitch1, 2 * g1.ra)
                   .intersection(self.D1).difference(self.P1))
        self.S2 = (_wedge(self.C2, g2.tooth_centre0, g2.tooth_centre0 + self.pitch2, 2 * g2.ra)
                   .intersection(self.D2).difference(self.P2))
        self.delta0 = self._take_up_backlash()
        self._setup_lines_of_action()

    # ---------------------------------------------------------------- motion
    def angles(self, theta):
        """Rotation (rad, CCW) of gear 1 and gear 2 from the CAD position for
        a drive gear angle theta (rad, in its direction of rotation)."""
        t1 = self.s * theta
        t2 = -t1 * self.ratio + self.delta0
        return t1, t2

    def gears_at(self, theta):
        t1, t2 = self.angles(theta)
        G1 = affinity.rotate(self.P1, t1, origin=self.C1, use_radians=True)
        G2 = affinity.rotate(self.P2, t2, origin=self.C2, use_radians=True)
        return G1, G2

    def _take_up_backlash(self):
        """Angle to turn the driven gear back (against its motion) until its
        flanks touch the drive gear's driving flanks."""
        back = self.s                     # driven gear turns -s; backwards is +s

        def touching(d):
            G2 = affinity.rotate(self.P2, d, origin=self.C2, use_radians=True)
            return self.P1.intersects(G2)

        if touching(0.0):
            # overlapping in the CAD position: turn forward until free
            step = -back * self.pitch2 / 400
            hi = step
            n = 0
            while touching(hi):
                hi += step
                n += 1
                if n > 400:
                    raise ValueError("The gears overlap in every position: check the centre distance.")
            free, hit = hi, hi - step
        else:
            step = back * self.pitch2 / 400
            free, hit = 0.0, step
            n = 0
            while not touching(hit):
                free, hit = hit, hit + step
                n += 1
                if n > 400:
                    raise ValueError("The gears never touch: they do not mesh.")
        for _ in range(60):
            mid = 0.5 * (free + hit)
            if touching(mid):
                hit = mid
            else:
                free = mid
        return free

    def theta_for_psi(self, psi, gear):
        """Drive gear angle that puts space 0 of `gear` (1 or 2) at chamber angle psi."""
        if gear == 1:
            t1 = self.s * psi - self.c1               # global centre angle = t1 + c1 = s*psi
            return self.s * t1
        # gear 2: centre angle = t2 + c2 = pi - s*psi  (direction of gear 2 is -s)
        t2 = np.pi - self.s * psi - self.c2
        t1 = -(t2 - self.delta0) / self.ratio
        return self.s * t1

    # --------------------------------------------------------------- volumes
    def tsv(self, psi_deg):
        """Tooth space volumes (mm^3) of both gears over the chamber angle grid."""
        V = np.zeros((2, len(psi_deg)))
        for gi, (S, C) in enumerate(((self.S1, self.C1), (self.S2, self.C2))):
            for k, p in enumerate(np.radians(psi_deg)):
                th = self.theta_for_psi(p, gi + 1)
                G1, G2 = self.gears_at(th)
                t1, t2 = self.angles(th)
                Sr = affinity.rotate(S, t1 if gi == 0 else t2, origin=C, use_radians=True)
                Sr = Sr.intersection(self.H1 if gi == 0 else self.H2)
                if Sr.is_empty:
                    continue
                other = G2 if gi == 0 else G1
                V[gi, k] = Sr.difference(other).area * self.b
        return V[0], V[1]

    # ----------------------------------------------------------------- ports
    def port_map(self, housing, gear, n=7200):
        """Classify the tip circle of `gear` against one housing section."""
        g = self.g1 if gear == 1 else self.g2
        C = np.array(self.C1 if gear == 1 else self.C2)
        Co = np.array(self.C2 if gear == 1 else self.C1)
        ra_o = (self.g2 if gear == 1 else self.g1).ra
        phi = np.linspace(0, 2 * np.pi, n, endpoint=False)
        u = np.column_stack([np.cos(phi), np.sin(phi)])
        tip = C + g.ra * u
        shapely.prepare(housing)
        clear = shapely.distance(shapely.points(tip), housing)
        inside_h = shapely.contains_xy(housing, tip[:, 0], tip[:, 1])
        clear = np.where(inside_h, 0.0, clear)
        mesh = np.hypot(*(tip - Co).T) < ra_o
        # radial clearance from the housing outline vertices, which lie on the
        # true surface (chords of the discretised bore sag inwards)
        hv = np.vstack([np.asarray(r.coords) for p in _parts(housing)
                        for r in [p.exterior, *p.interiors]])
        rv = np.hypot(*(hv - C).T) - g.ra
        near = (rv > -1e-3) & (rv < 0.1 * g.module) & (np.hypot(*(hv - Co).T) >= ra_o)
        h_r = float(max(np.median(rv[near]), 0.0)) if near.any() else float("nan")
        thr = max(3 * (h_r if np.isfinite(h_r) else 0.0), 0.02 * g.module, 0.02)
        sealed = (~mesh) & (clear < thr)
        opened = (~mesh) & ~sealed
        return PortMap(phi=phi, open_pos=opened & (tip[:, 1] > 0),
                       open_neg=opened & (tip[:, 1] <= 0), sealed=sealed,
                       clearance=clear, tip_clearance=h_r, threshold=thr)

    def port_areas(self, port_maps, slice_widths, psi_deg, gear):
        """Area (mm^2) between space 0 of `gear` and the +y / -y chambers.

        port_maps: list of PortMap of this gear, one per section;
        slice_widths: thickness each section stands for (sum = face width).
        """
        g = self.g1 if gear == 1 else self.g2
        tc0 = g.tooth_centre0
        pitch = 2 * np.pi / g.z
        half_land = 0.5 * max(g.thickness_angle(g.ra), 0.0)
        A_pos = np.zeros(len(psi_deg))
        A_neg = np.zeros(len(psi_deg))
        for pm, w in zip(port_maps, slice_widths):
            n = len(pm.phi)
            dphi = 2 * np.pi / n
            cum_p = np.concatenate([[0], np.cumsum(np.tile(pm.open_pos, 2))])
            cum_n = np.concatenate([[0], np.cumsum(np.tile(pm.open_neg, 2))])
            for k, p in enumerate(np.radians(psi_deg)):
                th = self.theta_for_psi(p, gear)
                t1, t2 = self.angles(th)
                rot = t1 if gear == 1 else t2
                a0 = (tc0 + half_land + rot) % (2 * np.pi)
                a1 = a0 + pitch - 2 * half_land
                i0 = int(np.round(a0 / dphi))
                i1 = int(np.round(a1 / dphi))
                L = g.ra * dphi
                A_pos[k] += w * L * (cum_p[i1] - cum_p[i0])
                A_neg[k] += w * L * (cum_n[i1] - cum_n[i0])
        return A_pos, A_neg

    # ---------------------------------------------------------------- mesh
    def _setup_lines_of_action(self):
        """Theoretical contact paths from the fitted involutes.

        A contact exists where a driving flank of gear 1 crosses the line of
        action between the two tip circles. Contacts on the coast flanks are
        added only when the backlash is too small to leave a gap.
        """
        g1, g2, a = self.g1, self.g2, self.a
        cos_aw = (g1.rb + g2.rb) / a
        aw = np.arccos(cos_aw)
        rw1 = g1.rb / cos_aw
        self.pb = 2 * np.pi * g1.rb / g1.z
        P = np.array([rw1, 0.0])
        rw2 = g2.rb / cos_aw
        s1 = rw1 * g1.thickness_angle(rw1)
        s2 = rw2 * g2.thickness_angle(rw2)
        backlash = 2 * np.pi * rw1 / g1.z - s1 - s2
        self.lines = []
        # base angle of the flank with orientation sigma: c = centre - sigma * psi_b / 2
        flanks = [(-self.s, g1.tooth_centre0 + self.s * g1.psi_b / 2)]   # driving flank
        self.backlash_normal = backlash * cos_aw
        if self.backlash_normal < self.contact_tol:
            flanks.append((self.s, g1.tooth_centre0 - self.s * g1.psi_b / 2))  # coast
        for sigma, c0 in flanks:
            # sigma = +1: involute unwinding CCW (phi = c + inv), -1: CW
            tau = sigma * aw
            T1 = g1.rb * np.array([np.cos(tau), np.sin(tau)])
            d = (P - T1) / np.linalg.norm(P - T1)
            l_end = np.sqrt(g1.ra ** 2 - g1.rb ** 2)                   # gear 1 tip
            l_start = a * np.sin(aw) - np.sqrt(g2.ra ** 2 - g2.rb ** 2)  # gear 2 tip
            self.lines.append(dict(sigma=sigma, c0=c0, tau=tau, T1=T1, d=d,
                                   l_lo=min(l_start, l_end), l_hi=max(l_start, l_end)))

    def contact_points(self, theta):
        """Contact points (x, y) and the line of action direction at theta."""
        t1, _ = self.angles(theta)
        out = []
        for L in self.lines:
            c = L["c0"] + t1
            l0 = (L["sigma"] * self.g1.rb * (L["tau"] - c)) % self.pb
            n0 = int(np.ceil((L["l_lo"] - l0) / self.pb))
            n1 = int(np.floor((L["l_hi"] - l0) / self.pb))
            for n in range(n0, n1 + 1):
                ell = l0 + n * self.pb
                out.append((L["T1"] + ell * L["d"], L["d"]))
        return out

    def mesh_state(self, theta):
        """Trapped pockets at drive gear angle theta.

        Returns (list of pocket polygons, list of contact segments, min gap).
        """
        G1, G2 = self.gears_at(theta)
        g1, g2 = self.g1, self.g2
        win = box(g1.rf - 0.5 * g1.module, -max(g1.ra, g2.ra),
                  self.a - g2.rf + 0.5 * g2.module, max(g1.ra, g2.ra))
        U = self.U.intersection(win)
        # pockets are found on gears shrunk by the contact tolerance, so CAD
        # flanks that graze each other away from the theoretical contacts do
        # not close the fluid; their volume is then measured on the true gears
        e = self.contact_tol
        M = U.difference(G1.buffer(-e)).difference(G2.buffer(-e))
        near = win.buffer(max(g1.module, g2.module))
        gmin = _min_gap(G1, G2, near)
        h = max(0.05, 10 * self.contact_tol)   # cut across CAD gaps at the contact
        segs = [LineString([tuple(X - h * d), tuple(X + h * d)])
                for X, d in self.contact_points(theta)]
        if segs:
            M = M.difference(unary_union(segs).buffer(1e-5))
        outer = self.U.exterior.buffer(1e-4).union(win.exterior.buffer(1e-4))
        pockets = []
        for c in _parts(M):
            if c.intersects(outer):
                continue
            true = c.difference(G1).difference(G2)
            if true.area > 1e-6:
                pockets.append(true)
        return pockets, segs, gmin

    def trapped(self, n=181):
        theta = np.linspace(0, self.pitch1, n)
        V = np.zeros(n)
        npk = np.zeros(n, dtype=int)
        gaps = np.zeros(n)
        for k, th in enumerate(theta):
            pockets, _, gmin = self.mesh_state(th)
            V[k] = sum(p.area for p in pockets) * self.b
            npk[k] = len(pockets)
            gaps[k] = gmin
        return np.degrees(theta), V, npk, gaps


def _distance_to_outline(pts, poly, region):
    """Distance from points to a polygon (0 inside), using only the part of
    its outline inside `region` and a spatial index over the segments."""
    ring = np.asarray(poly.exterior.coords)
    keep = shapely.contains_xy(region, ring[:, 0], ring[:, 1])
    keep = keep[:-1] | keep[1:]
    a, b = ring[:-1][keep], ring[1:][keep]
    if not len(a):
        return shapely.distance(shapely.points(pts), poly)
    segs = shapely.linestrings(np.stack([a, b], axis=1))
    tree = shapely.STRtree(segs)
    _, d = tree.query_nearest(shapely.points(pts), return_distance=True, all_matches=False)
    inside = shapely.contains_xy(poly, pts[:, 0], pts[:, 1])
    return np.where(inside, 0.0, d)


def _min_gap(Ga, Gb, region):
    a = Ga.intersection(region)
    b = Gb.intersection(region)
    if a.is_empty or b.is_empty:
        return np.inf
    return float(a.distance(b))


def _seal_arc(pm):
    """Longest contiguous sealed arc (deg) on a circular grid."""
    s = pm.sealed
    if s.all():
        return 360.0
    if not s.any():
        return 0.0
    k = int(np.argmin(s))                 # start on an unsealed cell
    r = np.roll(s, -k)
    best = cur = 0
    for v in r:
        cur = cur + 1 if v else 0
        best = max(best, cur)
    return best * 360.0 / len(s)


def _slice_maps(kin, housing_at, z_lo, z_hi, n_slices, max_slices=41):
    """Port maps of both gears on sections across the face width.

    Starts from n_slices evenly spaced sections and adds sections between
    neighbours whose open arcs differ (port edges, drilled holes), so the
    axial extent of the ports is found closely. Returns the sorted levels,
    their trapezoid weights (sum = face width) and the maps.
    """
    eps = 1e-3 * (z_hi - z_lo)
    maps = {}

    def get(z):
        if z not in maps:
            h = housing_at(z)
            if h is None:
                raise ValueError(f"No housing material {z:.3f} mm from the mid plane.")
            maps[z] = (kin.port_map(h, 1), kin.port_map(h, 2))
        return maps[z]

    def differs(za, zb):
        (a1, a2), (b1, b2) = get(za), get(zb)
        n = len(a1.phi)
        d = sum(np.count_nonzero((p.open_pos != q.open_pos) | (p.open_neg != q.open_neg))
                for p, q in ((a1, b1), (a2, b2)))
        return d > 1e-2 * n

    zs = list(np.linspace(z_lo + eps, z_hi - eps, max(int(n_slices), 2)))
    for z in zs:
        get(z)
    min_dz = (z_hi - z_lo) / 128
    changed = True
    while changed and len(maps) < max_slices:
        changed = False
        zs = sorted(maps)
        for za, zb in zip(zs[:-1], zs[1:]):
            if zb - za > min_dz and differs(za, zb) and len(maps) < max_slices:
                get(0.5 * (za + zb))
                changed = True
    zs = np.array(sorted(maps))
    # trapezoid weights, values held constant out to the end faces
    w = np.zeros(len(zs))
    w[:-1] += 0.5 * np.diff(zs)
    w[1:] += 0.5 * np.diff(zs)
    w[0] += zs[0] - z_lo
    w[-1] += z_hi - zs[-1]
    return zs, w, [maps[z][0] for z in zs], [maps[z][1] for z in zs]


def analyse_kinematics(sec, g1, g2, housing_at, n_slices=9, direction=1,
                       angle_step_deg=1.0, mesh_points=181, contact_tol=0.005):
    """Run the whole kinematic analysis.

    sec: cad.PumpSection (mid-plane gears); housing_at(z): housing region
    in the plane z mm from the mid plane (used across the face width).
    """
    kin = PumpKinematics(sec.gear1, sec.gear2, g1, g2, sec.a, sec.face_width,
                         direction, contact_tol)
    psi = np.arange(0.0, 360.0, angle_step_deg)
    V1, V2 = kin.tsv(psi)
    zs, widths, pm1, pm2 = _slice_maps(kin, housing_at, sec.z_lo, sec.z_hi, n_slices)
    Ap1, An1 = kin.port_areas(pm1, widths, psi, 1)
    Ap2, An2 = kin.port_areas(pm2, widths, psi, 2)
    # +y is the inlet when the drive gear turns CCW
    if kin.s > 0:
        A_in1, A_out1, A_in2, A_out2 = Ap1, An1, Ap2, An2
    else:
        A_in1, A_out1, A_in2, A_out2 = An1, Ap1, An2, Ap2
    th, Vt, npk, gaps = kin.trapped(mesh_points)
    D_cv = g1.z * ((V1.max() - V1.min()) + (V2.max() - V2.min())) / 1000.0
    mid = int(np.argmin(np.abs(zs)))
    warn = []
    if not np.isfinite(pm1[mid].tip_clearance):
        warn.append("No sealing arc found around the drive gear.")
    if np.nanmax([pm1[mid].tip_clearance, pm2[mid].tip_clearance]) < 1e-4:
        warn.append("The gear tips touch the housing bore in the CAD (nominal model): "
                    "enter the real radial clearance for leakage.")
    if (A_in1.max() == 0) or (A_out1.max() == 0):
        warn.append("A port is never opened by the drive gear spaces: check the housing "
                    "section and the rotation direction.")
    return KinematicsResult(
        direction=kin.s, delta0=kin.delta0, psi_deg=psi, V1=V1, V2=V2,
        A_in1=A_in1, A_out1=A_out1, A_in2=A_in2, A_out2=A_out2,
        theta_mesh_deg=th, V_trap=Vt, n_trap=npk, contact_gap_min=gaps, D_cv=D_cv,
        tip_clearance1=pm1[mid].tip_clearance, tip_clearance2=pm2[mid].tip_clearance,
        seal_arc1_deg=_seal_arc(pm1[mid]), seal_arc2_deg=_seal_arc(pm2[mid]),
        seal_teeth1=_seal_arc(pm1[mid]) / 360.0 * g1.z,
        seal_teeth2=_seal_arc(pm2[mid]) / 360.0 * g2.z,
        open_arcs={"gear1": pm1[mid], "gear2": pm2[mid]}, slice_levels=zs,
        warnings=warn), kin
