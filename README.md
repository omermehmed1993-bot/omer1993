# Amesim ND table maker (MATLAB)

`make_amesim_table.m` is a single file that converts Excel column data
(one row per point: input columns, then the output column) into a
Simcenter Amesim table file (`# Table format: 1D` … `8D`).

1. Open `make_amesim_table.m` and edit the **USER SETTINGS** block at the top.
2. Press **Run** (F5). If `excelFile` is empty, a file dialog asks for the data file.

Settings can also be given on the command line:

```matlab
make_amesim_table('excelFile', 'Example.xlsx', 'tableUnit', 'kg/s')
```

**Column order = breakpoint order in the file:** the 1st input column is the
1st breakpoint (axis X1, written first), the 2nd column is X2, and so on; the
last column is the value. Reorder with `inputColumns` if needed. The data must contain every combination of the input values
(a full grid), unless `fillMissing` is set. After writing, the file is read
back and every data row is checked against it.


## Input signals (time tables) for the lookup table

When run, both tools **ask for the Amesim total simulation time and number of
intervals** (a dialog, or command-window prompts), then write next to the table
one **1D table per input** with **time as the x axis** and that input as y,
plus one for the expected output:

```
<table>_input1_<name>.txt  ...  <table>_inputN_<name>.txt   (# Table format: 1D, x = time [s])
<table>_expected_<value>.txt                                 (x = time, y = data output)
```

All files are sampled on the Amesim print grid `t = 0 : T/N : T` (N intervals,
N + 1 points). The data rows are spread over these points in sheet order, each
row held for an equal number of points, so at every print time all inputs equal
one data row and the table output equals that row's value. N must be at least
rows - 1; for an equal hold on every row use N + 1 = a multiple of the number
of rows (the tool suggests values).

| Setting | Meaning | Default |
| --- | --- | --- |
| `simTime` | total simulation time [s] (Amesim final time) | `[]` = ask when run |
| `nIntervals` | number of intervals (Amesim) | `[]` = ask when run |
| `signals` | write the signal files | `true` |

Set `simTime` / `nIntervals` in the settings block (or on the command line) to
skip the question.

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
| `RPM_DP_FlowRate_MATLAB_Example.xlsx` | `make_amesim_multi1d_table('excelFile','examples/RPM_DP_FlowRate_MATLAB_Example.xlsx','tableUnit','L/min','axisUnits',{'rev/min','bar'})` | `RPM_DP_FlowRate_M1D.txt` |
| `FlightCondition_RPM_DP_FlowRate_MATLAB_Example.xlsx` | `make_amesim_multi1d_table('excelFile','examples/FlightCondition_RPM_DP_FlowRate_MATLAB_Example.xlsx','tableUnit','L/min','axisUnits',{'','rev/min','bar'})` | `FlightCondition_RPM_DP_FlowRate_MM1D.txt` |

In the M1D/MM1D examples each curve is flow against dP (X) at one RPM (Y),
with one set of curves per flight condition (Z) in the MM1D table.
