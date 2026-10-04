"""Check the extraction against test pumps with known geometry.

The pumps in test_pumps/ are made by tools/make_test_pump.py, which writes
the design values next to each STEP file. Besides those, three independent
references are used:
  * tooth space volume away from the mesh, from the area of the rack-cut
    tooth space computed by the generator (not from the STEP file);
  * port areas, from the analytic drilled-port geometry of the test housing;
  * displacement of identical gears, from the closed form
    2 pi b (ra^2 - rw^2 - pi^2 rb^2 / (3 z^2)).

Run:  python -m pytest tests -q        (about 2 minutes)
"""

import json
import sys
from functools import lru_cache
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from gearpump.analysis import Settings, analyse_pump  # noqa: E402
from gearpump.export import export_all  # noqa: E402

PUMPS = ["pump_A", "pump_B", "pump_C"]


@lru_cache(maxsize=None)
def run(name):
    st = Settings(angle_step_deg=1.0, mesh_points=121)
    res = analyse_pump(ROOT / "test_pumps" / f"{name}.step", st)
    truth = json.loads((ROOT / "test_pumps" / f"{name}.json").read_text())
    return res, truth


@pytest.mark.parametrize("name", PUMPS)
def test_gear_parameters(name):
    res, t = run(name)
    for g, tg in ((res.gear1, t["drive_gear"]), (res.gear2, t["driven_gear"])):
        assert g.z == tg["z"]
        assert g.module == pytest.approx(t["module"], abs=2e-3)
        assert g.alpha_deg == pytest.approx(t["alpha_deg"])
        assert g.x == pytest.approx(tg["x"], abs=2e-3)
        assert g.ra == pytest.approx(tg["ra"], abs=2e-3)
        assert g.rf == pytest.approx(tg["rf"], abs=5e-3)
        assert g.rb == pytest.approx(tg["rb"], abs=5e-3)
        assert g.bore_radius == pytest.approx(tg["bore"], abs=2e-3)
        assert g.flank_rms < 2e-3


@pytest.mark.parametrize("name", PUMPS)
def test_pair(name):
    res, t = run(name)
    p = res.pair
    assert p.a == pytest.approx(t["centre_distance"], abs=1e-4)
    assert p.face_width == pytest.approx(t["face_width"], abs=1e-4)
    assert p.alpha_w_deg == pytest.approx(t["alpha_w_deg"], abs=0.01)
    assert p.backlash == pytest.approx(t["backlash"], abs=2e-3)
    assert p.contact_ratio == pytest.approx(t["contact_ratio"], abs=5e-3)


@pytest.mark.parametrize("name", PUMPS)
def test_clearances(name):
    res, t = run(name)
    assert res.kin.tip_clearance1 == pytest.approx(t["tip_clearance"], abs=1.5e-3)
    assert res.kin.tip_clearance2 == pytest.approx(t["tip_clearance"], abs=1.5e-3)
    if t.get("lateral_gap") is None:
        assert res.lateral_gaps == (None, None)
    else:
        assert res.lateral_gaps[0] == pytest.approx(t["lateral_gap"], abs=1e-4)
        assert res.lateral_gaps[1] == pytest.approx(t["lateral_gap"], abs=1e-4)


@pytest.mark.parametrize("name", ["pump_A", "pump_B"])
def test_displacement_closed_form(name):
    res, t = run(name)
    g = t["drive_gear"]
    b, ra, rb, z = t["face_width"], g["ra"], g["rb"], g["z"]
    D = 2 * np.pi * b * (ra ** 2 - t["rw1"] ** 2 - np.pi ** 2 * rb ** 2 / (3 * z ** 2)) / 1000
    assert res.pair.displacement == pytest.approx(D, rel=2e-4)


@pytest.mark.parametrize("name", PUMPS)
def test_tooth_space_volume(name):
    """Away from the mesh the tooth space volume is b x the rack-cut space area."""
    res, t = run(name)
    b = t["face_width"]
    for V, tg in ((res.kin.V1, t["drive_gear"]), (res.kin.V2, t["driven_gear"])):
        assert V.max() == pytest.approx(b * tg["tooth_space_area"], rel=1e-3)


@pytest.mark.parametrize("name", PUMPS)
def test_trapped_volume_duration(name):
    """Two tooth pairs are in contact (fluid trapped) for (eps - 1) of a pitch."""
    res, t = run(name)
    frac = np.mean(res.kin.V_trap[:-1] > 0)
    assert frac == pytest.approx(t["contact_ratio"] - 1, abs=2.0 / len(res.kin.V_trap))
    assert res.kin.n_trap.max() == 1


@pytest.mark.parametrize("name", PUMPS)
def test_port_areas_against_drilled_port(name):
    """Space-to-port area from the analytic port: a hole of diameter pw along
    y through x = a/2, z = b/2. Integrated on a fine (arc x axial) grid."""
    res, t = run(name)
    kin, k = res.kinematics, res.kin
    a, b, pw, hr = t["centre_distance"], t["face_width"], t["port_width"], t["tip_clearance"]
    for gear in (1, 2):
        g = res.gear1 if gear == 1 else res.gear2
        go = res.gear2 if gear == 1 else res.gear1
        C = np.array([0.0, 0.0]) if gear == 1 else np.array([a, 0.0])
        Co = np.array([a, 0.0]) if gear == 1 else np.array([0.0, 0.0])
        R1, R2 = t["bore_radius_1"], t["bore_radius_2"]
        A_tot = (k.A_in1 + k.A_out1) if gear == 1 else (k.A_in2 + k.A_out2)
        half_land = 0.5 * g.thickness_angle(g.ra)
        pitch = 2 * np.pi / g.z
        zz = (np.arange(400) + 0.5) / 400 * b - b / 2              # from mid plane
        for psi in (k.psi_deg[np.argmax(A_tot)],
                    k.psi_deg[np.argmin(np.abs(A_tot - 0.5 * A_tot.max()))]):
            th = kin.theta_for_psi(np.radians(psi), gear)
            rot = kin.angles(th)[gear - 1]
            a0 = g.tooth_centre0 + half_land + rot
            ang = a0 + (np.arange(400) + 0.5) / 400 * (pitch - 2 * half_land)
            r = g.ra + 0.5 * hr                    # in the tip clearance gap, as the app
            P = C + r * np.column_stack([np.cos(ang), np.sin(ang)])
            in_other_tip = np.hypot(*(P - Co).T) < go.ra
            # the V-shaped chamber between the bores: inside the other gear's bore
            in_cavity = np.hypot(*(P - Co).T) < (R2 if gear == 1 else R1)
            open_ = np.zeros((len(zz), len(ang)), bool)
            for i, z in enumerate(zz):
                in_port = (P[:, 0] - a / 2) ** 2 + z ** 2 < (pw / 2) ** 2
                open_[i] = (in_port | in_cavity) & ~in_other_tip
            arc = g.ra * (pitch - 2 * half_land)
            A_ref = open_.mean() * arc * b
            A_app = A_tot[k.psi_deg == psi][0]
            assert A_app == pytest.approx(A_ref, rel=0.03, abs=0.01 * A_tot.max()), (gear, psi)


def test_export(tmp_path):
    res, _ = run("pump_A")
    files = export_all(res, tmp_path)
    names = {f.name for f in files}
    assert "pump_A_gear1_tsv_volume.txt" in names
    txt = (tmp_path / "pump_A_gear1_tsv_volume.txt").read_text().splitlines()
    assert txt[0] == "# Table format: 1D"
    data = np.loadtxt(tmp_path / "pump_A_gear1_tsv_volume.txt", comments="#")
    assert data[0, 0] == 0 and data[-1, 0] == 360 and data[0, 1] == data[-1, 1]
    assert np.all(np.diff(data[:, 0]) > 0)
    summ = json.loads((tmp_path / "pump_A_summary.json").read_text())
    assert summ["drive_gear"]["z"] == 12
