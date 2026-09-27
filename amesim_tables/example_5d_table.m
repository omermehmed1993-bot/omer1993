%EXAMPLE_5D_TABLE Build a 5D Amesim table from 6-column Excel-style data.
%
% This script makes a synthetic data sheet (5 input columns + 1 output
% column, rows shuffled like real test data), converts it to an Amesim
% 5D table file and checks a few values. Replace the first section with
% your own file:
%
%   amesim_excel_to_table('my_data.xlsx', 'my_table_5d.txt', ...
%       'TableUnit', 'Nm', 'AxisUnits', {'rev/min', 'bar', 'degC', 'mm', 's'});

clear; clc;

%% 1) Make example data: one row per point, 6 columns
x1 = [0 1000 2000 3000 4000 5000 6000];   % e.g. speed      (7 points)
x2 = 0:10:90;                             % e.g. load       (10 points)
x3 = [20 60 100];                         % e.g. temperature
x4 = [1 5];                               % e.g. pressure
x5 = [0 1];                               % e.g. mode

[G1, G2, G3, G4, G5] = ndgrid(x1, x2, x3, x4, x5);
value = @(a, b, c, d, e) 1e-3*a + 2*b + 0.1*c + 10*d + 100*e;  % known function
Y = value(G1, G2, G3, G4, G5);

rows = [G1(:) G2(:) G3(:) G4(:) G5(:) Y(:)];
rows = rows(randperm(size(rows, 1)), :);          % any row order is fine
headers = {'Speed', 'Load', 'Temp', 'Pressure', 'Mode', 'Torque'};

if exist('writetable', 'file') || exist('writetable', 'builtin')
    dataFile = 'example_5d_data.xlsx';
    writetable(array2table(rows, 'VariableNames', headers), dataFile);
else
    % Octave: write a CSV instead (amesim_excel_to_table reads both)
    dataFile = 'example_5d_data.csv';
    fid = fopen(dataFile, 'w');
    fprintf(fid, '%s\n', strjoin(headers, ','));
    fprintf(fid, '%.15g,%.15g,%.15g,%.15g,%.15g,%.15g\n', rows');
    fclose(fid);
end

%% 2) Convert to an Amesim 5D table file
outFile = 'example_table_5d.txt';
[ax, U] = amesim_excel_to_table(dataFile, outFile, ...
    'TableUnit', 'Nm', 'AxisUnits', {'rev/min', 'null', 'degC', 'bar', 'null'});

%% 3) Checks
assert(isequal(size(U), [7 10 3 2 2]));
assert(isequal(ax{1}, x1) && isequal(ax{5}, x5));
assert(abs(U(3, 4, 2, 1, 2) - value(x1(3), x2(4), x3(2), x4(1), x5(2))) < 1e-9);
[axBack, UBack] = amesim_read_table(outFile);
assert(max(abs(UBack(:) - Y(:))) < 1e-9);
disp('All checks passed.');

type(outFile);   % show the start of the file
