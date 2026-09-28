function make_amesim_multi1d_table(varargin)
%MAKE_AMESIM_MULTI1D_TABLE  Excel column data  ->  Amesim M1D or MM1D table file.
%
%   HOW TO USE
%     1. Edit the USER SETTINGS block below.
%     2. Press Run (F5), or type  make_amesim_multi1d_table  in the Command Window.
%
%   Any setting can also be given on the command line, which overrides the
%   block below, e.g.
%     make_amesim_multi1d_table('excelFile', 'data.xlsx', 'columns', [1 2 3 4])
%
%   COLUMN ORDER = BREAKPOINT ORDER IN THE FILE
%     The sheet columns are taken in the order their breakpoints appear in
%     the Amesim file: 1st breakpoint, 2nd breakpoint, ..., then the value.
%
%     M1D  "Multi 1D"       3 columns:  1st = Y (one curve per value)
%                                       2nd = X (curve abscissa)
%                                       then the table value
%     MM1D "Multi Multi 1D" 4 columns:  1st = Z (one M1D block per value)
%                                       2nd = Y (one curve per value)
%                                       3rd = X (curve abscissa)
%                                       then the table value
%
%     e.g. FlightCondition | RPM | dP_bar | Flow  ->  MM1D with
%          FlightCondition blocks, RPM curves inside them, Flow vs dP_bar.
%
%     Each curve can have its own x points, and in MM1D each Z can have its
%     own Y values (non-regular mesh).
%
%   INPUT DATA  (one row per point, rows in any order, header row on top)
%     Rows with the same 1st (and 2nd) breakpoint form one curve. The same
%     combination of breakpoints must not appear twice.
%
%   OUTPUT FILE  (layout from the Amesim table-format documentation)
%     M1D:                          MM1D:
%       # Table format: T1D           # Table format: T3D
%       y1  N1   <- 1st breakpoint,   z1  M1          <- 1st breakpoint, M1 curves
%         x v       N1 points           y1  N1        <- 2nd breakpoint, N1 points
%         ...    <- 2nd breakpoint        x v         <- 3rd breakpoint, value
%       y2  N2      and value             ...
%         ...                           y2  N2
%                                         ...
%                                     z2  M2
%                                       ...
%     (Amesim numbers the unit lines the other way round: axis1_unit is X,
%      axis2_unit is Y, axis3_unit is Z. The code takes care of that.)
%
%   INPUT SIGNALS  (cfg.signals = true)
%     For every input a 1D table <table>_input<k>_<name>.txt is written with
%     x = time [s] and y = that input, plus <table>_expected_<value>.txt
%     (x = time, y = data output), all on the same time vector:
%     - sheet has a time column: every row is applied at its own time from
%       that column, nothing is asked (signalTime = 'auto' or 'sheet');
%     - no time column: the code ASKS for the Amesim total simulation time
%       and number of intervals and samples the print grid t = 0 : T/N : T,
%       each row held for an equal number of print points ('grid').
%     At every row time all inputs equal one data row, so the table output
%     equals that row's value.
%     rowOrder = 'snake' plays the rows so that consecutive rows differ in
%     one input by one breakpoint (smaller jumps than sheet order).
%
%   TIME COLUMN
%     A time column in the sheet (header time, Time_s, Time [s], t ...) is
%     found automatically (timeColumn = 'auto'), never used as a table input
%     or value, and gives the time of the input signals. For real mission
%     profiles use make_amesim_mission_signals.m.
%
%   OFF-GRID TEST  (optional, offGridPoints = 0 switches it off completely)
%     offGridPoints > 0 also writes <table>_offgrid_input<k>_<name>.txt and
%     <table>_offgrid_expected_<value>.txt: random points between the
%     breakpoints with the linearly interpolated table output, on the same
%     time grid, to check Amesim's interpolation. The main files are not
%     changed by it.
%
%   After writing, the file is read back and every data row is checked
%   against it.

    %% ======================= USER SETTINGS =======================
    cfg.excelFile  = '';        % Excel/CSV file; '' = pick it in a dialog
    cfg.sheet      = 1;         % sheet name or number
    cfg.outFile    = '';        % '' = <excel name>_M1D.txt / _MM1D.txt next to the Excel file
    cfg.format     = 'auto';    % 'M1D', 'MM1D', or 'auto' (3 columns -> M1D, 4 -> MM1D)
    cfg.timeColumn = 'auto';    % time column, never a table input: 'auto' = find it
                                %   by its header (time, Time_s, t ...), 0 = none, or a number
    cfg.columns    = [];        % sheet columns as [1st 2nd value] (M1D) or
                                %   [1st 2nd 3rd value] (MM1D) breakpoint;
                                %   [] = the first 3 or 4 columns in sheet order (time skipped)
                                %   e.g. [1 2 3 4] -> col 1 = blocks, col 2 = curves,
                                %                     col 3 = curve x, col 4 = value
    cfg.tableUnit  = '';        % unit of the table value, e.g. 'kg/s' ('' = none)
    cfg.axisUnits  = {};        % one unit per breakpoint, same order as columns; '' to skip
    cfg.duplicates = 'error';   % same point twice: 'error' | 'mean' | 'first' | 'last'
    cfg.tolerance  = 1e-9;      % merge values that differ only by round-off
    cfg.precision  = 15;        % significant digits written to the file
    %% ---- input signals: 1D tables (x = time) that drive the table inputs ----
    cfg.signals    = true;      % also write one time table per input + expected output
    cfg.signalTime = 'auto';    % time of the signals: 'auto' = the sheet's time column
                                %   if there is one, else 'grid'; or 'sheet' | 'grid'
    cfg.simTime    = [];        % 'grid' only: total simulation time [s]; [] = ask
    cfg.nIntervals = [];        % 'grid' only: number of intervals;        [] = ask
    cfg.rowOrder   = 'sheet';   % order the rows are played: 'sheet' | 'snake'
                                %   (snake: one input changes by one breakpoint at a time)
    %% ---- optional off-grid test (offGridPoints = 0 switches it off) ----
    cfg.offGridPoints = 0;      % random test points between breakpoints; 0 = off
    cfg.offGridAxes = [];       % breakpoints moved off-grid ([] = all), e.g. [2 3]
                                %   keeps breakpoint 1 on its values
    cfg.offGridSeed = 1;        % random seed, so the test points are repeatable
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
    [D, names, cfg, tSheet] = select_columns(data, headers, cfg);
    % D has one row per point, breakpoints in file order:
    % [Y X Value] (M1D) or [Z Y X Value] (MM1D)

    % 2) Sort into curves ----------------------------------------------------
    [rows, info] = build_curves(D, cfg);

    % 3) Write the Amesim file -----------------------------------------------
    if isempty(cfg.outFile)
        [p, name] = fileparts(cfg.excelFile);
        cfg.outFile = fullfile(p, sprintf('%s_%s.txt', name, cfg.format));
    end
    [~, srcName, srcExt] = fileparts(cfg.excelFile);
    comments = {['Created from ' srcName srcExt], ['Value: ' names{end}]};
    write_table(cfg.outFile, rows, cfg, names, comments);

    % 4) Verify: read the file back and check every data row -----------------
    verify_file(cfg.outFile, rows, D, cfg);

    % 5) Summary --------------------------------------------------------------
    print_summary(cfg, rows, names, size(D, 1), info);

    % 6) Input signals: one 1D table (x = time) per input, same time vector
    if cfg.signals
        timing = write_signals(cfg, D(:, 1:end-1), D(:, end), names(1:end-1), names{end}, tSheet);

        % 7) Optional off-grid test points (cfg.offGridPoints = 0 skips this)
        if cfg.offGridPoints > 0 && ~isempty(timing)
            [Xo, yo] = offgrid_points(cfg, rows(:, 1:end-1), @(Q) interp_multi1d(rows, Q));
            write_offgrid_set(cfg, timing, Xo, yo, names(1:end-1), names{end});
        end
    end
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

function timeCol = find_time_column(headers, setting)
% Column number of the time column ([] if none). 'auto' looks for a header
% such as time, Time_s, Time [s], t, t_s; 0 or [] = no time column.
    if ischar(setting) && strcmpi(setting, 'auto')
        pattern = '^\s*(t|time|zeit|temps|tiempo)\s*([_\[\(\s].*)?$';
        timeCol = find(~cellfun(@isempty, regexpi(headers, pattern, 'once')));
        if numel(timeCol) > 1
            error(['Several columns look like time (%s). Set timeColumn to the ' ...
                   'right column number.'], strjoin(headers(timeCol), ', '));
        end
    elseif isempty(setting) || isequal(setting, 0)
        timeCol = [];
    elseif isnumeric(setting) && isscalar(setting) && setting >= 1 && ...
           setting <= numel(headers) && setting == round(setting)
        timeCol = setting;
    else
        error('timeColumn must be ''auto'', 0 or a column number.');
    end
    if ~isempty(timeCol)
        fprintf('Time column: column %d "%s" (not used as a table input).\n', ...
                timeCol, headers{timeCol});
    end
end

function [D, names, cfg, t] = select_columns(data, headers, cfg)
% Pick the breakpoint and value columns and decide between M1D and MM1D;
% t is the sheet's time column ([] if it has none).
    nCols = size(data, 2);
    timeCol = find_time_column(headers, cfg.timeColumn);
    available = setdiff(1:nCols, timeCol, 'stable');
    cols = cfg.columns;
    fmt = upper(cfg.format);
    if strcmp(fmt, 'AUTO')
        if ~isempty(cols)
            nNeeded = numel(cols);
        else
            nNeeded = numel(available);
        end
        if nNeeded == 3
            fmt = 'M1D';
        elseif nNeeded == 4
            fmt = 'MM1D';
        else
            error(['The sheet has %d columns, so the format cannot be guessed. Set ' ...
                   'format to ''M1D'' or ''MM1D'' and columns to the breakpoint ' ...
                   'columns in file order followed by the value column.'], nNeeded);
        end
    end
    switch fmt
        case 'M1D',  nNeeded = 3;
        case 'MM1D', nNeeded = 4;
        otherwise
            error('format must be ''M1D'', ''MM1D'' or ''auto'', not "%s".', cfg.format);
    end
    if isempty(cols)
        if numel(available) < nNeeded
            error('%s needs %d data columns, the sheet has %d.', fmt, nNeeded, numel(available));
        end
        cols = available(1:nNeeded);
    end
    if numel(cols) ~= nNeeded
        error('%s needs %d columns in columns, got %d.', fmt, nNeeded, numel(cols));
    end
    if any(cols < 1 | cols > nCols)
        error('The sheet has %d columns; check the columns setting.', nCols);
    end
    if ~isempty(timeCol) && any(cols == timeCol)
        error(['Column %d is the time column and cannot be a table input or value. ' ...
               'Check the columns setting, or set timeColumn = 0.'], timeCol);
    end
    if ~isempty(cfg.axisUnits) && numel(cfg.axisUnits) ~= nNeeded - 1
        error('axisUnits must have %d entries for %s.', nNeeded - 1, fmt);
    end
    cfg.format = fmt;

    D = data(:, [cols timeCol]);
    D = D(~all(isnan(D(:, 1:numel(cols))), 2), :); % drop empty rows
    bad = find(any(isnan(D), 2), 1);
    if ~isempty(bad)
        error('Data row %d has an empty or non-numeric cell.', bad);
    end
    t = [];
    if ~isempty(timeCol)
        t = D(:, end);
        D = D(:, 1:end-1);
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
    nAxes = numel(names) - 1;
    letters = {'Z', 'Y', 'X'};
    letters = letters(end-nAxes+1:end);           % {'Y','X'} or {'Z','Y','X'}

    fid = fopen(file, 'w');
    if fid < 0
        error('Cannot open "%s" for writing.', file);
    end
    closer = onCleanup(@() fclose(fid));

    fprintf(fid, '# Table format: %s\n', header);
    fprintf(fid, '# %s\n', comments{:});
    for k = 1:nAxes
        fprintf(fid, '# Breakpoint %d (%s): %s\n', k, letters{k}, names{k});
    end
    if ~isempty(cfg.tableUnit)
        fprintf(fid, '# table_unit = %s\n', cfg.tableUnit);
    end
    % Amesim: axis1 = X (last breakpoint), axis2 = Y, axis3 = Z
    for a = 1:numel(cfg.axisUnits)
        unit = cfg.axisUnits{nAxes - a + 1};
        if ~isempty(unit)
            fprintf(fid, '# axis%d_unit = %s\n', a, unit);
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
    nAxes = numel(names) - 1;
    letters = {'Z', 'Y', 'X'};
    letters = letters(end-nAxes+1:end);
    for k = 1:nAxes
        fprintf('  Breakpoint %d (%s): %-20s %d values\n', k, letters{k}, ...
                names{k}, numel(unique(rows(:, k))));
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

%% =========================================================================
%  6) INPUT SIGNALS
%  =========================================================================

function timing = write_signals(cfg, X, y, inputNames, valueName, tSheet)
% One 1D table per input (x = time, y = input value) plus one for the
% expected output, all on the same time vector. The time comes from
%   'sheet': the sheet's time column; every row is applied at its own time;
%   'grid' : the Amesim print grid t = 0 : simTime/nIntervals : simTime
%            (asked when run); the rows (sheet or snake order) are spread
%            over the print points, each held for an equal number of points.
% cfg.signalTime = 'auto' uses the sheet time when the sheet has a time
% column. Returns the timing used ([] if skipped), for the off-grid test.
    mode = lower(cfg.signalTime);
    if strcmp(mode, 'auto')
        if isempty(tSheet)
            mode = 'grid';
        else
            mode = 'sheet';
        end
    end
    switch mode
        case 'sheet'
            if isempty(tSheet)
                error(['signalTime = ''sheet'' needs a time column in the sheet ' ...
                       '(see timeColumn).']);
            end
            % Remove round-off noise such as 472.4000000000389 (12 significant digits)
            tSheet = arrayfun(@(v) str2double(sprintf('%.12g', v)), tSheet);
            bad = find(diff(tSheet) <= 0, 1);
            if ~isempty(bad)
                error(['The time column must increase from row to row: data row %d has ' ...
                       't = %g after t = %g. Fix the sheet, or set signalTime = ''grid''.'], ...
                      bad + 1, tSheet(bad + 1), tSheet(bad));
            end
            if strcmpi(cfg.rowOrder, 'snake')
                fprintf('  rowOrder = ''snake'' ignored: the rows follow the sheet''s time column.\n');
            end
            files = write_signal_files(cfg, '', tSheet, X, y, inputNames, valueName);
            dt = str2double(sprintf('%.12g', min(diff(tSheet))));
            timing = struct('mode', 'sheet', 't0', tSheet(1), 'dt', dt);
            print_sheet_timing(files, tSheet);
        case 'grid'
            M = size(X, 1);
            switch lower(cfg.rowOrder)
                case 'sheet'
                    order = (1:M)';
                case 'snake'
                    order = snake_order(X);
                otherwise
                    error('rowOrder must be ''sheet'' or ''snake'', not "%s".', cfg.rowOrder);
            end
            [simTime, nInt] = ask_run_parameters(cfg, M);
            if isempty(simTime)
                fprintf('Input signals skipped (no simulation time given).\n\n');
                timing = [];
                return
            end
            timing = struct('mode', 'grid', 'simTime', simTime, 'nInt', nInt);
            write_grid_set(cfg, '', X(order, :), y(order), inputNames, valueName, ...
                           timing, 'data rows');
            if strcmpi(cfg.rowOrder, 'snake')
                fprintf(['  Rows played in snake order: consecutive rows differ in one ' ...
                         'input by one breakpoint.\n\n']);
            end
        otherwise
            error('signalTime must be ''auto'', ''sheet'' or ''grid'', not "%s".', cfg.signalTime);
    end
end

function write_grid_set(cfg, tag, X, y, inputNames, valueName, timing, what)
% Spread the points X (rows) with outputs y over the Amesim print grid,
% each held for an equal number of print points (+-1), and write them.
    simTime = timing.simTime;
    nInt = timing.nInt;
    M = size(X, 1);
    nPts = nInt + 1;
    if nPts < M
        error(['%d intervals give %d print points, fewer than the %d %s, ' ...
               'so some would never be applied. Use at least %d intervals.'], ...
              nInt, nPts, M, what, M - 1);
    end
    t = (0:nInt)' * (simTime / nInt);
    row = floor((0:nInt)' * M / nPts) + 1;         % point applied at each print time
    held = accumarray(row, 1, [M 1]);               % print points per point
    files = write_signal_files(cfg, tag, t, X(row, :), y(row), inputNames, valueName);

    fprintf('  %s\n', files{:});
    fprintf('  Amesim run parameters: final time = %g s, %d intervals (print interval %g s).\n', ...
            simTime, nInt, simTime / nInt);
    if min(held) == max(held)
        fprintf('  Each of the %d %s is held for %d print point(s) (%g s).\n\n', ...
                M, what, held(1), held(1) * simTime / nInt);
    else
        fprintf(['  Each of the %d %s is held for %d or %d print points ' ...
                 '(use %d or %d intervals for an equal hold).\n\n'], ...
                M, what, min(held), max(held), M * floor(nPts / M) - 1, M * ceil(nPts / M) - 1);
    end
end

function write_offgrid_set(cfg, timing, Xo, yo, inputNames, valueName)
% Off-grid test signals on the same kind of time base as the main signals.
    if strcmp(timing.mode, 'grid')
        write_grid_set(cfg, 'offgrid_', Xo, yo, inputNames, valueName, timing, ...
                       'off-grid test points');
    else                                           % sheet time: same start and step
        t = timing.t0 + (0:size(Xo, 1) - 1)' * timing.dt;
        t = arrayfun(@(v) str2double(sprintf('%.12g', v)), t);
        files = write_signal_files(cfg, 'offgrid_', t, Xo, yo, inputNames, valueName);
        fprintf('  %s\n', files{:});
        fprintf('  One test point every %g s from t = %g s (t = %g ... %g s).\n\n', ...
                timing.dt, timing.t0, t(1), t(end));
    end
end

function files = write_signal_files(cfg, tag, t, V, y, inputNames, valueName)
% Write <table>_<tag>input<k>_<name>.txt (x = t, y = V(:,k)) and
% <table>_<tag>expected_<value>.txt (x = t, y = y), then read them back.
    if isempty(tag)
        label = {'Input signal', 'Expected output', 'Input signals'};
    else
        label = {'Off-grid test input', 'Off-grid expected output', 'Off-grid test signals'};
    end
    [p, base] = fileparts(cfg.outFile);
    numFmt = sprintf('%%.%dg', cfg.precision);
    nIn = numel(inputNames);
    files = cell(1, nIn + 1);
    for k = 1:nIn
        unit = '';
        if numel(cfg.axisUnits) >= k
            unit = cfg.axisUnits{k};
        end
        files{k} = fullfile(p, sprintf('%s_%sinput%d_%s.txt', base, tag, k, ...
                                       safe_name(inputNames{k})));
        write_signal(files{k}, t, V(:, k), numFmt, unit, ...
            sprintf('%s %d of %s.txt: %s vs time', label{1}, k, base, inputNames{k}));
    end
    files{end} = fullfile(p, sprintf('%s_%sexpected_%s.txt', base, tag, safe_name(valueName)));
    write_signal(files{end}, t, y, numFmt, cfg.tableUnit, ...
        sprintf('%s of %s.txt: %s vs time', label{2}, base, valueName));

    % Check: every file has the same time vector and the right values
    cols = [V y];
    relTol = 10^(1 - cfg.precision);
    for k = 1:numel(files)
        lines = regexp(fileread(files{k}), '\r?\n', 'split');
        lines = lines(~strncmp(strtrim(lines), '#', 1));
        tv = reshape(sscanf(strjoin(lines, ' '), '%f'), 2, [])';
        if size(tv, 1) ~= numel(t) || ...
           any(abs(tv(:, 1) - t) > relTol * max(1, abs(t))) || ...
           any(abs(tv(:, 2) - cols(:, k)) > relTol * max(1, abs(cols(:, k))))
            error('Check failed: signal file "%s" does not match the data.', files{k});
        end
    end
    fprintf('%s (1D tables, x = time [s]), %d points each, same time vector:\n', ...
            label{3}, numel(t));
end

function print_sheet_timing(files, t)
% Summary for signals that use the sheet's own time column.
    fprintf('  %s\n', files{:});
    dt = min(diff(t));
    fprintf('  Time from the sheet: every row applied at its own time, t = %g ... %g s.\n', ...
            t(1), t(end));
    k = t / dt;
    if all(abs(k - round(k)) < 1e-6)
        fprintf(['  Amesim run parameters: final time = %g s, print interval %g s ' ...
                 '(%d intervals): every row time is a print time.\n'], ...
                t(end), dt, round(t(end) / dt));
    else
        fprintf(['  Amesim run parameters: final time = %g s; use a print interval that ' ...
                 'divides the row times (smallest time step %g s).\n'], t(end), dt);
    end
    if t(1) > 0
        fprintf(['  Note: the first row is at t = %g s. Between 0 and %g s Amesim holds or ' ...
                 'extrapolates the input tables (see the table source settings).\n'], ...
                t(1), t(1));
    end
    fprintf('\n');
end

function order = snake_order(X)
% Row order that sweeps the breakpoints like a snake (boustrophedon): the
% 1st breakpoint is the slowest, the last the fastest, and each input runs
% up and down alternately, so consecutive rows differ in one input by one
% breakpoint. Works for full grids and for curves with different points.
% G is the position of each row's prefix (columns 1..k) along the snake;
% column k runs backwards whenever the prefix before it has an odd position.
    [M, N] = size(X);
    G = zeros(M, 1);
    for k = 1:N
        [~, ~, valRank] = unique(X(:, k));
        [~, ~, r] = unique([G valRank(:)], 'rows');       % rank inside (prefix, value)
        r = r(:);
        first = accumarray(G + 1, r, [], @min);
        last = accumarray(G + 1, r, [], @max);
        g = r - first(G + 1);                            % 0-based position in its group
        n = last(G + 1) - first(G + 1) + 1;              % values in its group
        back = mod(G, 2) == 1;
        g(back) = n(back) - 1 - g(back);
        [~, ~, G] = unique([G g], 'rows');
        G = G(:) - 1;
    end
    [~, order] = sort(G);                                 % stable: duplicates keep sheet order
end

function [simTime, nInt] = ask_run_parameters(cfg, M)
% Total simulation time and number of intervals: from the settings, or
% asked in a dialog (command-window prompt if no dialog is available).
    simTime = cfg.simTime;
    nInt = cfg.nIntervals;
    if isempty(simTime) || isempty(nInt)
        prompt = {'Total simulation time [s]  (Amesim final time):', ...
                  sprintf('Number of intervals  (Amesim; at least %d for %d data rows):', ...
                          M - 1, M)};
        defaults = {num2str(M - 1), num2str(M - 1)};
        try
            answer = inputdlg(prompt, 'Amesim run parameters', 1, defaults);
        catch
            fprintf('\nAmesim run parameters for the input signals (%d data rows)\n', M);
            answer = {input(['  ' prompt{1} ' '], 's'), input(['  ' prompt{2} ' '], 's')};
            if all(cellfun(@isempty, answer))
                answer = {};
            end
        end
        if isempty(answer)
            simTime = [];
            nInt = [];
            return
        end
        simTime = str2double(answer{1});
        nInt = str2double(answer{2});
    end
    if ~(isscalar(simTime) && simTime > 0)
        error('The total simulation time must be a positive number.');
    end
    if ~(isscalar(nInt) && nInt >= 1 && nInt == round(nInt))
        error('The number of intervals must be a positive whole number.');
    end
end

function write_signal(file, t, v, numFmt, unit, comment)
% 1D table: x = time, y = signal value.
    fid = fopen(file, 'w');
    if fid < 0
        error('Cannot open "%s" for writing.', file);
    end
    closer = onCleanup(@() fclose(fid));
    fprintf(fid, '# Table format: 1D\n');
    fprintf(fid, '# %s\n', comment);
    fprintf(fid, '# axis1_unit = s\n');
    if ~isempty(unit)
        fprintf(fid, '# table_unit = %s\n', unit);
    end
    fprintf(fid, [numFmt ' ' numFmt '\n'], [t(:)'; v(:)']);
end

function s = safe_name(name)
% Column header -> text usable in a file name.
    s = regexprep(name, '[^A-Za-z0-9_]+', '_');
    s = regexprep(s, '^_+|_+$', '');
    if isempty(s)
        s = 'signal';
    end
end


%% =========================================================================
%  7) OFF-GRID TEST POINTS  (optional: cfg.offGridPoints = 0 skips all of it)
%  =========================================================================

function [Xo, yo] = offgrid_points(cfg, X, evaluate)
% Random test points between the breakpoints and the table output there.
% X holds the data rows (one column per breakpoint), EVALUATE maps query
% points to table values (NaN outside the table). Axes not listed in
% cfg.offGridAxes take random values of their own breakpoints.
    n = cfg.offGridPoints;
    N = size(X, 2);
    offAxes = cfg.offGridAxes;
    if isempty(offAxes)
        offAxes = 1:N;
    end
    lo = min(X, [], 1);
    hi = max(X, [], 1);
    try                                           % repeatable, and leave the
        saved = rng;                              % caller's random state alone
        rng(cfg.offGridSeed);
    catch
        saved = rand('state');                    %#ok<RAND>
        rand('state', cfg.offGridSeed);           %#ok<RAND>
    end
    Xo = zeros(0, N);
    yo = zeros(0, 1);
    for attempt = 1:100
        m = n - size(Xo, 1);
        if m <= 0
            break
        end
        Q = zeros(m, N);
        for k = 1:N
            if any(offAxes == k)
                Q(:, k) = lo(k) + rand(m, 1) * (hi(k) - lo(k));
            else
                values = unique(X(:, k));
                Q(:, k) = values(randi(numel(values), m, 1));
            end
        end
        v = evaluate(Q);
        ok = ~isnan(v);                           % drop points outside the table
        Xo = [Xo; Q(ok, :)];                      %#ok<AGROW>
        yo = [yo; v(ok)];                         %#ok<AGROW>
    end
    if isstruct(saved)
        rng(saved);
    else
        rand('state', saved);                     %#ok<RAND>
    end
    if size(Xo, 1) < n
        warning('Only %d of %d off-grid test points fall inside the table.', size(Xo, 1), n);
    end
end

function v = interp_multi1d(rows, Q)
% Table value at the rows of Q ([y x] or [z y x]; NaN outside), interpolated
% as described in the Amesim docs: along x inside each curve first, then
% linearly between the two neighbouring curves (and, for MM1D, between the
% two neighbouring z blocks).
    v = nan(size(Q, 1), 1);
    for r = 1:size(Q, 1)
        v(r) = interp_level(rows, Q(r, :), 1);
    end
end

function v = interp_level(rows, q, level)
    nLevels = size(rows, 2) - 1;
    if level == nLevels                           % inside one curve: along x
        xs = rows(:, level);
        if numel(xs) == 1
            v = rows(1, end);
            if q(level) ~= xs
                v = NaN;
            end
        else
            v = interp1(xs, rows(:, end), q(level), 'linear');
        end
        return
    end
    keys = unique(rows(:, level));
    z = q(level);
    if z < keys(1) || z > keys(end)
        v = NaN;
        return
    end
    i = find(keys <= z, 1, 'last');
    v = interp_level(rows(rows(:, level) == keys(i), :), q, level + 1);
    if keys(i) ~= z                               % between two slices
        v2 = interp_level(rows(rows(:, level) == keys(i + 1), :), q, level + 1);
        w = (z - keys(i)) / (keys(i + 1) - keys(i));
        v = (1 - w) * v + w * v2;
    end
end
