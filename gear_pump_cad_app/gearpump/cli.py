"""Command line: python -m gearpump.cli pump.step [-o out_dir] [options]"""

import argparse
import sys

from .analysis import Settings, analyse_pump
from .export import export_all, report_text


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="gearpump",
        description="Extract external gear pump geometry (gears, chamber volumes, "
                    "port areas, trapped volume) from a STEP model for Amesim.")
    p.add_argument("step", help="STEP file with the housing and the two gears")
    p.add_argument("-o", "--out", default=None, help="output folder (default: <step>_amesim)")
    p.add_argument("--drive", type=int, default=None,
                   help="solid index of the drive gear (default: first gear found)")
    p.add_argument("--cw", action="store_true",
                   help="drive gear turns clockwise in the section frame (default CCW)")
    p.add_argument("--alpha", type=float, default=None,
                   help="reference pressure angle in deg (default: chosen automatically)")
    p.add_argument("--step-deg", type=float, default=1.0, help="chamber angle step, deg")
    p.add_argument("--mesh-points", type=int, default=181,
                   help="samples over one tooth pitch for the trapped volume")
    p.add_argument("--slices", type=int, default=9,
                   help="sections across the face width for the port areas")
    p.add_argument("--contact-tol", type=float, default=0.005,
                   help="normal backlash below this closes the coast flanks too "
                        "(zero-backlash CAD), mm")
    a = p.parse_args(argv)
    st = Settings(drive_index=a.drive, direction=-1 if a.cw else 1, alpha_deg=a.alpha,
                  angle_step_deg=a.step_deg, mesh_points=a.mesh_points,
                  n_slices=a.slices, contact_tol=a.contact_tol)
    res = analyse_pump(a.step, st, progress=lambda m: print(m, flush=True))
    out = a.out or (a.step.rsplit(".", 1)[0] + "_amesim")
    files = export_all(res, out)
    print()
    print(report_text(res))
    print(f"Wrote {len(files)} files to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
