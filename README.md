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

The input columns become axes X1, X2, … in column order (reorder them with
`inputColumns`). The data must contain every combination of the input values
(a full grid), unless `fillMissing` is set. After writing, the file is read
back and every data row is checked against it.

`examples/FADEC_FLOW_Demand_5D.txt` is the 5D table made from `Example.xlsx`
(4725 rows: FlightStage × Altitude × Mach × ISA dT × N_HP → corrected mass flow).

## M1D and MM1D tables

`make_amesim_multi1d_table.m` works the same way (settings block on top,
press **Run**) and writes the "Multi 1D" formats, where each curve can have
its own x points:

| Format | Header | Columns (`columns` setting) | Meaning |
| --- | --- | --- | --- |
| M1D  | `# Table format: T1D` | `[X Y Value]`   | one curve z(x) per y value |
| MM1D | `# Table format: T3D` | `[X Y Z Value]` | one M1D table per z value; each z can have its own y values |

```matlab
make_amesim_multi1d_table('excelFile', 'data.xlsx', 'columns', [5 3 2 6], 'tableUnit', 'kg/s')
```

Each (X, Y[, Z]) point must appear only once (see `duplicates`).
