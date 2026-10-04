"""Run the full gear pump extraction: STEP -> gears -> chambers -> results."""

from dataclasses import dataclass, field

import numpy as np

from .cad import read_pump, housing_section, lateral_gaps
from .gears import analyse_gear, analyse_pair, set_module
from .kinematics import analyse_kinematics


@dataclass
class Settings:
    drive_index: int = None          # solid index of the drive gear (None = first found)
    direction: int = 1               # +1 drive gear CCW in the section frame, -1 CW
    alpha_deg: float = None          # force the reference pressure angle (None = auto)
    angle_step_deg: float = 1.0      # chamber angle step
    mesh_points: int = 181           # samples over one tooth pitch for the trapped volume
    n_slices: int = 9                # initial sections across the face width (refined
                                     # automatically at port edges)
    deflection: float = 0.002        # CAD edge discretisation, mm
    contact_tol: float = 0.005       # flank gaps below this count as closed (coast side), mm


@dataclass
class PumpResult:
    file: str
    settings: Settings
    section: object
    gear1: object
    gear2: object
    pair: object
    kin: object
    kinematics: object = None        # PumpKinematics (geometry at any angle)
    lateral_gaps: tuple = (None, None)   # axial gaps above / below the drive gear, mm
    log: list = field(default_factory=list)


def analyse_pump(path, settings=None, progress=None):
    st = settings or Settings()
    log = []

    def say(msg):
        log.append(msg)
        if progress:
            progress(msg)

    say("Reading STEP and finding the gears and housing ...")
    sec = read_pump(path, st.drive_index, 0.5, st.deflection)
    gi = sec.gear_indices
    say(f"Gears: solids {gi[0]} (drive) and {gi[1]}; housing parts {list(sec.housing_index)}; "
        f"centre distance {sec.a:.4f} mm; face width {sec.face_width:.4f} mm")
    say("Fitting the involute profiles ...")
    g1 = analyse_gear(sec.gear1, (0.0, 0.0), st.alpha_deg)
    g2 = analyse_gear(sec.gear2, (sec.a, 0.0), st.alpha_deg)
    if st.alpha_deg is None and abs(g1.alpha_deg - g2.alpha_deg) > 1e-9:
        # both gears of a pair share module and pressure angle: use the better fit
        set_module(g2, g1.alpha_deg)
    pair = analyse_pair(g1, g2, sec.a, sec.face_width)
    say(f"z = {g1.z}/{g2.z}, m = {g1.module:.4f} mm, alpha = {g1.alpha_deg:g} deg, "
        f"x = {g1.x:.4f}/{g2.x:.4f}, displacement = {pair.displacement:.4f} cm3/rev")
    say("Rotating the gears: tooth space volumes, port areas, trapped volume ...")

    def housing_at(z):
        return housing_section(sec, z, st.deflection)

    kin, kobj = analyse_kinematics(sec, g1, g2, housing_at, st.n_slices, st.direction,
                                   st.angle_step_deg, st.mesh_points, st.contact_tol)
    say(f"Housing sectioned at {len(kin.slice_levels)} levels across the face width")
    say(f"Displacement from chamber volumes: {kin.D_cv:.4f} cm3/rev; "
        f"tip clearance {kin.tip_clearance1:.4f}/{kin.tip_clearance2:.4f} mm")
    angs = g1.tooth_centre0 + 2 * np.pi / g1.z * np.arange(0, g1.z, max(g1.z // 4, 1))
    lat = lateral_gaps(sec, 0.5 * (g1.rf + g1.ra), angs)
    if lat == (None, None):
        say("No end covers / side plates found against the gear faces: lateral gaps n/a.")
    else:
        fmt = lambda v: "open" if v is None else f"{v:.4f} mm"
        say(f"Lateral gaps: upper {fmt(lat[0])}, lower {fmt(lat[1])}")
    for w in kin.warnings:
        say("WARNING: " + w)
    return PumpResult(str(path), st, sec, g1, g2, pair, kin, kobj, lat, log)
