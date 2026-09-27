function amesim_write_table(filename, axesValues, U, varargin)
%AMESIM_WRITE_TABLE Write a regular-mesh table in Simcenter Amesim ASCII format.
%
%   amesim_write_table(FILENAME, AXES, U) writes the N-dimensional table U,
%   defined on the breakpoint vectors in the cell array AXES, to FILENAME
%   (.txt or .data) using the Amesim "# Table format: ND" layout
%   (N = 1..8). U must be an array of size [numel(AXES{1}) ... numel(AXES{N})],
%   i.e. U(i1,i2,...,iN) is the value at (AXES{1}(i1), ..., AXES{N}(iN)).
%
%   File layout written for N >= 2 (identical to the Amesim 2D/3D/ND docs):
%
%       # Table format: 5D
%       # table_unit = ...            (optional)
%       # axis1_unit = ...            (optional)
%       n1
%       n2
%       ...
%       nN
%       x1(1) x1(2) ... x1(n1)        <- axis 1 breakpoints
%       ...
%       xN(1) ... xN(nN)              <- axis N breakpoints
%
%       u(1,1,1..) u(2,1,1..) ... u(n1,1,1..)    <- one line = all of axis 1
%       u(1,2,1..) u(2,2,1..) ... u(n1,2,1..)       for fixed axis 2..N,
%       ...                                          axis 2 varies down the lines,
%                                                    then axis 3, 4, ... (blocks)
%
%   For N = 1 the "# Table format: 1D" x/y column pairs are written.
%
%   Name-value options:
%     'TableUnit'  - unit string of the table values, e.g. 'Nm'  (default '')
%     'AxisUnits'  - cellstr of N unit strings, '' to skip one   (default {})
%     'AxisNames'  - cellstr of N names, written as comments      (default {})
%     'Comments'   - char or cellstr of extra comment lines       (default {})
%     'Precision'  - significant digits for numbers               (default 15)
%
%   Example:
%     x = 0:10; y = [1 2 5];
%     [X, Y] = ndgrid(x, y);
%     amesim_write_table('my2d.txt', {x, y}, X.*Y, 'AxisUnits', {'rev/min','bar'});

    opts = parse_options(varargin, struct( ...
        'TableUnit', '', 'AxisUnits', {{}}, 'AxisNames', {{}}, ...
        'Comments', {{}}, 'Precision', 15));

    if ~iscell(axesValues)
        axesValues = {axesValues};
    end
    N = numel(axesValues);
    if N < 1 || N > 8
        error('amesim_write_table:dims', ...
              'Amesim ND tables support 1 to 8 dimensions, got %d.', N);
    end

    % --- validate axes -------------------------------------------------------
    n = zeros(1, N);
    for k = 1:N
        a = double(axesValues{k}(:)');
        if isempty(a) || any(~isfinite(a))
            error('amesim_write_table:axis', ...
                  'Axis %d is empty or contains NaN/Inf.', k);
        end
        if numel(a) < 2
            error('amesim_write_table:axis', ...
                  ['Axis %d has only one breakpoint. Amesim needs at least 2 ' ...
                   'points per axis; drop this input or add points.'], k);
        end
        if any(diff(a) <= 0)
            error('amesim_write_table:axis', ...
                  'Axis %d breakpoints must be strictly increasing.', k);
        end
        axesValues{k} = a;
        n(k) = numel(a);
    end

    % --- validate values -----------------------------------------------------
    U = double(U);
    if N == 1
        U = U(:);
        sz = numel(U);
    else
        sz = size(U);
        sz(end+1:N) = 1;
    end
    if numel(U) ~= prod(n) || (N > 1 && ~isequal(sz(1:N), n))
        error('amesim_write_table:size', ...
              'Size of U is [%s] but the axes define [%s].', ...
              num2str(sz), num2str(n));
    end
    if any(~isfinite(U(:)))
        error('amesim_write_table:values', ...
              'U contains %d NaN/Inf values; Amesim cannot read them.', ...
              sum(~isfinite(U(:))));
    end

    axisUnits = to_cellstr(opts.AxisUnits);
    axisNames = to_cellstr(opts.AxisNames);
    comments  = to_cellstr(opts.Comments);
    if ~isempty(axisUnits) && numel(axisUnits) ~= N
        error('amesim_write_table:units', ...
              'AxisUnits must have %d entries (one per axis).', N);
    end
    if ~isempty(axisNames) && numel(axisNames) ~= N
        error('amesim_write_table:names', ...
              'AxisNames must have %d entries (one per axis).', N);
    end

    numFmt = sprintf('%%.%dg', opts.Precision);

    % --- write ---------------------------------------------------------------
    fid = fopen(filename, 'w');
    if fid < 0
        error('amesim_write_table:open', 'Cannot open "%s" for writing.', filename);
    end
    cleaner = onCleanup(@() fclose(fid));

    fprintf(fid, '# Table format: %dD\n', N);
    for k = 1:numel(comments)
        fprintf(fid, '# %s\n', comments{k});
    end
    for k = 1:numel(axisNames)
        if ~isempty(axisNames{k})
            fprintf(fid, '# X%d: %s\n', k, axisNames{k});
        end
    end
    if ~isempty(opts.TableUnit)
        fprintf(fid, '# table_unit = %s\n', opts.TableUnit);
    end
    for k = 1:numel(axisUnits)
        if ~isempty(axisUnits{k})
            fprintf(fid, '# axis%d_unit = %s\n', k, axisUnits{k});
        end
    end

    if N == 1
        % 1D format: x y pairs, one couple per line
        fprintf(fid, [numFmt ' ' numFmt '\n'], [axesValues{1}; U(:)']);
        return
    end

    % Number of breakpoints of each axis, one per line
    fprintf(fid, '%d\n', n);

    % Breakpoints of each axis, one axis per line
    for k = 1:N
        write_row(fid, numFmt, axesValues{k});
    end
    fprintf(fid, '\n');

    % Values: axis 1 along a line, axis 2 down the lines, then axis 3..N
    % (MATLAB column-major order == Amesim storage order).
    V = reshape(U, n(1), []);
    for c = 1:size(V, 2)
        write_row(fid, numFmt, V(:, c)');
        if mod(c, n(2)) == 0 && c < size(V, 2)
            fprintf(fid, '\n');   % blank line between 2D slices (cosmetic)
        end
    end
end

function write_row(fid, numFmt, row)
    fprintf(fid, [strjoin(repmat({numFmt}, 1, numel(row)), ' ') '\n'], row);
end

function c = to_cellstr(v)
    if isempty(v)
        c = {};
    elseif ischar(v)
        c = cellstr(v);
    elseif isstring(v)
        c = cellstr(v);
    else
        c = v;
    end
    c = c(:)';
end

function opts = parse_options(args, opts)
    if mod(numel(args), 2) ~= 0
        error('amesim_write_table:args', 'Options must be name-value pairs.');
    end
    names = fieldnames(opts);
    for k = 1:2:numel(args)
        match = strcmpi(names, char(args{k}));
        if ~any(match)
            error('amesim_write_table:args', 'Unknown option "%s".', char(args{k}));
        end
        opts.(names{match}) = args{k+1};
    end
end
