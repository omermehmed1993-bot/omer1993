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
%     When run, the code ASKS for the Amesim total simulation time and number
%     of intervals (leave simTime / nIntervals empty), then writes for every
%     input a 1D table <table>_input<k>_<name>.txt with x = time [s] and
%     y = that input, plus <table>_expected_<value>.txt (x = time, y = data
%     output). All are sampled on the Amesim print grid t = 0 : T/N : T; the
%     data rows are spread over those points in sheet order, each row held
%     for an equal number of points. At every print time all inputs equal one
%     data row, so the table output equals that row's value.
%
%   After writing, the file is read back and every Excel row is checked
%   against it.

    %% ======================= USER SETTINGS =======================
    cfg.excelFile    = '';        % Excel/CSV file; '' = pick it in a dialog
    cfg.sheet        = 1;         % sheet name or number
    cfg.outFile      = '';        % '' = <excel name>_<N>D.txt next to the Excel file
    cfg.inputColumns = [];        % breakpoint columns in file order (1st = X1, 2nd = X2, ...)
                                  %   [] = all columns except the output, in sheet order
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
    cfg.simTime      = [];        % total simulation time [s];   [] = ask when run
    cfg.nIntervals   = [];        % number of intervals;         [] = ask when run
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
    [X, y, axisNames, valueName] = select_columns(data, headers, cfg);
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
        write_signals(cfg, X, y, axisNames, valueName);
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

function [X, y, axisNames, valueName] = select_columns(data, headers, cfg)
% Split the sheet into input columns X (one per axis) and the output y.
    nCols = size(data, 2);
    outCol = cfg.outputColumn;
    if isempty(outCol)
        outCol = nCols;
    end
    inCols = cfg.inputColumns;
    if isempty(inCols)
        inCols = setdiff(1:nCols, outCol, 'stable');
    end
    cols = [inCols(:)' outCol];
    if any(cols < 1 | cols > nCols)
        error('The sheet has %d columns; check inputColumns/outputColumn.', nCols);
    end
    if numel(inCols) > 8
        error('Amesim tables support at most 8 inputs, got %d.', numel(inCols));
    end

    used = data(:, cols);
    used = used(~all(isnan(used), 2), :);          % drop empty rows
    bad = find(any(isnan(used), 2), 1);
    if ~isempty(bad)
        error('Data row %d has an empty or non-numeric cell.', bad);
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

function write_signals(cfg, X, y, inputNames, valueName)
% One 1D table per input (x = time, y = input value) plus one for the
% expected output, all sampled on the Amesim print grid
%     t_i = i * simTime / nIntervals,   i = 0 ... nIntervals.
% The data rows are spread over those print points in sheet order, each
% row held for an equal number of points (+-1), so at every print time all
% inputs equal one data row and the table output equals that row's value.
    M = size(X, 1);
    [simTime, nInt] = ask_run_parameters(cfg, M);
    if isempty(simTime)
        fprintf('Input signals skipped (no simulation time given).\n\n');
        return
    end
    nPts = nInt + 1;
    if nPts < M
        error(['%d intervals give %d print points, fewer than the %d data rows, ' ...
               'so some rows would never be applied. Use at least %d intervals.'], ...
              nInt, nPts, M, M - 1);
    end
    t = (0:nInt)' * (simTime / nInt);
    row = floor((0:nInt)' * M / nPts) + 1;         % data row applied at each print point
    held = accumarray(row, 1, [M 1]);               % print points per data row

    [p, base] = fileparts(cfg.outFile);
    numFmt = sprintf('%%.%dg', cfg.precision);
    nIn = numel(inputNames);
    files = cell(1, nIn + 1);
    for k = 1:nIn
        unit = '';
        if numel(cfg.axisUnits) >= k
            unit = cfg.axisUnits{k};
        end
        files{k} = fullfile(p, sprintf('%s_input%d_%s.txt', base, k, ...
                                       safe_name(inputNames{k})));
        write_signal(files{k}, t, X(row, k), numFmt, unit, ...
            sprintf('Input signal %d of %s.txt: %s vs time', k, base, inputNames{k}));
    end
    files{end} = fullfile(p, sprintf('%s_expected_%s.txt', base, safe_name(valueName)));
    write_signal(files{end}, t, y(row), numFmt, cfg.tableUnit, ...
        sprintf('Expected output of %s.txt: %s vs time', base, valueName));

    % Check: every file has the same time vector and the right row values
    cols = [X y];
    relTol = 10^(1 - cfg.precision);
    for k = 1:numel(files)
        lines = regexp(fileread(files{k}), '\r?\n', 'split');
        lines = lines(~strncmp(strtrim(lines), '#', 1));
        tv = reshape(sscanf(strjoin(lines, ' '), '%f'), 2, [])';
        want = cols(row, k);
        if size(tv, 1) ~= nPts || ...
           any(abs(tv(:, 1) - t) > relTol * max(1, abs(t))) || ...
           any(abs(tv(:, 2) - want) > relTol * max(1, abs(want)))
            error('Check failed: signal file "%s" does not match the data.', files{k});
        end
    end

    fprintf('Input signals (1D tables, x = time [s]), %d points each, same time vector:\n', nPts);
    fprintf('  %s\n', files{:});
    fprintf('  Amesim run parameters: final time = %g s, %d intervals (print interval %g s).\n', ...
            simTime, nInt, simTime / nInt);
    if min(held) == max(held)
        fprintf('  Each of the %d data rows is held for %d print point(s) (%g s).\n\n', ...
                M, held(1), held(1) * simTime / nInt);
    else
        fprintf(['  Each of the %d data rows is held for %d or %d print points ' ...
                 '(use %d or %d intervals for an equal hold).\n\n'], ...
                M, min(held), max(held), M * floor(nPts / M) - 1, M * ceil(nPts / M) - 1);
    end
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
