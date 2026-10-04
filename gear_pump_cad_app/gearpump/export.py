"""Write the results: Amesim 1D tables, a JSON summary, a CSV and a report."""

import csv
import json
from datetime import datetime
from pathlib import Path

import numpy as np


def _periodic(x, y, period):
    """Close a periodic table: append x0 + period with the first value."""
    return np.append(x, x[0] + period), np.append(y, y[0])


def write_table_1d(path, x, y, title, x_unit, y_unit, precision=10):
    """Amesim 1D table: '# Table format: 1D' then x y pairs."""
    fmt = f"%.{precision}g %.{precision}g\n"
    with open(path, "w", newline="\n") as f:
        f.write("# Table format: 1D\n")
        f.write(f"# {title}\n")
        f.write(f"# axis1_unit = {x_unit}\n")
        f.write(f"# table_unit = {y_unit}\n")
        for a, b in zip(x, y):
            f.write(fmt % (a, b))


def summary_dict(res):
    g1, g2, p, k = res.gear1, res.gear2, res.pair, res.kin
    sec = res.section

    def gear(g):
        d = g.as_dict()
        d["tooth_centre0_deg"] = float(np.degrees(d.pop("tooth_centre0")))
        d["psi_b_deg"] = float(np.degrees(d.pop("psi_b")))
        d["tooth_space_volume_max_mm3"] = None
        return d

    G1, G2 = gear(g1), gear(g2)
    G1["tooth_space_volume_max_mm3"] = float(k.V1.max())
    G1["tooth_space_volume_min_mm3"] = float(k.V1.min())
    G2["tooth_space_volume_max_mm3"] = float(k.V2.max())
    G2["tooth_space_volume_min_mm3"] = float(k.V2.min())
    G1["tip_clearance_mm"] = k.tip_clearance1
    G2["tip_clearance_mm"] = k.tip_clearance2
    G1["sealing_arc_deg"] = k.seal_arc1_deg
    G2["sealing_arc_deg"] = k.seal_arc2_deg
    G1["teeth_in_sealing_arc"] = k.seal_teeth1
    G2["teeth_in_sealing_arc"] = k.seal_teeth2
    G1["inlet_area_max_mm2"] = float(k.A_in1.max())
    G1["outlet_area_max_mm2"] = float(k.A_out1.max())
    G2["inlet_area_max_mm2"] = float(k.A_in2.max())
    G2["outlet_area_max_mm2"] = float(k.A_out2.max())
    trap = k.V_trap > 0
    return {
        "file": res.file,
        "created": datetime.now().isoformat(timespec="seconds"),
        "units": "mm, mm^2, mm^3, deg; displacement cm^3/rev",
        "cad": {
            "gear_solids": list(sec.gear_indices),
            "housing_solids": list(sec.housing_index),
            "axis_direction": [float(v) for v in sec.ez],
            "drive_gear_axis_point_mid_plane": [float(v) for v in sec.origin],
            "section_x_axis": [float(v) for v in sec.ex],
        },
        "drive_gear": G1,
        "driven_gear": G2,
        "pair": {
            **p.as_dict(),
            "displacement_cm3_per_rev": p.displacement,
            "chamber_volume_swing_cm3_per_rev": k.D_cv,
            "lateral_gap_upper_mm": getattr(res, "lateral_gaps", (None, None))[0],
            "lateral_gap_lower_mm": getattr(res, "lateral_gaps", (None, None))[1],
        },
        "trapped_volume": {
            "max_mm3": float(k.V_trap.max()),
            "fraction_of_pitch_trapped": float(trap.mean()),
            "pockets_max": int(k.n_trap.max()),
        },
        "rotation": {
            "direction": "CCW" if k.direction > 0 else "CW",
            "note": "seen from +axis in the section frame; inlet is where the teeth leave the mesh",
            "backlash_take_up_deg": float(np.degrees(k.delta0)),
        },
        "settings": {kk: v for kk, v in vars(res.settings).items()},
        "warnings": list(k.warnings),
    }


def export_all(res, out_dir, name=None):
    """Write every output file; returns the list of paths."""
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    name = name or Path(res.file).stem
    k = res.kin
    files = []

    def table(suffix, x, y, title, xu, yu, period):
        xs, ys = _periodic(x, y, period)
        p = out / f"{name}_{suffix}.txt"
        write_table_1d(p, xs, ys, title, xu, yu)
        files.append(p)

    psi = k.psi_deg
    table("gear1_tsv_volume", psi, k.V1, "Drive gear tooth space volume vs chamber angle",
          "degree", "mm**3", 360.0)
    table("gear2_tsv_volume", psi, k.V2, "Driven gear tooth space volume vs chamber angle",
          "degree", "mm**3", 360.0)
    table("gear1_tsv_inlet_area", psi, k.A_in1, "Drive gear tooth space to inlet area",
          "degree", "mm**2", 360.0)
    table("gear1_tsv_outlet_area", psi, k.A_out1, "Drive gear tooth space to outlet area",
          "degree", "mm**2", 360.0)
    table("gear2_tsv_inlet_area", psi, k.A_in2, "Driven gear tooth space to inlet area",
          "degree", "mm**2", 360.0)
    table("gear2_tsv_outlet_area", psi, k.A_out2, "Driven gear tooth space to outlet area",
          "degree", "mm**2", 360.0)
    th = k.theta_mesh_deg
    pitch = 360.0 / res.gear1.z
    # the mesh grid already ends at one pitch; drop the duplicate before closing it
    table("trapped_volume", th[:-1], k.V_trap[:-1],
          "Trapped volume between two contacts vs drive gear angle (one tooth pitch)",
          "degree", "mm**3", pitch)

    # everything in one CSV for spreadsheets
    p = out / f"{name}_chambers.csv"
    with open(p, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["psi_deg", "V1_mm3", "A_in1_mm2", "A_out1_mm2",
                    "V2_mm3", "A_in2_mm2", "A_out2_mm2"])
        for row in zip(psi, k.V1, k.A_in1, k.A_out1, k.V2, k.A_in2, k.A_out2):
            w.writerow([f"{v:.10g}" for v in row])
    files.append(p)
    p = out / f"{name}_trapped.csv"
    with open(p, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["theta_deg", "V_trap_mm3", "pockets", "min_flank_gap_mm"])
        for row in zip(th, k.V_trap, k.n_trap, k.contact_gap_min):
            w.writerow([f"{v:.10g}" for v in row])
    files.append(p)

    summ = summary_dict(res)
    p = out / f"{name}_summary.json"
    p.write_text(json.dumps(summ, indent=2, default=_jsonable))
    files.append(p)
    p = out / f"{name}_report.txt"
    p.write_text(report_text(res, summ))
    files.append(p)
    return files


def _jsonable(o):
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, (np.floating,)):
        return float(o)
    if isinstance(o, np.ndarray):
        return o.tolist()
    return str(o)


def report_text(res, summ=None):
    summ = summ or summary_dict(res)
    g1, g2, p, k = res.gear1, res.gear2, res.pair, res.kin
    lg = getattr(res, "lateral_gaps", (None, None))

    def f(v, n=4):
        return "n/a" if v is None or (isinstance(v, float) and not np.isfinite(v)) else f"{v:.{n}f}"

    L = []
    L.append(f"Gear pump geometry from {res.file}")
    L.append("")
    L.append(f"{'':34s}{'drive':>12s}{'driven':>12s}")
    rows = [("number of teeth z", g1.z, g2.z, 0),
            ("module m [mm]", g1.module, g2.module, 4),
            ("pressure angle alpha [deg]", g1.alpha_deg, g2.alpha_deg, 2),
            ("profile shift x [-]", g1.x, g2.x, 4),
            ("tip radius ra [mm]", g1.ra, g2.ra, 4),
            ("root radius rf [mm]", g1.rf, g2.rf, 4),
            ("base radius rb [mm]", g1.rb, g2.rb, 4),
            ("reference radius r [mm]", g1.r_pitch, g2.r_pitch, 4),
            ("form (start of involute) radius", g1.r_form, g2.r_form, 4),
            ("addendum coefficient ha* [-]", g1.ha, g2.ha, 4),
            ("dedendum coefficient hf* [-]", g1.hf, g2.hf, 4),
            ("tip land thickness [mm]", g1.tip_thickness, g2.tip_thickness, 4),
            ("shaft bore radius [mm]", g1.bore_radius, g2.bore_radius, 4),
            ("involute fit rms [mm]", g1.flank_rms, g2.flank_rms, 5),
            ("tip clearance h_r [mm]", k.tip_clearance1, k.tip_clearance2, 4),
            ("housing sealing arc [deg]", k.seal_arc1_deg, k.seal_arc2_deg, 1),
            ("teeth in sealing arc", k.seal_teeth1, k.seal_teeth2, 2),
            ("tooth space volume max [mm3]", k.V1.max(), k.V2.max(), 3),
            ("tooth space volume min [mm3]", k.V1.min(), k.V2.min(), 3),
            ("inlet area max [mm2]", k.A_in1.max(), k.A_in2.max(), 3),
            ("outlet area max [mm2]", k.A_out1.max(), k.A_out2.max(), 3)]
    for name, a, b, n in rows:
        if n == 0:
            L.append(f"{name:34s}{a:>12d}{b:>12d}")
        else:
            L.append(f"{name:34s}{f(a, n):>12s}{f(b, n):>12s}")
    L.append("")
    L.append(f"centre distance a [mm]            {p.a:.5f}")
    L.append(f"face width b [mm]                 {p.face_width:.5f}")
    L.append(f"working pressure angle [deg]      {p.alpha_w_deg:.4f}")
    L.append(f"operating pitch radii [mm]        {p.rw1:.4f} / {p.rw2:.4f}")
    L.append(f"circumferential backlash [mm]     {p.backlash:.5f}")
    L.append(f"contact ratio [-]                 {p.contact_ratio:.4f}")
    L.append(f"lateral gap upper/lower [mm]      {f(lg[0])} / {f(lg[1])}")
    L.append(f"geometric displacement [cm3/rev]  {p.displacement:.5f}")
    L.append(f"chamber volume swing [cm3/rev]    {k.D_cv:.5f}  (z x sum of tooth space volume swings)")
    L.append(f"trapped volume max [mm3]          {k.V_trap.max():.4f}  "
             f"(trapped over {100 * np.mean(k.V_trap > 0):.1f} % of a tooth pitch)")
    L.append(f"rotation (drive gear)             {'CCW' if k.direction > 0 else 'CW'} "
             "in the section frame")
    for w in k.warnings:
        L.append("WARNING: " + w)
    L.append("")
    L.append("Log:")
    L.extend("  " + m for m in res.log)
    return "\n".join(L) + "\n"
