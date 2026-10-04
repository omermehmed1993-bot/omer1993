# Gear Pump CAD → Amesim

A Python desktop app (and command line tool) that reads the STEP model of an
**external gear pump** (a housing plus two spur gears, in their assembled
positions) and extracts what a lumped Simcenter Amesim gear pump model needs:

* **gear parameters**: number of teeth, module, pressure angle, profile shift,
  tip / root / base / reference radii, addendum and dedendum coefficients, tip
  land, shaft bore;
* **pair data**: centre distance, face width, working pressure angle, operating
  pitch radii, backlash, contact ratio, theoretical displacement;
* **volumes vs angle**: tooth space (chamber) volume of each gear over a turn,
  and the trapped volume between two contact points over a tooth pitch;
* **areas vs angle**: connection area of each tooth space to the inlet and to
  the outlet;
* **leakage geometry**: radial tip clearance, housing sealing arc, teeth inside
  the sealing arc, and the axial (lateral) gaps to the end covers.

Unlike CAD import that relies on a template geometry, everything is measured
from the solids: any tooth count, module, profile shift, unequal gears,
housing split into several solids, drilled ports or slots.

## Install

```
pip install -r requirements.txt
```

(`cadquery` brings `cadquery-ocp`, the OpenCascade kernel. Python 3.10+.)

## Use

Desktop app:

```
python run_app.py                 # then Open STEP ... -> Analyse -> Export for Amesim ...
python run_app.py my_pump.step    # pre-select a file
```

The **Section** tab shows the mid-plane section. A slider turns the gears, and
the view highlights one tooth space of each gear and the trapped volume.
**Volumes and areas** plots the curves, **Results** lists every value, and
**Log** shows what was found.

Command line:

```
python -m gearpump.cli my_pump.step -o out_folder [--cw] [--alpha 20] [--step-deg 1]
```

### Settings

| setting | meaning |
|---|---|
| rotation (`--cw`) | drive gear rotation as seen in the section view (default CCW). The inlet is where the teeth leave the mesh: +y for CCW. |
| drive gear (`--drive`) | solid index of the drive gear (default: the first gear found) |
| pressure angle (`--alpha`) | The CAD fixes the base radius `rb = m z cos(alpha)/2`, but not `m` and `alpha` separately. By default the standard pressure angle that gives the nearest ISO 54 module is used. Set it to override. |
| angle step | chamber angle step of the tables |
| mesh samples | samples over one tooth pitch for the trapped volume |
| slices | initial number of sections across the face width. More are added automatically where the port outline changes (drilled holes, port edges). |
| contact tolerance | CAD flank gaps smaller than this count as closed. It only matters for zero-backlash models, where the coast flanks also touch. |

## Output files (`export`)

Amesim 1D tables (`# Table format: 1D`, x = angle in degree, closed over the
period so they can be used cyclically):

| file | x | y |
|---|---|---|
| `<name>_gear1_tsv_volume.txt` | chamber angle ψ, 0–360° | drive gear tooth space volume [mm³] |
| `<name>_gear2_tsv_volume.txt` | ψ of the driven gear | driven gear tooth space volume [mm³] |
| `<name>_gear1_tsv_inlet_area.txt` / `_outlet_area` | ψ | tooth space → inlet / outlet area [mm²] |
| `<name>_gear2_tsv_inlet_area.txt` / `_outlet_area` | ψ | the same for the driven gear |
| `<name>_trapped_volume.txt` | drive gear angle over one tooth pitch | trapped volume [mm³] (0 while only one pair is in contact) |

Also written:
* `<name>_chambers.csv`: all chamber curves;
* `<name>_trapped.csv`: trapped volume, number of pockets, smallest flank gap;
* `<name>_summary.json`: every scalar;
* `<name>_report.txt`: a readable report.

## Conventions and method

* **Frame**: the drive gear axis is the origin, the driven gear lies on +x, and z is the
  gear axis. Gears are recognised by shape: a solid whose cross-section has a
  periodic toothed profile. Every other solid cut by the gear mid-plane is
  housing.
* **Chamber angle ψ**: position of a tooth space centre, measured from the line
  of centres (pointing at the other gear) in that gear's direction of rotation.
  ψ = 0 is the space in the middle of the mesh.
* **Tooth space volume (TSV)**: the fluid between two adjacent tooth centre lines,
  inside the tip circle, less what the other gear's teeth fill in the mesh.
  The overlap of the two tip circles is split on the line through their
  intersections, so no fluid is counted twice.
* **Port areas**: the part of a space's tip opening (the arc between the two tip
  lands) that faces a port rather than the sealing bore. The tip clearance there
  must be at least 3 × h_r. The open arc is found on sections across the face
  width and integrated as arc × slice thickness, so a drilled port narrower
  than the gear is handled correctly.
* **Involute fit**: the base radius is fitted to the flank points (the
  base-angle scatter is minimised), first on the upper flank, then extended
  down to the start of the involute. The fit rms is reported. Profile shift
  comes from the tooth thickness on the reference circle.
* **Contacts and trapped volume**: contacts are the points where a driving flank
  crosses the line of action between the two tip circles. They are computed from
  the fitted involutes, so micrometre spline errors in the CAD do not matter.
  Fluid enclosed between two contacts is the trapped volume.
* **Displacement**: Manring & Kasaragadda (2003), integrated over the theoretical
  sealing contact. For identical gears it equals
  `2 π b (ra² − rw² − π² rb² / (3 z²))`. The report also gives the *chamber
  volume swing* `z (ΔV1 + ΔV2)`. It is a few percent higher, because part of
  each space's volume decrease flows back across the contact.

## Validation

`tools/make_test_pump.py` builds test pumps by simulating a rack cutter, so the
flanks are true involutes with trochoid root fillets. The flanks are written as
B-splines and the housing bore as true cylinders, with drilled ports and
optional end covers. A JSON file with the design values is written beside each
STEP file. `tests/test_validation.py` compares the app against three of them:

* pump A: z 12/12, m 3, α 20°, x 0.2;
* pump B: z 14/14, m 2.5, x 0, with end covers;
* pump C: z 13/15, m 2, α 25°, x 0.3/0.1.

```
python -m pytest tests -q
```

Checked:
* z, m, α, x, ra, rf, rb and bore;
* centre distance, working pressure angle, backlash and contact ratio;
* tip clearance and lateral gaps;
* displacement against the closed form;
* tooth space volume against the generator's rack-cut space area;
* trapped duration against (ε − 1) of a pitch;
* port areas against the analytic drilled-port geometry;
* the export format.

Typical agreement: rb and module within a few µm, backlash within 0.1 µm,
displacement within 0.01 %, port areas within 3 %.

The app was also checked against a second, independently written generator,
which makes backlash by thinning the driven gear rather than by opening the
centre distance. It reproduced that generator's displacement (14.59668 vs
14.596679 cm³/rev), working pressure angle, contact ratio, backlash, tip lands
and clearances.

## Limits (current version)

* Spur gears only (helical gears are not supported yet). Profile modifications
  such as tip relief are measured, but contacts assume a pure involute.
* Lateral grooves and relief grooves machined in side plates or bushings are
  outside the gear face width and are not analysed yet. The trapped-volume
  relief areas therefore come out as zero. Ports in the housing body are
  handled.
* Nominal CAD models often have the tips touching the bore (h_r = 0). The app
  warns about this; enter the real clearance in Amesim.
* Parameter names follow gear and pump nomenclature. They will be mapped to the
  exact parameter names of the Amesim *Hydraulic Component* gear pump once that
  list is available.
