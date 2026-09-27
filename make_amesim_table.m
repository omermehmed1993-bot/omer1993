function make_amesim_table(varargin)
%MAKE_AMESIM_TABLE  Excel column data  ->  Simcenter Amesim ND table file (1D ... 8D).
%
%   HOW TO USE
%     1. Edit the USER SETTINGS block below.
%     2. Press Run (F5), or type  make_amesim_table  in the Command Window.
%
%   Any setting can also be given on the command line, which overrides the
%   block below, e.g.
%     make_amesim_table('excelFile', 'Example.xlsx', 'tableUnit', 'kg/s')
%
%   INPUT DATA  (one row per point, rows in any order, header row on top)
%     1st bkpt  2nd bkpt  3rd bkpt  ...  Output
%     COLUMN ORDER = BREAKPOINT ORDER IN THE FILE: the 1st input column is
%     axis X1 (its breakpoints are written first), the 2nd is X2, and so on;
%     the output column becomes the table value. Every combination of the
%     input values must be present (full grid), e.g. 9*5*5*3*7 = 4725 rows.
%
%   OUTPUT FILE  (Amesim "ND table" layout, same as the 2D/3D docs)
%     # Table format: 5D
%     # table_unit = kg/s                <- optional unit lines
%     n1                                 <- number of breakpoints, one axis per line
%     ...
%     n5
%     x1(1) ... x1(n1)                   <- breakpoints, one axis per line
%     ...
%     x5(1) ... x5(n5)
%     u(1,1,1,1,1) ... u(n1,1,1,1,1)     <- values: X1 along a line,
%     u(1,2,1,1,1) ... u(n1,2,1,1,1)        X2 down the lines, then X3, X4, X5
%     ...
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
%   After writing, the file is read back and every Excel row is checked
%   against it.

    %% ======================= USER SETTINGS =======================
    cfg.excelFile    = '';        % Excel/CSV file; '' = pick it in a dialog
    cfg.sheet        = 1;         % sheet name or number
    cfg.outFile      = '';        % '' = <excel name>_<N>D.txt next to the Excel file
    cfg.timeColumn   = 'auto';    % time column, never a table input: 'auto' = find it
                                  %   by its header (time, Time_s, t ...), 0 = none, or a number
    cfg.inputColumns = [];        % breakpoint columns in file order (1st = X1, 2nd = X2, ...)
                                  %   [] = all columns except time and output, in sheet order
                                  %   e.g. [2 3 4 5 1] makes sheet column 2 the 1st breakpoint
    cfg.outputColumn = [];        % [] = last column
    cfg.tableUnit    = '';        % unit of the table value, e.g. 'kg/s' ('' = none)
    cfg.axisUnits    = {};        % one unit per axis, e.g. {'', 'm', 'null', '', ''}
    cfg.duplicates   = 'error';   % same point twice: 'error' | 'mean' | 'first' | 'last'
    cfg.fillMissing  = 'error';   % missing points:   'error' | 'nearest' | 'linear'
    cfg.tolerance    = 1e-9;      % merge breakpoints that differ only by round-off
    cfg.precision    = 15;        % significant digits written to the file
    %% ---- input signals: 1D tables (x = time) that drive the table inputs ----
    cfg.signals      = true;      % also write one time table per input + expected output
    cfg.signalTime   = 'auto';    % time of the signals: 'auto' = the sheet's time column
                                  %   if there is one, else 'grid'; or 'sheet' | 'grid'
    cfg.simTime      = [];        % 'grid' only: total simulation time [s]; [] = ask
    cfg.nIntervals   = [];        % 'grid' only: number of intervals;        [] = ask
    cfg.rowOrder     = 'sheet';   % order the rows are played: 'sheet' | 'snake'
                                  %   (snake: one input changes by one breakpoint at a time)
    %% ---- optional off-grid test (offGridPoints = 0 switches it off) ----
    cfg.offGridPoints = 0;        % random test points between breakpoints; 0 = off
    cfg.offGridAxes  = [];        % breakpoints moved off-grid ([] = all), e.g. [2 3 4 5]
                                  %   keeps breakpoint 1 on its values
    cfg.offGridSeed  = 1;         % random seed, so the test points are repeatable
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
    [X, y, axisNames, valueName, tSheet] = select_columns(data, headers, cfg);
    N = size(X, 2);

    % 2) Arrange the rows on a regular grid ----------------------------------
    [axesValues, U, rowIndex, info] = build_grid(X, y, cfg);

    % 3) Write the Amesim file -----------------------------------------------
    if isempty(cfg.outFile)
        [p, name] = fileparts(cfg.excelFile);
        cfg.outFile = fullfile(p, sprintf('%s_%dD.txt', name, N));
    end
    [~, srcName, srcExt] = fileparts(cfg.excelFile);
    comments = {['Created from ' srcName srcExt], ['Value: ' valueName]};
    write_table(cfg.outFile, axesValues, U, cfg, axisNames, comments);

    % 4) Verify: read the file back and check every data row -----------------
    verify_file(cfg.outFile, axesValues, U, rowIndex, y, cfg);

    % 5) Summary --------------------------------------------------------------
    print_summary(cfg, axesValues, axisNames, valueName, size(X, 1), info);

    % 6) Input signals: one 1D table (x = time) per input, same time vector
    if cfg.signals
        timing = write_signals(cfg, X, y, axisNames, valueName, tSheet);

        % 7) Optional off-grid test points (cfg.offGridPoints = 0 skips this)
        if cfg.offGridPoints > 0 && ~isempty(timing)
            [Xo, yo] = offgrid_points(cfg, X, @(Q) interp_nd(axesValues, U, Q));
            write_offgrid_set(cfg, timing, Xo, yo, axisNames, valueName);
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

function [X, y, axisNames, valueName, t] = select_columns(data, headers, cfg)
% Split the sheet into input columns X (one per axis), the output y and
% the time column t ([] if the sheet has none).
    nCols = size(data, 2);
    timeCol = find_time_column(headers, cfg.timeColumn);
    available = setdiff(1:nCols, timeCol, 'stable');
    outCol = cfg.outputColumn;
    if isempty(outCol)
        outCol = available(end);
    end
    inCols = cfg.inputColumns;
    if isempty(inCols)
        inCols = setdiff(available, outCol, 'stable');
    end
    cols = [inCols(:)' outCol];
    if any(cols < 1 | cols > nCols)
        error('The sheet has %d columns; check inputColumns/outputColumn.', nCols);
    end
    if ~isempty(timeCol) && any(cols == timeCol)
        error(['Column %d is the time column and cannot be a table input or value. ' ...
               'Check inputColumns/outputColumn, or set timeColumn = 0.'], timeCol);
    end
    if numel(inCols) > 8
        error('Amesim tables support at most 8 inputs, got %d.', numel(inCols));
    end

    used = data(:, [cols timeCol]);
    used = used(~all(isnan(used(:, 1:numel(cols))), 2), :);   % drop empty rows
    bad = find(any(isnan(used), 2), 1);
    if ~isempty(bad)
        error('Data row %d has an empty or non-numeric cell.', bad);
    end
    t = [];
    if ~isempty(timeCol)
        t = used(:, end);
        used = used(:, 1:end-1);
    end
    X = used(:, 1:end-1);
    y = used(:, end);
    axisNames = headers(inCols);
    valueName = headers{outCol};
end


%% =========================================================================
%  2) GRID
%  =========================================================================

function [axesValues, U, lin, info] = build_grid(X, y, cfg)
% Breakpoints of each column, and the N-D value array U with
% U(i1,...,iN) = y at (axes{1}(i1), ..., axes{N}(iN)).
% lin(r) is the position of data row r inside U.
    [M, N] = size(X);
    axesValues = cell(1, N);
    idx = zeros(M, N);
    n = zeros(1, N);
    for k = 1:N
        [axesValues{k}, idx(:, k)] = unique_with_tolerance(X(:, k), cfg.tolerance);
        n(k) = numel(axesValues{k});
        if n(k) < 2
            error(['Input "%d" has a single value. Amesim needs at least 2 ' ...
                   'breakpoints per axis; remove this column with inputColumns.'], k);
        end
    end
    if N == 1
        lin = idx(:, 1);
    else
        sub = num2cell(idx, 1);
        lin = sub2ind(n, sub{:});
    end
    total = prod(n);
    counts = accumarray(lin, 1, [total 1]);

    % Points given more than once
    nDup = sum(counts > 1);
    vals = zeros(total, 1);
    if nDup == 0
        vals(lin) = y;
    else
        switch lower(cfg.duplicates)
            case 'mean'
                vals = accumarray(lin, y, [total 1]) ./ max(counts, 1);
            case 'first'
                [~, r] = unique(lin, 'first');
                vals(lin(r)) = y(r);
            case 'last'
                [~, r] = unique(lin, 'last');
                vals(lin(r)) = y(r);
            otherwise
                error(['%d grid points appear more than once, e.g. (%s).\n' ...
                       'Set duplicates to ''mean'', ''first'' or ''last'' to accept them.'], ...
                      nDup, point_text(find(counts > 1, 1), n, axesValues));
        end
    end

    % Points not given at all
    missing = find(counts == 0);
    if ~isempty(missing)
        switch lower(cfg.fillMissing)
            case {'nearest', 'linear'}
                vals(missing) = fill_points(missing, n, axesValues, X, y, ...
                                            lower(cfg.fillMissing));
            otherwise
                error(['The data is not a full grid: %d of %d points are missing ' ...
                       '(axis sizes [%s]), e.g. (%s).\n' ...
                       'Set fillMissing to ''nearest'' or ''linear'' to fill them.'], ...
                      numel(missing), total, num2str(n), ...
                      point_text(missing(1), n, axesValues));
        end
    end

    if N == 1
        U = vals;
    else
        U = reshape(vals, n);
    end
    info = struct('duplicates', nDup, 'missing', numel(missing));
end

function [values, index] = unique_with_tolerance(x, tol)
% Sorted unique values of x; values closer than tol (relative) are merged.
% Each group is represented by its most frequent value, which is a value
% that really is in the data (a mean would add round-off: 0.3 -> 0.300..05).
    [xs, order] = sort(x);
    scale = max(max(abs(xs)), 1);
    groupId = cumsum([true; diff(xs) > tol * scale]);
    values = accumarray(groupId, xs, [], @mode)';
    index = zeros(size(x));
    index(order) = groupId;
end

function v = fill_points(linMissing, n, axesValues, X, y, method)
% Values at missing grid points, by linear interpolation of the data
% (griddatan) or nearest neighbour; axes are scaled to [0,1] first.
    N = numel(n);
    sub = cell(1, N);
    [sub{:}] = ind2sub(n, linMissing(:));
    Q = zeros(numel(linMissing), N);
    for k = 1:N
        Q(:, k) = axesValues{k}(sub{k});
    end
    lo = min(X, [], 1);
    span = max(X, [], 1) - lo;
    span(span == 0) = 1;
    Xs = (X - lo) ./ span;
    Qs = (Q - lo) ./ span;

    v = nan(size(Q, 1), 1);
    if strcmp(method, 'linear')
        if N == 1
            v = interp1(Xs, y, Qs, 'linear');
        else
            v = griddatan(Xs, y, Qs, 'linear');
        end
    end
    for r = find(isnan(v))'           % nearest (also outside the convex hull)
        [~, j] = min(sum((Xs - Qs(r, :)).^2, 2));
        v(r) = y(j);
    end
end

function s = point_text(linIdx, n, axesValues)
    N = numel(n);
    sub = cell(1, N);
    [sub{:}] = ind2sub(n, linIdx);
    parts = cell(1, N);
    for k = 1:N
        parts{k} = sprintf('X%d=%g', k, axesValues{k}(sub{k}));
    end
    s = strjoin(parts, ', ');
end


%% =========================================================================
%  3) WRITING
%  =========================================================================

function write_table(file, axesValues, U, cfg, axisNames, comments)
% Write the table in the Amesim 1D / ND layout (see the header of this file).
    N = numel(axesValues);
    n = cellfun(@numel, axesValues);
    if ~isempty(cfg.axisUnits) && numel(cfg.axisUnits) ~= N
        error('axisUnits must have %d entries (one per axis).', N);
    end
    numFmt = sprintf('%%.%dg', cfg.precision);

    fid = fopen(file, 'w');
    if fid < 0
        error('Cannot open "%s" for writing.', file);
    end
    closer = onCleanup(@() fclose(fid));

    % Header
    fprintf(fid, '# Table format: %dD\n', N);
    fprintf(fid, '# %s\n', comments{:});
    for k = 1:N
        fprintf(fid, '# Breakpoint %d (X%d): %s\n', k, k, axisNames{k});
    end
    if ~isempty(cfg.tableUnit)
        fprintf(fid, '# table_unit = %s\n', cfg.tableUnit);
    end
    for k = 1:numel(cfg.axisUnits)
        if ~isempty(cfg.axisUnits{k})
            fprintf(fid, '# axis%d_unit = %s\n', k, cfg.axisUnits{k});
        end
    end

    % 1D: x y couples
    if N == 1
        fprintf(fid, [numFmt ' ' numFmt '\n'], [axesValues{1}; U(:)']);
        return
    end

    % ND: sizes, breakpoints, then values with X1 along each line
    fprintf(fid, '%d\n', n);
    for k = 1:N
        write_line(fid, numFmt, axesValues{k});
    end
    fprintf(fid, '\n');
    V = reshape(U, n(1), []);                  % column-major = Amesim order
    for c = 1:size(V, 2)
        write_line(fid, numFmt, V(:, c)');
        if mod(c, n(2)) == 0 && c < size(V, 2)
            fprintf(fid, '\n');                % blank line between 2D slices
        end
    end
end

function write_line(fid, numFmt, row)
    fprintf(fid, [strjoin(repmat({numFmt}, 1, numel(row)), ' ') '\n'], row);
end


%% =========================================================================
%  4) VERIFICATION
%  =========================================================================

function verify_file(file, axesValues, U, rowIndex, y, cfg)
% Read the written file back and compare it with the grid and with every
% original data row.
    [axesBack, UBack] = read_table(file);
    relTol = 10^(1 - cfg.precision);
    ok = numel(axesBack) == numel(axesValues) && numel(UBack) == numel(U);
    for k = 1:numel(axesValues)
        ok = ok && isequal(size(axesBack{k}), size(axesValues{k})) && ...
             all(abs(axesBack{k} - axesValues{k}) <= relTol * max(1, abs(axesValues{k})));
    end
    if ~ok
        error('Check failed: the axes read back from "%s" do not match.', file);
    end
    if any(abs(UBack(:) - U(:)) > relTol * max(1, abs(U(:))))
        error('Check failed: the values read back from "%s" do not match.', file);
    end
    if strcmpi(cfg.duplicates, 'error')
        bad = find(abs(UBack(rowIndex) - y) > relTol * max(1, abs(y)), 1);
        if ~isempty(bad)
            error('Check failed: data row %d does not match the file.', bad);
        end
    end
end

function [axesValues, U] = read_table(file)
% Read an Amesim 1D / ND table file (comment lines start with #).
    lines = regexp(fileread(file), '\r?\n', 'split');
    fmt = regexp(lines{1}, 'Table format:\s*(\d)D', 'tokens', 'once');
    if isempty(fmt)
        error('"%s" has no "# Table format: ND" header.', file);
    end
    N = str2double(fmt{1});
    body = lines(~strncmp(strtrim(lines), '#', 1));
    values = sscanf(strjoin(body, ' '), '%f');

    if N == 1
        xy = reshape(values, 2, [])';
        axesValues = {xy(:, 1)'};
        U = xy(:, 2);
        return
    end
    n = values(1:N)';
    if numel(values) ~= N + sum(n) + prod(n)
        error('"%s" has the wrong number of values for a [%s] table.', file, num2str(n));
    end
    pos = N;
    axesValues = cell(1, N);
    for k = 1:N
        axesValues{k} = values(pos + (1:n(k)))';
        pos = pos + n(k);
    end
    U = reshape(values(pos+1:end), n);
end


%% =========================================================================
%  5) HELPERS
%  =========================================================================

function print_summary(cfg, axesValues, axisNames, valueName, nRows, info)
    fprintf('\nWrote %dD Amesim table: %s\n', numel(axesValues), cfg.outFile);
    for k = 1:numel(axesValues)
        fprintf('  Breakpoint %d (X%d): %-22s %3d points  [%g ... %g]\n', k, k, axisNames{k}, ...
                numel(axesValues{k}), axesValues{k}(1), axesValues{k}(end));
    end
    fprintf('  Value: %s', valueName);
    if ~isempty(cfg.tableUnit)
        fprintf(' [%s]', cfg.tableUnit);
    end
    fprintf('\n  %d values from %d data rows', prod(cellfun(@numel, axesValues)), nRows);
    if info.duplicates > 0
        fprintf(', %d duplicate points (%s)', info.duplicates, cfg.duplicates);
    end
    if info.missing > 0
        fprintf(', %d missing points filled (%s)', info.missing, cfg.fillMissing);
    end
    if strcmpi(cfg.duplicates, 'error')
        fprintf('\n  Check passed: file read back and every data row matches.\n\n');
    else
        fprintf('\n  Check passed: file read back and matches the grid.\n\n');
    end
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

function v = interp_nd(axesValues, U, Q)
% Multilinear interpolation of the ND table at the rows of Q (NaN outside),
% the interpolation an Amesim ND table uses between breakpoints.
    if numel(axesValues) == 1
        v = interp1(axesValues{1}(:), U(:), Q(:, 1), 'linear');
    else
        q = num2cell(Q, 1);
        v = interpn(axesValues{:}, U, q{:}, 'linear');
    end
    v = v(:);
end
