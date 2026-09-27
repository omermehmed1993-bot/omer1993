function [axesValues, U, meta] = amesim_read_table(filename)
%AMESIM_READ_TABLE Read an Amesim 1D, 2D or ND (up to 8D) ASCII table.
%
%   [AXES, U, META] = amesim_read_table(FILENAME) returns the breakpoint
%   vectors in the cell array AXES, the values as an N-D array U of size
%   [numel(AXES{1}) ... numel(AXES{N})], and META with the fields
%   'format', 'tableUnit', 'axisUnits' and 'comments'.
%
%   Used to check files written by amesim_write_table, but it reads any
%   Amesim file in the 1D / 2D / 3D ... 8D regular-mesh formats.

    text = fileread(filename);
    lines = regexp(text, '\r?\n', 'split');

    meta = struct('format', '', 'tableUnit', '', 'axisUnits', {{}}, ...
                  'comments', {{}});
    numbers = {};
    for k = 1:numel(lines)
        line = strtrim(lines{k});
        if isempty(line)
            continue
        end
        if line(1) == '#'
            body = strtrim(line(2:end));
            tok = regexp(body, '^Table format:\s*(\S+)', 'tokens', 'once', 'ignorecase');
            if ~isempty(tok)
                meta.format = upper(tok{1});
                continue
            end
            tok = regexp(body, '^table_unit\s*=\s*(.*)$', 'tokens', 'once');
            if ~isempty(tok)
                meta.tableUnit = strtrim(tok{1});
                continue
            end
            tok = regexp(body, '^axis(\d+)_unit\s*=\s*(.*)$', 'tokens', 'once');
            if ~isempty(tok)
                meta.axisUnits{str2double(tok{1})} = strtrim(tok{2});
                continue
            end
            meta.comments{end+1} = body;
            continue
        end
        numbers{end+1} = line; %#ok<AGROW>
    end

    values = sscanf(strjoin(numbers, ' '), '%f');

    fmt = regexp(meta.format, '^(\d)D$', 'tokens', 'once');
    if isempty(fmt)
        error('amesim_read_table:format', ...
              'Unsupported or missing "# Table format:" header ("%s").', meta.format);
    end
    N = str2double(fmt{1});

    if N == 1
        if mod(numel(values), 2) ~= 0
            error('amesim_read_table:data', '1D table has an odd number of values.');
        end
        xy = reshape(values, 2, [])';
        axesValues = {xy(:, 1)'};
        U = xy(:, 2);
        return
    end

    if numel(values) < N
        error('amesim_read_table:data', 'File ends before the axis sizes.');
    end
    n = values(1:N)';
    if any(n < 1) || any(n ~= round(n))
        error('amesim_read_table:data', 'Invalid axis sizes [%s].', num2str(n));
    end
    expected = N + sum(n) + prod(n);
    if numel(values) ~= expected
        error('amesim_read_table:data', ...
              'Expected %d numbers for a [%s] table, found %d.', ...
              expected, num2str(n), numel(values));
    end

    pos = N;
    axesValues = cell(1, N);
    for k = 1:N
        axesValues{k} = values(pos + (1:n(k)))';
        pos = pos + n(k);
    end
    U = reshape(values(pos+1:end), n);
end
