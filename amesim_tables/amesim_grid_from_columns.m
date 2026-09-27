function [axesValues, U, info] = amesim_grid_from_columns(X, y, varargin)
%AMESIM_GRID_FROM_COLUMNS Turn column data (one row per point) into a regular mesh.
%
%   [AXES, U] = amesim_grid_from_columns(X, Y) takes an M-by-N matrix X of
%   input values (column k = axis k) and an M-by-1 vector Y of outputs, as
%   they typically appear in an Excel sheet, and returns:
%     AXES - 1-by-N cell array of sorted unique breakpoints of each column
%     U    - N-D array, U(i1,...,iN) = Y at (AXES{1}(i1), ..., AXES{N}(iN))
%
%   The rows may be in any order. Every combination of breakpoints must be
%   present (full-factorial data), otherwise see 'FillMissing'.
%
%   Name-value options:
%     'Tolerance'   - relative tolerance used to merge breakpoints that
%                     differ only by round-off (e.g. 0.1 vs 0.1000000001).
%                     Default 1e-9.
%     'Duplicates'  - what to do when the same grid point appears twice:
%                     'error' (default), 'mean', 'first', 'last'.
%     'FillMissing' - what to do when grid points are missing:
%                     'error' (default), 'nearest', 'linear' (griddatan,
%                     points outside the convex hull filled by nearest).
%
%   [AXES, U, INFO] = ... also returns a struct with the number of
%   duplicate and missing points that were handled.

    opts = parse_options(varargin, struct( ...
        'Tolerance', 1e-9, 'Duplicates', 'error', 'FillMissing', 'error'));

    X = double(X);
    y = double(y(:));
    [M, N] = size(X);
    if numel(y) ~= M
        error('amesim_grid_from_columns:size', ...
              'X has %d rows but Y has %d values.', M, numel(y));
    end
    if any(~isfinite(X(:))) || any(~isfinite(y))
        error('amesim_grid_from_columns:nan', ...
              'Input data contains NaN/Inf. Clean the data first.');
    end

    % --- breakpoints of each axis and index of each row on that axis --------
    axesValues = cell(1, N);
    idx = zeros(M, N);
    n = zeros(1, N);
    for k = 1:N
        [axesValues{k}, idx(:, k)] = cluster_unique(X(:, k), opts.Tolerance);
        n(k) = numel(axesValues{k});
    end

    if N == 1
        lin = idx(:, 1);
    else
        sub = num2cell(idx, 1);
        lin = sub2ind(n, sub{:});
    end
    total = prod(n);

    % --- duplicates ----------------------------------------------------------
    counts = accumarray(lin, 1, [total 1]);
    nDup = sum(counts > 1);
    if nDup > 0
        switch lower(opts.Duplicates)
            case 'error'
                bad = find(counts > 1, 1);
                error('amesim_grid_from_columns:duplicates', ...
                      ['%d grid points appear more than once, e.g. at (%s). ' ...
                       'Use ''Duplicates'',''mean''/''first''/''last'' to accept them.'], ...
                      nDup, point_string(bad, n, axesValues));
            case 'mean'
                vals = accumarray(lin, y, [total 1]) ./ max(counts, 1);
            case 'first'
                [~, firstRow] = unique(lin, 'first');
                vals = zeros(total, 1);
                vals(lin(firstRow)) = y(firstRow);
            case 'last'
                [~, lastRow] = unique(lin, 'last');
                vals = zeros(total, 1);
                vals(lin(lastRow)) = y(lastRow);
            otherwise
                error('amesim_grid_from_columns:args', ...
                      'Unknown Duplicates option "%s".', opts.Duplicates);
        end
    else
        vals = zeros(total, 1);
        vals(lin) = y;
    end

    % --- missing points ------------------------------------------------------
    missing = counts == 0;
    nMissing = sum(missing);
    if nMissing > 0
        switch lower(opts.FillMissing)
            case 'error'
                bad = find(missing, 1);
                error('amesim_grid_from_columns:missing', ...
                      ['The data is not a full grid: %d of %d points are missing ' ...
                       '(axis sizes [%s]), e.g. (%s). Use ''FillMissing'',' ...
                       '''nearest'' or ''linear'' to interpolate them.'], ...
                      nMissing, total, num2str(n), point_string(bad, n, axesValues));
            case {'nearest', 'linear'}
                vals(missing) = fill_points(find(missing), n, axesValues, ...
                                            X, y, lower(opts.FillMissing));
            otherwise
                error('amesim_grid_from_columns:args', ...
                      'Unknown FillMissing option "%s".', opts.FillMissing);
        end
    end

    if N == 1
        U = vals;
    else
        U = reshape(vals, n);
    end
    info = struct('axisSizes', n, 'duplicatePoints', nDup, ...
                  'missingPoints', nMissing);
end

function [values, index] = cluster_unique(x, tol)
% Unique values of x, merging values closer than tol (relative to the range).
    [xs, order] = sort(x);
    scale = max(max(abs(xs)), 1);
    newGroup = [true; diff(xs) > tol * scale];
    groupId = cumsum(newGroup);
    values = accumarray(groupId, xs, [], @mean)';
    index = zeros(size(x));
    index(order) = groupId;
end

function v = fill_points(linMissing, n, axesValues, X, y, method)
    N = numel(n);
    sub = cell(1, N);
    [sub{:}] = ind2sub(n, linMissing(:));
    Q = zeros(numel(linMissing), N);
    for k = 1:N
        Q(:, k) = axesValues{k}(sub{k});
    end
    % Scale every axis to [0,1] so distances are comparable between axes.
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
    todo = isnan(v);
    if any(todo)
        % Nearest neighbour (also used for points outside the convex hull).
        for r = find(todo)'
            [~, j] = min(sum((Xs - Qs(r, :)).^2, 2));
            v(r) = y(j);
        end
    end
end

function s = point_string(linIdx, n, axesValues)
    N = numel(n);
    sub = cell(1, N);
    [sub{:}] = ind2sub(n, linIdx);
    parts = cell(1, N);
    for k = 1:N
        parts{k} = sprintf('X%d=%g', k, axesValues{k}(sub{k}));
    end
    s = strjoin(parts, ', ');
end

function opts = parse_options(args, opts)
    if mod(numel(args), 2) ~= 0
        error('amesim_grid_from_columns:args', 'Options must be name-value pairs.');
    end
    names = fieldnames(opts);
    for k = 1:2:numel(args)
        match = strcmpi(names, char(args{k}));
        if ~any(match)
            error('amesim_grid_from_columns:args', 'Unknown option "%s".', char(args{k}));
        end
        opts.(names{match}) = args{k+1};
    end
end
