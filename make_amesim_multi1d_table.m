function make_amesim_multi1d_table(varargin)
%MAKE_AMESIM_MULTI1D_TABLE  Excel column data  ->  Amesim M1D or MM1D table file.
%
%   HOW TO USE
%     1. Edit the USER SETTINGS block below.
%     2. Press Run (F5), or type  make_amesim_multi1d_table  in the Command Window.
%
%   Any setting can also be given on the command line, which overrides the
%   block below, e.g.
%     make_amesim_multi1d_table('excelFile', 'data.xlsx', 'columns', [5 3 2 6])
%
%   TABLE TYPES
%     M1D  "Multi 1D"       z(x, y)    3 columns: X  Y  Value
%          A set of 1D curves z(x), one per y value. Each curve can have its
%          own x points (non-regular mesh in x).
%     MM1D "Multi Multi 1D" u(x, y, z) 4 columns: X  Y  Z  Value
%          A set of M1D tables, one per z value. Each z can have its own
%          y values, and each (y, z) curve its own x points.
%
%   INPUT DATA  (one row per point, rows in any order, header row on top)
%     Each row is one point of a curve. Rows with the same Y (and Z) form
%     one curve. The same (X, Y[, Z]) must not appear twice.
%
%   OUTPUT FILE  (layout from the Amesim table-format documentation)
%     M1D:                          MM1D:
%       # Table format: T1D           # Table format: T3D
%       # table_unit = ...            # table_unit = ...
%       # axis1_unit = ... (X)        # axis1_unit = ... (X)
%       # axis2_unit = ... (Y)        # axis2_unit = ... (Y)
%       y1  N1                        # axis3_unit = ... (Z)
%         x z                         z1  M1          <- M1 curves at z1
%         ...  (N1 couples)             y1  N1        <- N1 points at (y1, z1)
%       y2  N2                            x u
%         x z                             ...
%         ...                           y2  N2
%                                         ...
%                                     z2  M2
%                                       ...
%
%   After writing, the file is read back and every data row is checked
%   against it.

    %% ======================= USER SETTINGS =======================
    cfg.excelFile  = '';        % Excel/CSV file; '' = pick it in a dialog
    cfg.sheet      = 1;         % sheet name or number
    cfg.outFile    = '';        % '' = <excel name>_M1D.txt / _MM1D.txt next to the Excel file
    cfg.format     = 'auto';    % 'M1D', 'MM1D', or 'auto' (3 columns -> M1D, 4 -> MM1D)
    cfg.columns    = [];        % sheet columns in the order [X Y Value] (M1D)
                                %   or [X Y Z Value] (MM1D); [] = first 3 or 4 columns
                                %   e.g. [5 3 2 6] -> X=col 5, Y=col 3, Z=col 2, value=col 6
    cfg.tableUnit  = '';        % unit of the table value, e.g. 'kg/s' ('' = none)
    cfg.axisUnits  = {};        % units of {X, Y} or {X, Y, Z}; '' to skip one
    cfg.duplicates = 'error';   % same point twice: 'error' | 'mean' | 'first' | 'last'
    cfg.tolerance  = 1e-9;      % merge values that differ only by round-off
    cfg.precision  = 15;        % significant digits written to the file
    %% =============================================================

    cfg = apply_overrides(cfg, varargin);

    % 1) Read the sheet ------------------------------------------------------
    if isempty(cfg.excelFile)
        [f, p] = uigetfile({'*.xlsx;*.xls;*.xlsm;*.csv', 'Data files'}, ...
                           'Select the data file');
        if isequal(f, 0)
            disp('Cancelled.');
            return
        end
        cfg.excelFile = fullfile(p, f);
    end
    [data, headers] = read_sheet(cfg.excelFile, cfg.sheet);
    [D, names, cfg] = select_columns(data, headers, cfg);
    % D has one row per point: [X Y Value] or [X Y Z Value]

    % 2) Sort into curves ----------------------------------------------------
    % Reorder to [Z Y X Value] / [Y X Value]: outer slice first, x last.
    nAxes = size(D, 2) - 1;
    order = [nAxes:-1:1, nAxes + 1];
    [rows, info] = build_curves(D(:, order), cfg);

    % 3) Write the Amesim file -----------------------------------------------
    if isempty(cfg.outFile)
        [p, name] = fileparts(cfg.excelFile);
        cfg.outFile = fullfile(p, sprintf('%s_%s.txt', name, cfg.format));
    end
    [~, srcName, srcExt] = fileparts(cfg.excelFile);
    comments = {['Created from ' srcName srcExt], ['Value: ' names{end}]};
    write_table(cfg.outFile, rows, cfg, names, comments);

    % 4) Verify: read the file back and check every data row -----------------
    verify_file(cfg.outFile, rows, D(:, order), cfg);

    % 5) Summary --------------------------------------------------------------
    print_summary(cfg, rows, names, size(D, 1), info);
end


%% =========================================================================
%  1) READING
%  =========================================================================

function [data, headers] = read_sheet(file, sheet)
% Numeric matrix of the sheet plus the header names of its columns.
    if ~exist(file, 'file')
        error('File not found: %s', file);
    end
    [~, ~, ext] = fileparts(file);
    isExcel = any(strcmpi(ext, {'.xls', '.xlsx', '.xlsm', '.ods'}));
    headers = {};

    if exist('readtable', 'file') || exist('readtable', 'builtin')   % MATLAB
        args = {};
        if isExcel
            args = {'Sheet', sheet};
        end
        try
            T = readtable(file, args{:}, 'VariableNamingRule', 'preserve');
        catch
            T = readtable(file, args{:});      % MATLAB older than R2020b
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
    elseif ~isExcel                                                  % Octave, CSV
        raw = strtrim(strsplit(fileread(file), '\n'));
        raw = raw(~cellfun(@isempty, raw));
        delims = {',', ';', char(9)};
        first = strtrim(strsplit(raw{1}, delims));
        if all(isnan(str2double(first)))
            headers = first;
            raw = raw(2:end);
        end
        data = cell2mat(cellfun(@(r) str2double(strsplit(r, delims)), ...
                                raw(:), 'UniformOutput', false));
    else                                                             % Octave, Excel
        data = xlsread(file, sheet);
    end

    if numel(headers) ~= size(data, 2)
        headers = arrayfun(@(k) sprintf('column %d', k), 1:size(data, 2), ...
                           'UniformOutput', false);
    end
end

function [D, names, cfg] = select_columns(data, headers, cfg)
% Pick the [X Y (Z) Value] columns and decide between M1D and MM1D.
    nCols = size(data, 2);
    cols = cfg.columns;
    fmt = upper(cfg.format);
    if strcmp(fmt, 'AUTO')
        if ~isempty(cols)
            nNeeded = numel(cols);
        else
            nNeeded = nCols;
        end
        if nNeeded == 3
            fmt = 'M1D';
        elseif nNeeded == 4
            fmt = 'MM1D';
        else
            error(['The sheet has %d columns, so the format cannot be guessed. Set ' ...
                   'format to ''M1D'' or ''MM1D'' and columns to [X Y Value] ' ...
                   'or [X Y Z Value].'], nNeeded);
        end
    end
    switch fmt
        case 'M1D',  nNeeded = 3;
        case 'MM1D', nNeeded = 4;
        otherwise
            error('format must be ''M1D'', ''MM1D'' or ''auto'', not "%s".', cfg.format);
    end
    if isempty(cols)
        cols = 1:nNeeded;
    end
    if numel(cols) ~= nNeeded
        error('%s needs %d columns in columns, got %d.', fmt, nNeeded, numel(cols));
    end
    if any(cols < 1 | cols > nCols)
        error('The sheet has %d columns; check the columns setting.', nCols);
    end
    if ~isempty(cfg.axisUnits) && numel(cfg.axisUnits) ~= nNeeded - 1
        error('axisUnits must have %d entries for %s.', nNeeded - 1, fmt);
    end
    cfg.format = fmt;

    D = data(:, cols);
    D = D(~all(isnan(D), 2), :);                   % drop empty rows
    bad = find(any(isnan(D), 2), 1);
    if ~isempty(bad)
        error('Data row %d has an empty or non-numeric cell.', bad);
    end
    names = headers(cols);
end


%% =========================================================================
%  2) CURVES
%  =========================================================================

function [rows, info] = build_curves(D, cfg)
% D is [Y X V] or [Z Y X V]. Returns the rows sorted by slice (outer axis
% first) and by x inside each curve, with duplicates handled.
    nAxes = size(D, 2) - 1;
    for k = 1:nAxes                               % snap round-off noise
        [values, idx] = unique_with_tolerance(D(:, k), cfg.tolerance);
        D(:, k) = values(idx);
    end
    rows = sortrows(D, 1:nAxes);

    % Same point (same slice and same x) given more than once
    keys = rows(:, 1:nAxes);
    newPoint = [true; any(diff(keys, 1, 1) ~= 0, 2)];
    pointId = cumsum(newPoint);
    nDup = sum(accumarray(pointId, 1) > 1);
    if nDup > 0
        switch lower(cfg.duplicates)
            case 'mean'
                v = accumarray(pointId, rows(:, end), [], @mean);
            case 'first'
                [~, r] = unique(pointId, 'first');
                v = rows(r, end);
            case 'last'
                [~, r] = unique(pointId, 'last');
                v = rows(r, end);
            otherwise
                r = find(~newPoint, 1);
                error(['%d points appear more than once, e.g. (%s).\n' ...
                       'Set duplicates to ''mean'', ''first'' or ''last'' to accept them.'], ...
                      nDup, point_text(rows(r, 1:nAxes), cfg.format));
        end
        rows = [keys(newPoint, :) v];
    end

    % Each curve needs at least 2 points to interpolate along x
    curveKeys = rows(:, 1:nAxes-1);
    newCurve = [true; any(diff(curveKeys, 1, 1) ~= 0, 2)];
    pointsPerCurve = accumarray(cumsum(newCurve), 1);
    short = find(pointsPerCurve < 2, 1);
    if ~isempty(short)
        starts = find(newCurve);
        warning('%d curve(s) have a single x point, e.g. the curve at (%s).', ...
                sum(pointsPerCurve < 2), ...
                point_text([curveKeys(starts(short), :) NaN], cfg.format));
    end
    info = struct('duplicates', nDup, 'curves', numel(pointsPerCurve), ...
                  'minPoints', min(pointsPerCurve), 'maxPoints', max(pointsPerCurve));
end

function [values, index] = unique_with_tolerance(x, tol)
% Sorted unique values of x; values closer than tol (relative) are merged.
% Each group is represented by its most frequent value (a value that is
% really in the data).
    [xs, order] = sort(x);
    scale = max(max(abs(xs)), 1);
    groupId = cumsum([true; diff(xs) > tol * scale]);
    values = accumarray(groupId, xs, [], @mode);
    index = zeros(size(x));
    index(order) = groupId;
end

function s = point_text(key, format)
% key is [Y X] or [Z Y X] (NaN = not shown).
    if strcmp(format, 'M1D')
        labels = {'Y', 'X'};
    else
        labels = {'Z', 'Y', 'X'};
    end
    parts = {};
    for k = 1:numel(key)
        if ~isnan(key(k))
            parts{end+1} = sprintf('%s=%g', labels{k}, key(k)); %#ok<AGROW>
        end
    end
    s = strjoin(parts, ', ');
end


%% =========================================================================
%  3) WRITING
%  =========================================================================

function write_table(file, rows, cfg, names, comments)
% Write the M1D (T1D) or MM1D (T3D) layout, see the header of this file.
    numFmt = sprintf('%%.%dg', cfg.precision);
    if strcmp(cfg.format, 'M1D')
        header = 'T1D';
    else
        header = 'T3D';
    end
    axisLetters = {'X', 'Y', 'Z'};

    fid = fopen(file, 'w');
    if fid < 0
        error('Cannot open "%s" for writing.', file);
    end
    closer = onCleanup(@() fclose(fid));

    fprintf(fid, '# Table format: %s\n', header);
    fprintf(fid, '# %s\n', comments{:});
    for k = 1:numel(names) - 1
        fprintf(fid, '# %s: %s\n', axisLetters{k}, names{k});
    end
    if ~isempty(cfg.tableUnit)
        fprintf(fid, '# table_unit = %s\n', cfg.tableUnit);
    end
    for k = 1:numel(cfg.axisUnits)
        if ~isempty(cfg.axisUnits{k})
            fprintf(fid, '# axis%d_unit = %s\n', k, cfg.axisUnits{k});
        end
    end
    write_level(fid, rows, 1, numFmt);
end

function write_level(fid, rows, level, numFmt)
% rows = [outer ... y x value] from column LEVEL on. Writes "key count"
% for each slice, then recurses; at the x level writes the x/value couples.
    nLevels = size(rows, 2) - 1;
    indent = repmat(' ', 1, 2 * (level - 1));
    if level == nLevels
        fprintf(fid, [indent numFmt ' ' numFmt '\n'], rows(:, end-1:end)');
        return
    end
    [keys, ~, id] = unique(rows(:, level));
    for k = 1:numel(keys)
        sub = rows(id == k, :);
        if level + 1 == nLevels
            count = size(sub, 1);                  % number of x points
        else
            count = numel(unique(sub(:, level + 1)));   % number of y curves
        end
        fprintf(fid, [indent numFmt ' %d\n'], keys(k), count);
        write_level(fid, sub, level + 1, numFmt);
    end
end


%% =========================================================================
%  4) VERIFICATION
%  =========================================================================

function verify_file(file, rows, original, cfg)
% Read the file back; it must give the same rows, and (without merged
% duplicates) every original data row must be among them.
    back = read_table(file);
    relTol = 10^(1 - cfg.precision);
    same = @(a, b) size(a, 1) == size(b, 1) && ...
                    all(all(abs(a - b) <= relTol * max(1, abs(b))));
    if ~same(back, rows)
        error('Check failed: the data read back from "%s" does not match.', file);
    end
    if strcmpi(cfg.duplicates, 'error')
        nAxes = size(original, 2) - 1;
        if ~same(sortrows(original, 1:nAxes), rows)
            error('Check failed: the data rows do not match "%s".', file);
        end
    end
end

function rows = read_table(file)
% Read a T1D / T3D file into rows [Y X V] or [Z Y X V].
    lines = regexp(fileread(file), '\r?\n', 'split');
    fmt = regexp(lines{1}, 'Table format:\s*(T1D|T3D)', 'tokens', 'once');
    if isempty(fmt)
        error('"%s" has no "# Table format: T1D/T3D" header.', file);
    end
    body = lines(~strncmp(strtrim(lines), '#', 1));
    values = sscanf(strjoin(body, ' '), '%f');
    if strcmp(fmt{1}, 'T1D')
        nLevels = 2;
    else
        nLevels = 3;
    end
    rows = zeros(0, nLevels + 1);
    pos = 0;
    while pos < numel(values)
        [block, pos] = read_level(values, pos, 1, nLevels);
        rows = [rows; block]; %#ok<AGROW>
    end
end

function [rows, pos] = read_level(values, pos, level, nLevels)
% Read one "key count" slice starting after position POS.
    if pos + 2 > numel(values)
        error('The table file ends in the middle of a slice.');
    end
    key = values(pos + 1);
    count = values(pos + 2);
    pos = pos + 2;
    if level + 1 == nLevels
        if pos + 2 * count > numel(values)
            error('The table file ends in the middle of a curve.');
        end
        xy = reshape(values(pos + (1:2*count)), 2, [])';
        pos = pos + 2 * count;
        rows = [repmat(key, count, 1) xy];
    else
        rows = zeros(0, nLevels - level + 1);
        for k = 1:count
            [sub, pos] = read_level(values, pos, level + 1, nLevels);
            rows = [rows; sub]; %#ok<AGROW>
        end
        rows = [repmat(key, size(rows, 1), 1) rows];
    end
end


%% =========================================================================
%  5) HELPERS
%  =========================================================================

function print_summary(cfg, rows, names, nRows, info)
    fprintf('\nWrote %s Amesim table: %s\n', cfg.format, cfg.outFile);
    fprintf('  X: %s\n', names{1});
    fprintf('  Y: %s   (%d values)\n', names{2}, numel(unique(rows(:, end-2))));
    if strcmp(cfg.format, 'MM1D')
        fprintf('  Z: %s   (%d values)\n', names{3}, numel(unique(rows(:, 1))));
    end
    fprintf('  Value: %s', names{end});
    if ~isempty(cfg.tableUnit)
        fprintf(' [%s]', cfg.tableUnit);
    end
    fprintf('\n  %d curves, %d to %d points each, from %d data rows', ...
            info.curves, info.minPoints, info.maxPoints, nRows);
    if info.duplicates > 0
        fprintf(', %d duplicate points (%s)', info.duplicates, cfg.duplicates);
    end
    fprintf('\n  Check passed: file read back and matches the data.\n\n');
end

function cfg = apply_overrides(cfg, args)
% Name-value pairs from the command line replace the settings block.
    if mod(numel(args), 2) ~= 0
        error('Settings must be given as name-value pairs.');
    end
    names = fieldnames(cfg);
    for k = 1:2:numel(args)
        match = strcmpi(names, char(args{k}));
        if ~any(match)
            error('Unknown setting "%s". Valid: %s', char(args{k}), strjoin(names', ', '));
        end
        cfg.(names{match}) = args{k+1};
    end
    if ischar(cfg.axisUnits)
        cfg.axisUnits = {cfg.axisUnits};
    end
end
