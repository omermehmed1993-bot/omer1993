# Amesim table makers (MATLAB)

Three single-file MATLAB tools (edit the settings block at the top, press **Run**):

| File | Makes |
| --- | --- |
| `make_amesim_table.m` | ND tables (`# Table format: 1D` … `8D`) from Excel column data, plus input-signal tables |
| `make_amesim_multi1d_table.m` | M1D (`T1D`) and MM1D (`T3D`) tables, plus input-signal tables |
| `make_amesim_mission_signals.m` | input-signal tables from a real mission profile, checked against a table |

## ND tables

`make_amesim_table.m` converts Excel column data (one row per point: input
columns, then the output column) into a Simcenter Amesim table file.

1. Open `make_amesim_table.m` and edit the **USER SETTINGS** block at the top.
2. Press **Run** (F5). If `excelFile` is empty, a file dialog asks for the data file.

Settings can also be given on the command line:

```matlab
make_amesim_table('excelFile', 'Example.xlsx', 'tableUnit', 'kg/s')
```

**Column order = breakpoint order in the file:** the 1st input column is the
1st breakpoint (axis X1, written first), the 2nd column is X2, and so on; the
last column is the value; a time column is skipped. Reorder with `inputColumns` if needed. The data must contain every combination of the input
values (a full grid), unless `fillMissing` is set. After writing, the file is read
back and every data row is checked against it.


## Input signals (time tables) for the lookup table

Both tools write, next to the table, one **1D table per input** with **time
as the x axis** and that input as y, plus one for the expected output:

```
<table>_input1_<name>.txt  ...  <table>_inputN_<name>.txt   (# Table format: 1D, x = time [s])
<table>_expected_<value>.txt                                 (x = time, y = data output)
```

All signal files share one time vector, taken from:

- **the sheet's time column**, if it has one (header `time`, `Time_s`,
  `Time [s]`, `t` …): every row is applied at its own time and nothing is
  asked. The tool prints the matching Amesim final time and print interval.
- **the Amesim print grid** otherwise: the tools ask for the **total
  simulation time and number of intervals** (a dialog, or command-window
  prompts) and sample `t = 0 : T/N : T` (N intervals, N + 1 points). The data
  rows are spread over these points, each row held for an equal number of
  points. N must be at least rows - 1; for an equal hold use N + 1 = a multiple
  of the number of rows (the tool suggests values).

At every row time all inputs equal one data row, so the table output equals
that row's value.

| Setting | Meaning | Default |
| --- | --- | --- |
| `signalTime` | `'auto'` = sheet time column if there is one, else grid; `'sheet'`; `'grid'` | `'auto'` |
| `simTime` | grid only: total simulation time [s] (Amesim final time) | `[]` = ask when run |
| `nIntervals` | grid only: number of intervals (Amesim) | `[]` = ask when run |
| `signals` | write the signal files | `true` |

Set `simTime` / `nIntervals` in the settings block (or on the command line) to
skip the question.

| Setting | Meaning | Default |
| --- | --- | --- |
| `rowOrder` | grid only: `'sheet'`, or `'snake'`: rows are played so that consecutive rows differ in one input by one breakpoint (smaller jumps) | `'sheet'` |
| `timeColumn` | a time column in the sheet is found by its header (`time`, `Time_s`, `Time [s]`, `t` …), never used as a table input, and gives the signal time; or give its column number, or `0` for none | `'auto'` |

### Optional off-grid test

`offGridPoints = 0` (the default) switches it off completely: nothing else in
the output changes. With `offGridPoints > 0` the tools also write
`<table>_offgrid_input<k>_<name>.txt` and `<table>_offgrid_expected_<value>.txt`:
random points between the breakpoints with the linearly interpolated table
output (for M1D/MM1D: along x inside the curves, then between curves), on the
same time grid, to check that Amesim interpolates as expected.
`offGridAxes` limits which breakpoints move off-grid (e.g. `[2 3 4 5]` keeps
FlightStage on its values) and `offGridSeed` makes the points repeatable.

## Mission profiles

`make_amesim_mission_signals.m` (same style: settings block, press **Run**)
turns a real profile into input signals: an Excel sheet with a time column and
one column per table input, in breakpoint order.

```matlab
make_amesim_mission_signals('excelFile', 'mission.xlsx', 'tableFile', 'examples/FADEC_FLOW_Demand_5D.txt')
```

It writes one 1D table per input (x = time). With `tableFile` set (an ND, M1D
or MM1D table) it also checks every input against the table's breakpoint
ranges, reports where the profile leaves them, and, if the whole profile is
inside, writes the expected table output along the mission.

## M1D and MM1D tables

`make_amesim_multi1d_table.m` works the same way (settings block on top,
press **Run**) and writes the "Multi 1D" formats, where each curve can have
its own x points:

The sheet columns follow the same rule, **column order = breakpoint order in
the file**:

| Format | Header | Column 1 | Column 2 | Column 3 | Column 4 |
| --- | --- | --- | --- | --- | --- |
| M1D  | `# Table format: T1D` | Y (one curve per value) | X (curve abscissa) | value | |
| MM1D | `# Table format: T3D` | Z (one block per value) | Y (one curve per value) | X (curve abscissa) | value |

For example, `FlightCondition | RPM | dP_bar | Flow` gives

```
# Table format: T3D
1 7            <- FlightCondition 1, 7 RPM curves
  3000 7       <- RPM 3000, 7 points
    5 18.975   <- dP_bar  Flow
    ...
```

Use the `columns` setting to pick or reorder sheet columns, e.g. `[1 2 3 4]`.
`axisUnits` follows the same column order.

Each (X, Y[, Z]) point must appear only once (see `duplicates`).

## Examples

The `examples/` folder has each input sheet next to the table and the input-signal files made from it (print interval 0.5 s, each row held for 1 s; MM1D: `simTime` 440.5 s / 881 intervals, M1D: 48.5 s / 97, 5D: 4724.5 s / 9449):

| Input | Command | Output |
| --- | --- | --- |
| `Example.xlsx` (5 inputs, 4725 rows) | `make_amesim_table('excelFile','examples/Example.xlsx','tableUnit','kg/s')` | `FADEC_FLOW_Demand_5D.txt` |
| `Example_with_time.xlsx` (time column + 5 inputs) | `make_amesim_table('excelFile','examples/Example_with_time.xlsx','tableUnit','kg/s')`: signals at the sheet times 0.1 … 472.5 s, no questions | same 5D table + signals |
| `RPM_DP_FlowRate_MATLAB_Example.xlsx` | `make_amesim_multi1d_table('excelFile','examples/RPM_DP_FlowRate_MATLAB_Example.xlsx','tableUnit','L/min','axisUnits',{'rev/min','bar'})` | `RPM_DP_FlowRate_M1D.txt` |
| `FlightCondition_RPM_DP_FlowRate_MATLAB_Example.xlsx` | `make_amesim_multi1d_table('excelFile','examples/FlightCondition_RPM_DP_FlowRate_MATLAB_Example.xlsx','tableUnit','L/min','axisUnits',{'','rev/min','bar'})` | `FlightCondition_RPM_DP_FlowRate_MM1D.txt` |

In the M1D/MM1D examples each curve is flow against dP (X) at one RPM (Y),
with one set of curves per flight condition (Z) in the MM1D table.

## Gear pump CAD → Amesim (Python app)

`gear_pump_cad_app/` holds a desktop app that reads the STEP model of an
external gear pump (housing + two spur gears). It extracts the gear parameters,
tooth space volumes, port areas, trapped volume and clearances, and writes them
as Amesim tables. See [gear_pump_cad_app/README.md](gear_pump_cad_app/README.md).
