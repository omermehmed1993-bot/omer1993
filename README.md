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

Both tools also write, next to the table, one **1D table per input** with
**time as the x axis** and that input column as y, plus one for the expected
output:

```
<table>_input1_<name>.txt  ...  <table>_inputN_<name>.txt   (# Table format: 1D, x = time [s])
<table>_expected_<value>.txt                                 (x = time, y = data output)
```

All signal files share one time vector: sheet row k is at
`t = (k-1) * simTime / (rows-1)`, in sheet order. Connecting input k of the
lookup table to signal file k makes the table output reproduce the data
column at every row time. Set these to match the Amesim run parameters:

| Setting | Meaning | Default |
| --- | --- | --- |
| `simTime` | Amesim final time [s] | 1 s per data row (rows - 1) |
| `nIncrements` | Amesim number of print increments | one per data row (rows - 1) |
| `signals` | write the signal files | `true` |

The tool prints the matching Amesim final time and print interval, and warns if
`nIncrements` is not a multiple of (rows - 1), because then some rows fall
between print times.

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

The `examples/` folder has each input sheet next to the table and the input-signal files made from it (default timing, 1 s per row):

| Input | Command | Output |
| --- | --- | --- |
| `Example.xlsx` (5 inputs, 4725 rows) | `make_amesim_table('excelFile','examples/Example.xlsx','tableUnit','kg/s')` | `FADEC_FLOW_Demand_5D.txt` |
| `RPM_DP_FlowRate_MATLAB_Example.xlsx` | `make_amesim_multi1d_table('excelFile','examples/RPM_DP_FlowRate_MATLAB_Example.xlsx','tableUnit','L/min','axisUnits',{'rev/min','bar'})` | `RPM_DP_FlowRate_M1D.txt` |
| `FlightCondition_RPM_DP_FlowRate_MATLAB_Example.xlsx` | `make_amesim_multi1d_table('excelFile','examples/FlightCondition_RPM_DP_FlowRate_MATLAB_Example.xlsx','tableUnit','L/min','axisUnits',{'','rev/min','bar'})` | `FlightCondition_RPM_DP_FlowRate_MM1D.txt` |

In the M1D/MM1D examples each curve is flow against dP (X) at one RPM (Y),
with one set of curves per flight condition (Z) in the MM1D table.
