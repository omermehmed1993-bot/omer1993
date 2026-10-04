function make_amesim_mission_signals(varargin)
%MAKE_AMESIM_MISSION_SIGNALS  Mission profile (Excel)  ->  Amesim input-signal tables.
%
%   HOW TO USE
%     1. Edit the USER SETTINGS block below.
%     2. Press Run (F5), or type  make_amesim_mission_signals  in the Command Window.
%
%   Any setting can also be given on the command line, which overrides the
%   block below, e.g.
%     make_amesim_mission_signals('excelFile', 'mission.xlsx', 'tableFile', 'FADEC_5D.txt')
%
%   INPUT DATA  (one row per time point, header row on top)
%     Time   1st input   2nd input   ...   (in the table's breakpoint order)
%     The time column is found by its header (time, Time_s, Time [s], t ...)
%     and must increase from row to row. Every other column is an input of
%     the lookup table, in breakpoint order: the 1st input column drives
%     breakpoint 1 (X1), the 2nd drives breakpoint 2, and so on.
%
%   OUTPUT FILES  (next to the Excel file, or at outFile)
%     <name>_input<k>_<column>.txt   one per input, # Table format: 1D,
%                                    x = time [s], y = that input
%     With tableFile set (an Amesim ND, M1D or MM1D table made by the other
%     tools), the profile is also checked against the table's breakpoint
%     ranges, and if it stays inside them
%     <name>_expected_<value>.txt    the table output along the mission
%                                    (x = time), for comparing with Amesim.
%
%   All files are read back and checked after writing.

    %% ======================= USER SETTINGS =======================
    cfg.excelFile    = '';        % mission profile Excel/CSV; '' = pick it in a dialog
    cfg.sheet        = 1;         % sheet name or number
    cfg.timeColumn   = 'auto';    % 'auto' = find it by its header, or its column number
    cfg.inputColumns = [];        % input columns in breakpoint order (1st, 2nd, ...);
                                  %   [] = all columns except time, in sheet order
    cfg.inputUnits   = {};        % one unit per input, e.g. {'', 'm', 'null'}; '' to skip
    cfg.tableFile    = '';        % optional Amesim table to check against / get the
                                  %   expected output from; '' = no check
    cfg.outFile      = '';        % base name; '' = <excel name>_mission.txt next to the Excel file
    cfg.precision    = 15;        % significant digits written to the files
    %% =============================================================

    cfg = apply_overrides(cfg, varargin);

    % 1) Read the profile ----------------------------------------------------
    if isempty(cfg.excelFile)
        [f, p] = uigetfile({'*.xlsx;*.xls;*.xlsm;*.csv', 'Data files'}, ...
                           'Select the mission profile');
        if isequal(f, 0)
            disp('Cancelled.');
            return
        end
        cfg.excelFile = fullfile(p, f);
    end
    [data, headers] = read_sheet(cfg.excelFile, cfg.sheet);
    [t, X, inputNames] = select_columns(data, headers, cfg);

    % 2) Write one 1D table per input (x = time) -----------------------------
    if isempty(cfg.outFile)
        [p, name] = fileparts(cfg.excelFile);
        cfg.outFile = fullfile(p, [name '_mission.txt']);
    end
    [p, base] = fileparts(cfg.outFile);
    numFmt = sprintf('%%.%dg', cfg.precision);
    files = cell(1, numel(inputNames));
    for k = 1:numel(inputNames)
        unit = '';
        if numel(cfg.inputUnits) >= k
            unit = cfg.inputUnits{k};
        end
        files{k} = fullfile(p, sprintf('%s_input%d_%s.txt', base, k, safe_name(inputNames{k})));
        write_signal(files{k}, t, X(:, k), numFmt, unit, ...
            sprintf('Mission input %d: %s vs time', k, inputNames{k}));
    end
    check_signals(files, t, X, cfg);

    % 3) Optional: check against the lookup table and write the expected output
    expectedFile = '';
    if ~isempty(cfg.tableFile)
        expectedFile = check_against_table(cfg, t, X, inputNames, p, base, numFmt);
    end

    % 4) Summary --------------------------------------------------------------
    fprintf('\nMission input signals (1D tables, x = time [s]), %d points each, same time vector:\n', ...
            numel(t));
    fprintf('  %s\n', files{:});
    if ~isempty(expectedFile)
        fprintf('  %s\n', expectedFile);
    end
    fprintf('  Profile covers t = %g ... %g s (smallest time step %g s).\n', ...
            t(1), t(end), min(diff(t)));
    fprintf(['  Amesim: final time <= %g s; a print interval of %g s or smaller shows ' ...
             'every profile point.\n'], t(end), min(diff(t)));
    if t(1) > 0
        fprintf('  Note: the profile starts at t = %g s, after the Amesim start time 0.\n', t(1));
    end
    fprintf('  Check passed: every file read back and matches the profile.\n\n');
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

function [t, X, inputNames] = select_columns(data, headers, cfg)
% Time vector and the input columns (breakpoint order) of the profile.
    nCols = size(data, 2);
    timeCol = find_time_column(headers, cfg.timeColumn);
    if isempty(timeCol)
        error(['No time column found. Name its header time / Time_s / t, or set ' ...
               'timeColumn to its column number.']);
    end
    inCols = cfg.inputColumns;
    if isempty(inCols)
        inCols = setdiff(1:nCols, timeCol, 'stable');
    end
    if any(inCols < 1 | inCols > nCols)
        error('The sheet has %d columns; check inputColumns.', nCols);
    end
    if any(inCols == timeCol)
        error('Column %d is the time column and cannot be an input.', timeCol);
    end
    if isempty(inCols)
        error('The profile has no input columns besides time.');
    end

    used = data(:, [timeCol inCols(:)']);
    used = used(~all(isnan(used), 2), :);          % drop empty rows
    bad = find(any(isnan(used), 2), 1);
    if ~isempty(bad)
        error('Profile row %d has an empty or non-numeric cell.', bad);
    end
    t = used(:, 1);
    X = used(:, 2:end);
    if numel(t) < 2
        error('The profile needs at least 2 time points.');
    end
    bad = find(diff(t) <= 0, 1);
    if ~isempty(bad)
        error(['Time must increase from row to row: row %d has t = %g after ' ...
               't = %g.'], bad + 1, t(bad + 1), t(bad));
    end
    inputNames = headers(inCols);
end


%% =========================================================================
%  2) WRITING AND CHECKING THE SIGNALS
%  =========================================================================

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

function check_signals(files, t, V, cfg)
% Every file must hold the same time vector and its column of V.
    relTol = 10^(1 - cfg.precision);
    for k = 1:numel(files)
        tv = read_pairs(files{k});
        if size(tv, 1) ~= numel(t) || ...
           any(abs(tv(:, 1) - t) > relTol * max(1, abs(t))) || ...
           any(abs(tv(:, 2) - V(:, k)) > relTol * max(1, abs(V(:, k))))
            error('Check failed: signal file "%s" does not match the profile.', files{k});
        end
    end
end

function tv = read_pairs(file)
    lines = regexp(fileread(file), '\r?\n', 'split');
    lines = lines(~strncmp(strtrim(lines), '#', 1));
    tv = reshape(sscanf(strjoin(lines, ' '), '%f'), 2, [])';
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
%  3) CHECK AGAINST THE LOOKUP TABLE
%  =========================================================================

function expectedFile = check_against_table(cfg, t, X, inputNames, p, base, numFmt)
% Compare the profile with the table's breakpoint ranges; if it stays
% inside, write the table output along the mission.
    tbl = read_amesim_table(cfg.tableFile);
    nIn = size(X, 2);
    if nIn ~= tbl.nInputs
        error(['The profile has %d inputs but "%s" is a %s table with %d inputs. ' ...
               'Check inputColumns.'], nIn, cfg.tableFile, tbl.format, tbl.nInputs);
    end
    [~, tname, text] = fileparts(cfg.tableFile);
    fprintf('\nChecking the profile against %s%s (%s table):\n', tname, text, tbl.format);

    % Per input: breakpoint range of the table
    for k = 1:nIn
        lo = tbl.lo(k);
        hi = tbl.hi(k);
        out = X(:, k) < lo | X(:, k) > hi;
        if any(out)
            first = find(out, 1);
            fprintf(['  Input %d %-22s range [%g ... %g]: %d points OUTSIDE, first at ' ...
                     't = %g s (value %g)\n'], k, inputNames{k}, lo, hi, sum(out), ...
                    t(first), X(first, k));
        else
            fprintf('  Input %d %-22s range [%g ... %g]: inside\n', k, inputNames{k}, lo, hi);
        end
    end

    % Whole points: inside the table (for M1D/MM1D also inside the curves)
    y = tbl.evaluate(X);
    out = isnan(y);
    if any(out)
        first = find(out, 1);
        fprintf(['  %d of %d profile points are outside the table (first at t = %g s); ' ...
                 'Amesim would extrapolate there.\n  Expected output not written: fix ' ...
                 'the profile or extend the table.\n'], sum(out), numel(t), t(first));
        expectedFile = '';
        return
    end
    fprintf('  All %d profile points are inside the table.\n', numel(t));

    expectedFile = fullfile(p, sprintf('%s_expected_%s.txt', base, safe_name(tbl.valueName)));
    write_signal(expectedFile, t, y, numFmt, tbl.tableUnit, ...
        sprintf('Expected output of %s%s along the mission: %s vs time', ...
                tname, text, tbl.valueName));
    check_signals({expectedFile}, t, y, cfg);
end

function tbl = read_amesim_table(file)
% Read an Amesim ND (1D ... 8D), M1D (T1D) or MM1D (T3D) table file.
    lines = regexp(fileread(file), '\r?\n', 'split');
    fmt = regexp(lines{1}, 'Table format:\s*(\S+)', 'tokens', 'once');
    if isempty(fmt)
        error('"%s" has no "# Table format:" header.', file);
    end
    fmt = upper(fmt{1});
    comments = lines(strncmp(strtrim(lines), '#', 1));
    tbl.valueName = 'output';
    tbl.tableUnit = '';
    for k = 1:numel(comments)
        tok = regexp(comments{k}, '^#\s*Value:\s*(.*)$', 'tokens', 'once');
        if ~isempty(tok)
            tbl.valueName = strtrim(tok{1});
        end
        tok = regexp(comments{k}, '^#\s*table_unit\s*=\s*(.*)$', 'tokens', 'once');
        if ~isempty(tok)
            tbl.tableUnit = strtrim(tok{1});
        end
    end
    body = lines(~strncmp(strtrim(lines), '#', 1));
    values = sscanf(strjoin(body, ' '), '%f');

    nd = regexp(fmt, '^(\d)D$', 'tokens', 'once');
    if ~isempty(nd)                                  % regular ND table
        N = str2double(nd{1});
        tbl.format = fmt;
        tbl.nInputs = N;
        if N == 1
            xy = reshape(values, 2, [])';
            axesValues = {xy(:, 1)'};
            U = xy(:, 2);
        else
            n = values(1:N)';
            pos = N;
            axesValues = cell(1, N);
            for k = 1:N
                axesValues{k} = values(pos + (1:n(k)))';
                pos = pos + n(k);
            end
            U = reshape(values(pos+1:end), n);
        end
        tbl.lo = cellfun(@(a) a(1), axesValues);
        tbl.hi = cellfun(@(a) a(end), axesValues);
        tbl.evaluate = @(Q) interp_nd(axesValues, U, Q);
    elseif any(strcmp(fmt, {'T1D', 'T3D'}))          % M1D / MM1D
        if strcmp(fmt, 'T1D')
            nLevels = 2;
            tbl.format = 'M1D';
        else
            nLevels = 3;
            tbl.format = 'MM1D';
        end
        rows = zeros(0, nLevels + 1);
        pos = 0;
        while pos < numel(values)
            [block, pos] = read_level(values, pos, 1, nLevels);
            rows = [rows; block]; %#ok<AGROW>
        end
        tbl.nInputs = nLevels;
        tbl.lo = min(rows(:, 1:nLevels), [], 1);
        tbl.hi = max(rows(:, 1:nLevels), [], 1);
        tbl.evaluate = @(Q) interp_multi1d(rows, Q);
    else
        error('Unsupported table format "%s" in "%s".', fmt, file);
    end
end

function [rows, pos] = read_level(values, pos, level, nLevels)
% Read one "key count" slice of a T1D / T3D file starting after POS.
    key = values(pos + 1);
    count = values(pos + 2);
    pos = pos + 2;
    if level + 1 == nLevels
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

function v = interp_nd(axesValues, U, Q)
% Multilinear interpolation of an ND table at the rows of Q (NaN outside).
    if numel(axesValues) == 1
        v = interp1(axesValues{1}(:), U(:), Q(:, 1), 'linear');
    else
        q = num2cell(Q, 1);
        v = interpn(axesValues{:}, U, q{:}, 'linear');
    end
    v = v(:);
end

function v = interp_multi1d(rows, Q)
% M1D/MM1D value at the rows of Q ([y x] or [z y x]; NaN outside): along x
% inside each curve, then linearly between neighbouring curves / z blocks.
    v = nan(size(Q, 1), 1);
    for r = 1:size(Q, 1)
        v(r) = interp_level(rows, Q(r, :), 1);
    end
end

function v = interp_level(rows, q, level)
    nLevels = size(rows, 2) - 1;
    if level == nLevels
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
    if keys(i) ~= z
        v2 = interp_level(rows(rows(:, level) == keys(i + 1), :), q, level + 1);
        w = (z - keys(i)) / (keys(i + 1) - keys(i));
        v = (1 - w) * v + w * v2;
    end
end


%% =========================================================================
%  4) HELPERS
%  =========================================================================

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
    if ischar(cfg.inputUnits)
        cfg.inputUnits = {cfg.inputUnits};
    end
end
