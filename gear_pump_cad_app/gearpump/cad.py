"""Read a gear pump STEP file and turn it into a 2D cross-section.

The pump is expected to contain a housing and two spur gears (other solids,
such as shafts or side plates, are listed but not used). Gears are found by
their shape: a solid of revolution-like symmetry whose cross-section has a
periodic, toothed radial profile. Everything downstream works on the 2D
section at mid face width, expressed in a frame with the drive-gear axis at
the origin and the driven-gear axis on the +x axis.
"""

from dataclasses import dataclass, field

import numpy as np
from shapely.geometry import LineString, Polygon, MultiPolygon
from shapely.ops import polygonize, unary_union

from OCP.BRepAdaptor import BRepAdaptor_Curve
from OCP.BRepAlgoAPI import BRepAlgoAPI_Section
from OCP.BRepBndLib import BRepBndLib
from OCP.BRepClass3d import BRepClass3d_SolidClassifier
from OCP.BRepGProp import BRepGProp
from OCP.Bnd import Bnd_Box
from OCP.GCPnts import GCPnts_QuasiUniformDeflection
from OCP.GProp import GProp_GProps
from OCP.IFSelect import IFSelect_RetDone
from OCP.STEPControl import STEPControl_Reader
from OCP.BRep import BRep_Tool
from OCP.TopAbs import TopAbs_EDGE, TopAbs_IN, TopAbs_ON, TopAbs_SOLID, TopAbs_VERTEX
from OCP.TopExp import TopExp_Explorer
from OCP.TopoDS import TopoDS
from OCP.IntCurvesFace import IntCurvesFace_ShapeIntersector
from OCP.gp import gp_Dir, gp_Lin, gp_Pln, gp_Pnt


@dataclass
class SolidInfo:
    """One solid of the STEP file with the properties used to classify it."""
    index: int
    shape: object                      # TopoDS_Solid
    volume: float                      # mm^3
    centre: np.ndarray                 # centre of mass, mm
    bbox_min: np.ndarray
    bbox_max: np.ndarray
    axis: np.ndarray                   # principal axis with the distinct moment
    axis_score: float                  # how axisymmetric (0 = perfectly)
    role: str = "other"                # 'gear', 'housing' or 'other'
    teeth: int = 0                     # teeth counted in a trial section (gears)

    @property
    def bbox_size(self):
        return self.bbox_max - self.bbox_min


@dataclass
class PumpSection:
    """2D mid-plane section of the pump in the gear frame (mm)."""
    gear1: Polygon                     # drive gear, centred at (0, 0)
    gear2: Polygon                     # driven gear, centred at (a, 0)
    housing: object                    # housing material (Polygon/MultiPolygon)
    a: float                           # centre distance
    face_width: float                  # gear face width along the axis
    origin: np.ndarray                 # 3D point of the frame origin
    ex: np.ndarray                     # 3D unit vectors of the 2D frame
    ey: np.ndarray
    ez: np.ndarray                     # common gear axis direction
    section_offset: float              # position of the section along ez
    solids: list = field(default_factory=list)
    gear_indices: tuple = (0, 1)
    housing_index: tuple = ()
    z_lo: float = 0.0                  # gear end faces along ez, relative to origin
    z_hi: float = 0.0


# --------------------------------------------------------------------------
# STEP loading and solid properties
# --------------------------------------------------------------------------

def load_step(path):
    """Return the list of solids in a STEP file (TopoDS_Solid objects)."""
    reader = STEPControl_Reader()
    status = reader.ReadFile(str(path))
    if status != IFSelect_RetDone:
        raise IOError(f"Could not read STEP file: {path}")
    reader.TransferRoots()
    shape = reader.OneShape()
    solids = []
    exp = TopExp_Explorer(shape, TopAbs_SOLID)
    while exp.More():
        solids.append(TopoDS.Solid_s(exp.Current()))
        exp.Next()
    if not solids:
        raise ValueError("The STEP file contains no solids.")
    return solids


def solid_info(index, solid):
    props = GProp_GProps()
    BRepGProp.VolumeProperties_s(solid, props)
    c = props.CentreOfMass()
    pp = props.PrincipalProperties()
    moments = np.array(pp.Moments())
    axes = [pp.FirstAxisOfInertia(), pp.SecondAxisOfInertia(), pp.ThirdAxisOfInertia()]
    axes = [np.array([v.X(), v.Y(), v.Z()]) for v in axes]
    # the symmetry axis is the one whose moment differs from the other two
    best, score = 0, np.inf
    for k in range(3):
        others = np.delete(moments, k)
        s = abs(others[0] - others[1]) / max(abs(others).max(), 1e-12)
        if s < score:
            best, score = k, s
    box = Bnd_Box()
    BRepBndLib.Add_s(solid, box)
    xmin, ymin, zmin, xmax, ymax, zmax = box.Get()
    return SolidInfo(index, solid, props.Mass(), np.array([c.X(), c.Y(), c.Z()]),
                     np.array([xmin, ymin, zmin]), np.array([xmax, ymax, zmax]),
                     axes[best] / np.linalg.norm(axes[best]), score)


# --------------------------------------------------------------------------
# Sections
# --------------------------------------------------------------------------

def _edge_points(edge, deflection):
    curve = BRepAdaptor_Curve(edge)
    disc = GCPnts_QuasiUniformDeflection(curve, deflection)
    if not disc.IsDone() or disc.NbPoints() < 2:
        return None
    pts = []
    for i in range(1, disc.NbPoints() + 1):
        p = disc.Value(i)
        pts.append((p.X(), p.Y(), p.Z()))
    return np.array(pts)


def _snap_ends(lines, tol=1e-5):
    """Merge edge end points closer than tol so the section edges close up.

    Edges evaluated from their own curves end a few 1e-7 mm away from the
    shared vertex, which is enough to stop polygonize from finding faces.
    """
    ends = np.array([[ln.coords[0], ln.coords[-1]] for ln in lines]).reshape(-1, 2)
    rep = np.arange(len(ends))
    cells = {}
    for i, p in enumerate(ends):
        key = (int(np.floor(p[0] / tol)), int(np.floor(p[1] / tol)))
        found = None
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in cells.get((key[0] + dx, key[1] + dy), ()):
                    if np.hypot(*(ends[j] - p)) <= tol:
                        found = j
                        break
                if found is not None:
                    break
            if found is not None:
                break
        if found is None:
            cells.setdefault(key, []).append(i)
        else:
            rep[i] = found
    out = []
    for k, ln in enumerate(lines):
        c = np.asarray(ln.coords).copy()
        c[0], c[-1] = ends[rep[2 * k]], ends[rep[2 * k + 1]]
        if len(c) == 2 and np.allclose(c[0], c[1]):
            continue
        out.append(LineString(c))
    return out


def section_polygon(solid, origin, ex, ey, ez, offset, deflection=0.002):
    """Cut a solid with the plane (origin + offset*ez, normal ez).

    Returns the material region as a shapely (Multi)Polygon in the (ex, ey)
    frame, or None if the plane misses the solid.
    """
    p0 = origin + offset * ez
    plane = gp_Pln(gp_Pnt(*p0), gp_Dir(*ez))
    sec = BRepAlgoAPI_Section(solid, plane)
    sec.Build()
    if not sec.IsDone():
        return None
    lines = []
    exp = TopExp_Explorer(sec.Shape(), TopAbs_EDGE)
    while exp.More():
        pts = _edge_points(TopoDS.Edge_s(exp.Current()), deflection)
        exp.Next()
        if pts is None:
            continue
        rel = pts - p0
        xy = np.column_stack([rel @ ex, rel @ ey])
        if len(xy) >= 2:
            lines.append(LineString(xy))
    if not lines:
        return None
    faces = list(polygonize(unary_union(_snap_ends(lines))))
    # keep the faces that are material (inside the solid)
    classifier = BRepClass3d_SolidClassifier(solid)
    keep = []
    for f in faces:
        rp = f.representative_point()
        q = p0 + rp.x * ex + rp.y * ey
        classifier.Perform(gp_Pnt(*q), 1e-6)
        if classifier.State() in (TopAbs_IN, TopAbs_ON):
            keep.append(f)
    if not keep:
        return None
    region = unary_union(keep)
    return region.buffer(0)


def _frame_from_axis(axis):
    ez = axis / np.linalg.norm(axis)
    tmp = np.array([1.0, 0, 0]) if abs(ez[0]) < 0.9 else np.array([0, 1.0, 0])
    ex = np.cross(ez, tmp)
    ex /= np.linalg.norm(ex)
    ey = np.cross(ez, ex)
    return ex, ey, ez


def count_teeth(poly, centre_xy):
    """Count teeth of a toothed 2D region from its outer boundary."""
    if poly is None or poly.is_empty:
        return 0
    if isinstance(poly, MultiPolygon):
        poly = max(poly.geoms, key=lambda g: g.area)
    xy = np.asarray(poly.exterior.coords) - np.asarray(centre_xy)
    r = np.hypot(xy[:, 0], xy[:, 1])
    if r.max() <= 0:
        return 0
    phi = np.unwrap(np.arctan2(xy[:, 1], xy[:, 0]))
    if abs(phi[-1] - phi[0]) < 1.5 * np.pi:      # centre not inside: not a gear
        return 0
    mid = 0.5 * (r.max() + r.min())
    if (r.max() - r.min()) < 0.02 * r.max():     # round: shaft or disc
        return 0
    above = r > mid
    return int(np.sum(above & ~np.roll(above, 1)))


def _axis_extent(info, axis_point, ez):
    """Extent of a solid along ez, measured from axis_point (bbox corners)."""
    corners = np.array([[x, y, z] for x in (info.bbox_min[0], info.bbox_max[0])
                        for y in (info.bbox_min[1], info.bbox_max[1])
                        for z in (info.bbox_min[2], info.bbox_max[2])])
    s = (corners - axis_point) @ ez
    return s.min(), s.max()


def _vertex_axis_extent(solid, axis_point, ez):
    """Extent of a solid along ez from its vertices (exact for spur gears,
    whose end faces are planes normal to the axis)."""
    vals = []
    exp = TopExp_Explorer(solid, TopAbs_VERTEX)
    while exp.More():
        p = BRep_Tool.Pnt_s(TopoDS.Vertex_s(exp.Current()))
        vals.append((np.array([p.X(), p.Y(), p.Z()]) - axis_point) @ ez)
        exp.Next()
    if not vals:
        return None
    return min(vals), max(vals)


# --------------------------------------------------------------------------
# Classification and the pump section
# --------------------------------------------------------------------------

def classify(solids):
    """Find the two gears and the housing among the solids."""
    infos = [solid_info(i, s) for i, s in enumerate(solids)]
    for info in infos:
        ex, ey, ez = _frame_from_axis(info.axis)
        poly = section_polygon(info.shape, info.centre, ex, ey, ez, 0.0, 0.01)
        info.teeth = count_teeth(poly, (0.0, 0.0)) if poly is not None else 0
    gears = [i for i in infos if i.teeth >= 4 and i.axis_score < 0.05]
    if len(gears) < 2:
        raise ValueError(
            f"Found {len(gears)} gear(s); the pump needs two external spur gears. "
            "Check that the STEP file contains both gears as separate solids.")
    if len(gears) > 2:
        # keep the pair with parallel axes that are closest together
        best = None
        for i in range(len(gears)):
            for j in range(i + 1, len(gears)):
                g1, g2 = gears[i], gears[j]
                par = abs(abs(g1.axis @ g2.axis) - 1)
                d = np.linalg.norm(np.cross(g2.centre - g1.centre, g1.axis))
                key = (par > 1e-3, d)
                if best is None or key < best[0]:
                    best = (key, (g1, g2))
        gears = list(best[1])
    for g in gears:
        g.role = "gear"
    others = [i for i in infos if i.role != "gear"]
    if not others:
        raise ValueError("No housing found: the STEP file must contain the housing as a solid.")
    # every other solid cut by the gear mid-plane is part of the housing
    # (body, bushings, port inserts); solids beside the gears are ignored later
    for o in others:
        o.role = "housing"
    return infos, gears, others


def build_section(infos, gear_a, gear_b, housing, drive_index=None,
                  section_fraction=0.5, deflection=0.002):
    """Mid-face-width section of both gears and the housing in the gear frame."""
    if drive_index is not None and drive_index == gear_b.index:
        gear_a, gear_b = gear_b, gear_a
    ez = gear_a.axis.copy()
    if abs(abs(ez @ gear_b.axis) - 1) > 1e-3:
        raise ValueError("The two gear axes are not parallel.")
    # axis points: centres of mass projected on a common plane
    c1, c2 = gear_a.centre, gear_b.centre
    d = c2 - c1
    d_perp = d - (d @ ez) * ez
    a = np.linalg.norm(d_perp)
    if a <= 0:
        raise ValueError("The two gears are on the same axis.")
    ex = d_perp / a
    ey = np.cross(ez, ex)
    origin = c1.copy()
    # face width from gear 1 (refined along the axis)
    ext = _vertex_axis_extent(gear_a.shape, origin, ez)
    s0, s1 = ext if ext is not None else _axis_extent(gear_a, origin, ez)
    face_width = s1 - s0
    offset = s0 + section_fraction * face_width
    g1 = section_polygon(gear_a.shape, origin, ex, ey, ez, offset, deflection)
    g2 = section_polygon(gear_b.shape, origin, ex, ey, ez, offset, deflection)
    if g1 is None or g2 is None:
        raise ValueError("The mid-plane section misses a gear.")
    housing = housing if isinstance(housing, (list, tuple)) else [housing]
    parts, used = [], []
    for h in housing:
        hp = section_polygon(h.shape, origin, ex, ey, ez, offset, deflection)
        if hp is not None:
            parts.append(hp)
            used.append(h.index)
        else:
            h.role = "other"
    if not parts:
        raise ValueError("The mid-plane section misses the housing.")
    hs = unary_union(parts)
    g1 = max(g1.geoms, key=lambda g: g.area) if isinstance(g1, MultiPolygon) else g1
    g2 = max(g2.geoms, key=lambda g: g.area) if isinstance(g2, MultiPolygon) else g2
    return PumpSection(gear1=g1, gear2=g2, housing=hs, a=a, face_width=face_width,
                       origin=origin + offset * ez, ex=ex, ey=ey, ez=ez,
                       section_offset=offset, solids=infos,
                       gear_indices=(gear_a.index, gear_b.index),
                       housing_index=tuple(used),
                       z_lo=s0 - offset, z_hi=s1 - offset)


def read_pump(path, drive_index=None, section_fraction=0.5, deflection=0.002):
    """Load a STEP file and return (PumpSection, list of SolidInfo)."""
    solids = load_step(path)
    infos, gears, housing = classify(solids)
    sec = build_section(infos, gears[0], gears[1], housing, drive_index,
                        section_fraction, deflection)
    return sec


def housing_section(sec, dz, deflection=0.002):
    """Housing region in the plane dz (mm along ez) from the main section."""
    parts = []
    for i in sec.housing_index:
        hp = section_polygon(sec.solids[i].shape, sec.origin, sec.ex, sec.ey, sec.ez,
                             dz, deflection)
        if hp is not None:
            parts.append(hp)
    return unary_union(parts) if parts else None


def lateral_gaps(sec, r, angles, reach=20.0):
    """Axial clearance between the drive gear's end faces and the housing.

    Rays are cast along +ez from the upper face and -ez from the lower face,
    at radius r (mm, around the drive gear axis) and the given angles (rad,
    in the section frame). Returns (gap_upper, gap_lower) in mm: the median
    over the rays, or None where no housing part closes that side.
    """
    hits = {+1: [], -1: []}
    # every solid that is not a gear (body, covers, side plates, bushings)
    shapes = [s.shape for s in sec.solids if s.index not in sec.gear_indices]
    for side, z0 in ((+1, sec.z_hi), (-1, sec.z_lo)):
        for ang in angles:
            p = sec.origin + z0 * sec.ez + r * (np.cos(ang) * sec.ex + np.sin(ang) * sec.ey)
            d = side * sec.ez
            best = None
            for shp in shapes:
                inter = IntCurvesFace_ShapeIntersector()
                inter.Load(shp, 1e-7)
                inter.Perform(gp_Lin(gp_Pnt(*p), gp_Dir(*d)), -1e-6, reach)
                for k in range(1, inter.NbPnt() + 1):
                    w = inter.WParameter(k)
                    if best is None or w < best:
                        best = w
            if best is not None:
                hits[side].append(max(best, 0.0))
    out = []
    for side in (+1, -1):
        h = hits[side]
        out.append(float(np.median(h)) if len(h) >= max(1, len(angles) // 2) else None)
    return tuple(out)
