# Amesim ND table writer (MATLAB)

MATLAB functions that turn column data from Excel (one row per point, e.g.
5 input columns + 1 output column) into a Simcenter Amesim regular-mesh table
file (`# Table format: 1D` … `8D`) that Amesim table submodels can read.

## Quick start

```matlab
addpath('amesim_tables')

% data.xlsx: columns X1 X2 X3 X4 X5 Output, one row per point, any order
amesim_excel_to_table('data.xlsx', 'my_table_5d.txt', ...
    'TableUnit', 'Nm', ...
    'AxisUnits', {'rev/min', 'bar', 'degC', 'mm', 's'});
```

The input columns become the table axes **in column order** (column 1 = X1,
column 2 = X2, …), and the last column is the table value. Use
`'InputColumns'` and `'OutputColumn'` to pick other columns or change the axis
order. The axis order must match the order of the inputs on the Amesim
submodel.

Run `example_5d_table.m` to see a full example with a self-check.

## Files

| File | Purpose |
| --- | --- |
| `amesim_excel_to_table.m` | Excel/CSV → grid → Amesim file, then reads the file back to check it |
| `amesim_grid_from_columns.m` | Column data (M rows × N inputs + 1 output) → breakpoints + N-D array |
| `amesim_write_table.m` | Writes breakpoints + N-D array in Amesim format (1D … 8D) |
| `amesim_read_table.m` | Reads Amesim 1D/2D/ND files (for checking) |
| `example_5d_table.m` | Worked 5D example |

If your data is already on a grid in MATLAB, call the writer directly:

```matlab
amesim_write_table('t.txt', {x1, x2, x3, x4, x5}, U)   % size(U) = [n1 n2 n3 n4 n5]
```

## File layout written

This is the same layout as the 2D/3D examples in the Amesim documentation,
extended to N axes:

```
# Table format: 5D
# table_unit = Nm
# axis1_unit = rev/min
...
n1                      <- number of breakpoints of axis 1
n2
n3
n4
n5
x1(1) ... x1(n1)        <- breakpoints of axis 1
...
x5(1) ... x5(n5)        <- breakpoints of axis 5

u(1,1,1,1,1) u(2,1,1,1,1) ... u(n1,1,1,1,1)     <- a line runs along axis 1
u(1,2,1,1,1) ...                                  axis 2 goes down the lines
...                                               then axis 3, 4, 5 (blocks)
```

Axis 1 varies fastest, then axis 2, and so on. This is MATLAB's column-major
order, so `U(:)` is already in file order. The blank lines between 2D slices
are only for readability; Amesim treats all whitespace alike. Each 2D slice
matches what the Amesim Table Editor shows: X1 across, X2 down, one block per
(X3, X4, X5) combination.

## Data requirements and options

- **Full grid.** Every combination of the unique input values must be in the
  data, so a 7 × 10 × 3 × 2 × 2 table needs 840 rows. By default missing
  points stop the conversion with an error. Set `'FillMissing'` to
  `'nearest'` or `'linear'` to fill them, and check the result.
- **Duplicates.** A point that appears twice is an error by default. Set
  `'Duplicates'` to `'mean'`, `'first'` or `'last'` to accept it.
- **Round-off.** Values that differ only by round-off (for example `0.1` and
  `0.1000000001`) are merged into one breakpoint (`'Tolerance'`, default
  1e-9 relative).
- **Breakpoints.** Every axis needs at least 2 strictly increasing
  breakpoints. A constant input column cannot be an axis, so drop it with
  `'InputColumns'`.
- **Units.** Units are optional. If you give them, use unit strings that
  Amesim knows (for example `null` for dimensionless), because Amesim uses
  them for unit conversion. Leave a unit as `''` to skip it.
