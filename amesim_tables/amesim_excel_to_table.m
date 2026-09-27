function [axesValues, U] = amesim_excel_to_table(excelFile, outFile, varargin)
%AMESIM_EXCEL_TO_TABLE Convert column data from Excel/CSV into an Amesim ND table file.
%
%   amesim_excel_to_table(EXCELFILE, OUTFILE) reads a sheet where every row
%   is one data point, e.g. with 6 columns:
%
%       X1    X2    X3    X4    X5    Output
%       ...   ...   ...   ...   ...   ...
%
%   The first columns are the table inputs (axis 1, axis 2, ... in that
%   order) and the last column is the table value. The rows may be in any
%   order, but together they must cover every combination of the input
%   values (full-factorial grid). The result is written to OUTFILE in the
%   Amesim "# Table format: ND" layout (use a .txt or .data extension) and
%   read back to check it.
%
%   Name-value options:
%     'Sheet'         - sheet name or number                  (default 1)
%     'InputColumns'  - column numbers of the inputs, in axis order
%                       (default: all columns except the output)
%     'OutputColumn'  - column number of the table value      (default: last)
%     'TableUnit'     - unit of the table value, e.g. 'Nm'    (default '')
%     'AxisUnits'     - cellstr with one unit per input axis  (default {})
%     'Tolerance'     - see amesim_grid_from_columns          (default 1e-9)
%     'Duplicates'    - see amesim_grid_from_columns          (default 'error')
%     'FillMissing'   - see amesim_grid_from_columns          (default 'error')
%     'Precision'     - significant digits in the file        (default 15)
%
%   Example (5 inputs + 1 output -> 5D table):
%     amesim_excel_to_table('data.xlsx', 'my_table_5d.txt', ...
%         'TableUnit', 'Nm', 'AxisUnits', {'rev/min','bar','degC','','s'});

    opts = parse_options(varargin, struct( ...
        'Sheet', 1, 'InputColumns', [], 'OutputColumn', [], ...
        'TableUnit', '', 'AxisUnits', {{}}, 'Tolerance', 1e-9, ...
        'Duplicates', 'error', 'FillMissing', 'error', 'Precision', 15));

    [data, headers] = read_sheet(excelFile, opts.Sheet);
    nCols = size(data, 2);

    outCol = opts.OutputColumn;
    if isempty(outCol)
        outCol = nCols;
    end
    inCols = opts.InputColumns;
    if isempty(inCols)
        inCols = setdiff(1:nCols, outCol, 'stable');
    end
    if any([inCols(:); outCol] > nCols) || any([inCols(:); outCol] < 1)
        error('amesim_excel_to_table:columns', ...
              'The sheet has %d columns; check InputColumns/OutputColumn.', nCols);
    end

    % Drop fully empty rows (e.g. blank lines at the end of the sheet).
    used = data(:, [inCols(:)' outCol]);
    empty = all(isnan(used), 2);
    used = used(~empty, :);
    bad = find(any(isnan(used), 2), 1);
    if ~isempty(bad)
        error('amesim_excel_to_table:nan', ...
              'Data row %d has an empty or non-numeric cell.', bad);
    end

    X = used(:, 1:end-1);
    y = used(:, end);

    [axesValues, U, info] = amesim_grid_from_columns(X, y, ...
        'Tolerance', opts.Tolerance, 'Duplicates', opts.Duplicates, ...
        'FillMissing', opts.FillMissing);

    axisNames = headers(inCols);
    comments = {sprintf('Created from %s', file_name(excelFile)), ...
                sprintf('Value: %s', headers{outCol})};
    amesim_write_table(outFile, axesValues, U, ...
        'TableUnit', opts.TableUnit, 'AxisUnits', opts.AxisUnits, ...
        'AxisNames', axisNames, 'Comments', comments, ...
        'Precision', opts.Precision);

    % Read the file back and make sure it matches what was intended.
    [axesBack, UBack] = amesim_read_table(outFile);
    ok = numel(axesBack) == numel(axesValues) && isequal(size(UBack), size(U));
    for k = 1:numel(axesValues)
        ok = ok && max(abs(axesBack{k} - axesValues{k})) <= 1e-12 * max(1, max(abs(axesValues{k})));
    end
    ok = ok && max(abs(UBack(:) - U(:))) <= 10^(1 - opts.Precision) * max(1, max(abs(U(:))));
    if ~ok
        error('amesim_excel_to_table:verify', ...
              'Read-back check of "%s" failed.', outFile);
    end

    fprintf('Wrote %dD Amesim table "%s"\n', numel(axesValues), outFile);
    for k = 1:numel(axesValues)
        fprintf('  X%d  %-20s %3d points  [%g ... %g]\n', k, axisNames{k}, ...
                numel(axesValues{k}), axesValues{k}(1), axesValues{k}(end));
    end
    fprintf('  %d values from %d data rows', numel(U), size(X, 1));
    if info.duplicatePoints > 0
        fprintf(', %d duplicate points merged', info.duplicatePoints);
    end
    if info.missingPoints > 0
        fprintf(', %d missing points filled (%s)', info.missingPoints, opts.FillMissing);
    end
    fprintf('\n');
end

function [data, headers] = read_sheet(file, sheet)
    [~, ~, ext] = fileparts(file);
    headers = {};
    if exist('readtable', 'file') || exist('readtable', 'builtin')
        args = {};
        if any(strcmpi(ext, {'.xls', '.xlsx', '.xlsm', '.ods'}))
            args = {'Sheet', sheet};
        end
        try
            T = readtable(file, args{:}, 'VariableNamingRule', 'preserve');
        catch
            T = readtable(file, args{:});   % MATLAB older than R2020b
        end
        headers = T.Properties.VariableNames;
        data = nan(height(T), width(T));
        for k = 1:width(T)
            col = T{:, k};
            if isnumeric(col) || islogical(col)
                data(:, k) = double(col);
            else
                data(:, k) = str2double(string(col));
            end
        end
    elseif any(strcmpi(ext, {'.csv', '.txt'}))
        % Octave fallback: numeric CSV with an optional header row.
        raw = strtrim(strsplit(fileread(file), '\n'));
        raw = raw(~cellfun(@isempty, raw));
        first = strsplit(raw{1}, {',', ';', char(9)});
        if all(isnan(str2double(first)))
            headers = strtrim(first);
            raw = raw(2:end);
        end
        data = cell2mat(cellfun(@(r) str2double(strsplit(r, {',', ';', char(9)})), ...
                                raw(:), 'UniformOutput', false));
    else
        data = xlsread(file, sheet);   % Octave with the io package
    end
    if numel(headers) ~= size(data, 2)
        headers = arrayfun(@(k) sprintf('column %d', k), 1:size(data, 2), ...
                           'UniformOutput', false);
    end
end

function s = file_name(path)
    [~, name, ext] = fileparts(path);
    s = [name ext];
end

function opts = parse_options(args, opts)
    if mod(numel(args), 2) ~= 0
        error('amesim_excel_to_table:args', 'Options must be name-value pairs.');
    end
    names = fieldnames(opts);
    for k = 1:2:numel(args)
        match = strcmpi(names, char(args{k}));
        if ~any(match)
            error('amesim_excel_to_table:args', 'Unknown option "%s".', char(args{k}));
        end
        opts.(names{match}) = args{k+1};
    end
end
