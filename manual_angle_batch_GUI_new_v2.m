function manual_angle_batch(niftiPath)
% MANUAL_ANGLE_BATCH  Loop through every slice of a NIfTI volume with an
% interactive display. Before picking the angle point, the user can:
%   - Change the colormap in real time (slider)
%   - Switch between the ORIGINAL image and a black-and-white GRADIENT
%     (edge) image  -- only one is shown at a time
%   - Adjust brightness/contrast by Window/Level: hold-drag in the image,
%     left/right changes WINDOW (contrast), up/down changes LEVEL (brightness)
%
% Two mutually-exclusive interaction modes prevent conflicts:
%   [Window/Level ON]  -> dragging adjusts contrast/brightness
%   [Pick Point Mode]  -> the NEXT click records the angle point
%
% Progress is logged to manual_angles.xlsx after every slice, so an
% interrupted run resumes at the next unprocessed slice.
%
% USAGE:
%   manual_angle_batch('/path/to/volume.nii')
%   manual_angle_batch()   % prompts for a file

    % ---- Get the NIfTI file if not provided ----
    if nargin < 1 || isempty(niftiPath)
        [file, path] = uigetfile({'*.nii;*.nii.gz', 'NIfTI files'}, ...
            'Select NIfTI volume');
        if isequal(file, 0)
            error('No file selected.');
        end
        niftiPath = fullfile(path, file);
    end

    % ---- Load volume and find number of slices (3rd dimension) ----
    vol = niftiread(niftiPath);
    nSlices = size(vol, 3);

    % ---- Excel output file lives in the current working directory ----
    xlsxFile = fullfile(pwd, 'manual_angles.xlsx');

    % ---- Load existing progress, if any, to determine resume point ----
    if isfile(xlsxFile)
        T = readtable(xlsxFile);
        if ~isempty(T)
            startSlice = max(T.Slice) + 1;
        else
            startSlice = 1;
        end
    else
        T = table('Size', [0 2], 'VariableTypes', {'double', 'double'}, ...
            'VariableNames', {'Slice', 'Angle_deg'});
        startSlice = 1;
    end

    if startSlice > nSlices
        fprintf('All slices already processed (last slice %d of %d).\n', ...
            startSlice - 1, nSlices);
        return;
    end

    fprintf('Resuming at slice %d of %d.\n', startSlice, nSlices);

    % ---- Colormap list for the slider ----
    cmapList = {'gray','bone','hot','jet','parula','turbo','hsv','copper','pink','winter'};

    % ---- Loop through remaining slices one at a time ----
    for sliceIdx = startSlice:nSlices

        img = double(vol(:, :, sliceIdx));

        % Precompute the gradient (edge) image once for this slice
        [gx, gy] = gradient(img);
        gradImg  = sqrt(gx.^2 + gy.^2);

        % ---- Per-slice shared state ----
        S = struct();
        S.img       = img;
        S.gradImg   = gradImg;
        S.sliceIdx  = sliceIdx;
        S.nSlices   = nSlices;
        S.cmapList  = cmapList;
        S.cmapIdx   = 1;            % gray
        S.showGrad  = false;        % showing ORIGINAL image
        S.mode      = 'idle';       % 'wl' | 'pick' | 'idle'
        S.picked    = false;
        S.P1        = [NaN NaN];
        S.angleDiff = NaN;

        % Window/Level state for the ORIGINAL image
        lo = min(img(:));  hi = max(img(:));
        if hi <= lo, hi = lo + 1; end
        S.imgLevel  = (hi + lo) / 2;
        S.imgWindow = (hi - lo);

        % Window/Level state for the GRADIENT image (separate, so switching
        % back and forth preserves each one's contrast setting)
        glo = min(gradImg(:));  ghi = max(gradImg(:));
        if ghi <= glo, ghi = glo + 1; end
        S.gradLevel  = (ghi + glo) / 2;
        S.gradWindow = (ghi - glo);

        % Active window/level (points at whichever image is displayed)
        S.level  = S.imgLevel;
        S.window = S.imgWindow;
        S.win0   = S.window;
        S.lev0   = S.level;
        S.dragOrigin = [NaN NaN];
        S.dragging   = false;

        [rows, cols] = size(img);
        S.centerX = cols / 2;
        S.centerY = rows / 2;

        % ---- Build the figure ----
        fig = figure('Name', sprintf('Slice %d/%d', sliceIdx, nSlices), ...
            'NumberTitle', 'off', 'Color', [0.13 0.13 0.15], ...
            'Units', 'normalized', 'Position', [0.15 0.10 0.7 0.80]);

        ax = axes('Parent', fig, 'Units', 'normalized', ...
            'Position', [0.08 0.20 0.84 0.72]);

        % Single image handle -- CData is swapped between img and gradImg
        hImg = imagesc(ax, img);
        colormap(ax, cmapList{S.cmapIdx});
        axis(ax, 'image'); hold(ax, 'on');
        caxis(ax, [S.level - S.window/2, S.level + S.window/2]);

        % Center marker
        plot(ax, S.centerX, S.centerY, 'r+', 'MarkerSize', 12, 'LineWidth', 2);
        text(ax, S.centerX + 10, S.centerY, 'Center', 'Color', 'r', ...
            'FontWeight', 'bold');

        hTitle = title(ax, sprintf('Slice %d/%d - ORIGINAL image', ...
            sliceIdx, nSlices), 'Color', 'w', 'FontSize', 12);

        % Marker graphics for the picked point
        hP1 = plot(ax, NaN, NaN, 'go', 'MarkerSize', 9, 'LineWidth', 2);
        hP2 = plot(ax, NaN, NaN, 'bo', 'MarkerSize', 9, 'LineWidth', 2);
        hL1 = plot(ax, NaN, NaN, 'g-', 'LineWidth', 1.5);
        hL2 = plot(ax, NaN, NaN, 'b-', 'LineWidth', 1.5);

        % ================= UI CONTROLS =================

        % --- Colormap slider ---
        uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
            'Position', [0.08 0.115 0.11 0.028], ...
            'String', 'Colormap:', 'BackgroundColor', [0.13 0.13 0.15], ...
            'ForegroundColor', 'w', 'HorizontalAlignment', 'left', ...
            'FontWeight', 'bold', 'FontSize', 9);

        hCmapTxt = uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
            'Position', [0.19 0.115 0.13 0.028], ...
            'String', cmapList{S.cmapIdx}, ...
            'BackgroundColor', [0.13 0.13 0.15], ...
            'ForegroundColor', [1 0.85 0.35], 'HorizontalAlignment', 'left', ...
            'FontWeight', 'bold', 'FontSize', 9);

        hCmapSlider = uicontrol(fig, 'Style', 'slider', 'Units', 'normalized', ...
            'Position', [0.08 0.078 0.24 0.032], ...
            'Min', 1, 'Max', numel(cmapList), 'Value', 1, ...
            'SliderStep', [1/(numel(cmapList)-1), 1/(numel(cmapList)-1)]);

        % --- GRADIENT toggle: high-contrast amber (OFF) / bright cyan (ON) ---
        hGradBtn = uicontrol(fig, 'Style', 'togglebutton', 'Units', 'normalized', ...
            'Position', [0.345 0.072 0.155 0.058], ...
            'String', 'GRADIENT: OFF', 'FontWeight', 'bold', 'FontSize', 10, ...
            'BackgroundColor', [0.95 0.62 0.05], ...   % vivid amber
            'ForegroundColor', [0.08 0.05 0.00]);

        % --- Window/Level ON ---
        hWLon = uicontrol(fig, 'Style', 'pushbutton', 'Units', 'normalized', ...
            'Position', [0.515 0.072 0.135 0.058], ...
            'String', 'Window/Level: ON', 'FontWeight', 'bold', 'FontSize', 9, ...
            'BackgroundColor', [0.20 0.42 0.68], 'ForegroundColor', 'w');

        % --- Pick Point Mode (turns WL off) ---
        hWLoff = uicontrol(fig, 'Style', 'pushbutton', 'Units', 'normalized', ...
            'Position', [0.655 0.072 0.135 0.058], ...
            'String', 'Pick Point Mode', 'FontWeight', 'bold', 'FontSize', 9, ...
            'BackgroundColor', [0.22 0.55 0.32], 'ForegroundColor', 'w');

        % --- Reset contrast ---
        hResetBtn = uicontrol(fig, 'Style', 'pushbutton', 'Units', 'normalized', ...
            'Position', [0.795 0.072 0.125 0.058], ...
            'String', 'Reset Contrast', 'FontWeight', 'bold', 'FontSize', 9, ...
            'BackgroundColor', [0.45 0.36 0.28], 'ForegroundColor', 'w');

        % --- Confirm & Next ---
        hDoneBtn = uicontrol(fig, 'Style', 'pushbutton', 'Units', 'normalized', ...
            'Position', [0.795 0.010 0.125 0.055], ...
            'String', 'Confirm & Next', 'FontWeight', 'bold', 'FontSize', 9, ...
            'BackgroundColor', [0.60 0.25 0.25], 'ForegroundColor', 'w', ...
            'Enable', 'off');

        % --- Status bar ---
        hStatus = uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
            'Position', [0.08 0.010 0.70 0.050], ...
            'String', 'Mode: IDLE  |  Adjust display, then choose Window/Level or Pick Point Mode.', ...
            'BackgroundColor', [0.08 0.08 0.09], 'ForegroundColor', [0.75 0.95 0.75], ...
            'HorizontalAlignment', 'left', 'FontSize', 9);

        % ---- Stash handles/state ----
        H = struct('fig',fig,'ax',ax,'hImg',hImg, ...
            'hTitle',hTitle,'hP1',hP1,'hP2',hP2,'hL1',hL1,'hL2',hL2, ...
            'hCmapTxt',hCmapTxt,'hCmapSlider',hCmapSlider,'hGradBtn',hGradBtn, ...
            'hWLon',hWLon,'hWLoff',hWLoff,'hResetBtn',hResetBtn, ...
            'hDoneBtn',hDoneBtn,'hStatus',hStatus);
        setappdata(fig, 'S', S);
        setappdata(fig, 'H', H);

        % ---- Callbacks ----
        set(hCmapSlider, 'Callback', @(src,~) onCmap(fig, src));
        set(hGradBtn,    'Callback', @(src,~) onGradToggle(fig, src));
        set(hWLon,       'Callback', @(~,~) setMode(fig, 'wl'));
        set(hWLoff,      'Callback', @(~,~) setMode(fig, 'pick'));
        set(hResetBtn,   'Callback', @(~,~) onResetContrast(fig));
        set(hDoneBtn,    'Callback', @(~,~) uiresume(fig));

        set(fig, 'WindowButtonDownFcn',   @(~,~) onMouseDown(fig));
        set(fig, 'WindowButtonMotionFcn', @(~,~) onMouseMove(fig));
        set(fig, 'WindowButtonUpFcn',     @(~,~) onMouseUp(fig));

        % ---- Block until confirmed or closed ----
        uiwait(fig);

        if ~ishandle(fig)
            fprintf('Figure closed before confirming slice %d. Stopping.\n', sliceIdx);
            return;
        end

        S = getappdata(fig, 'S');

        if ~S.picked || isnan(S.angleDiff)
            choice = questdlg(sprintf(['No point was picked for slice %d.\n' ...
                'Skip this slice or stop?'], sliceIdx), ...
                'No Point', 'Skip', 'Stop', 'Skip');
            if ishandle(fig), close(fig); end
            if strcmp(choice, 'Stop'), return; else, continue; end
        end

        angleDiff = S.angleDiff;
        fprintf('Slice %d: angle = %.2f degrees\n', sliceIdx, angleDiff);

        if ishandle(fig), close(fig); end

        % ---- Append and save immediately ----
        newRow = table(sliceIdx, angleDiff, 'VariableNames', {'Slice', 'Angle_deg'});
        T = [T; newRow]; %#ok<AGROW>
        writetable(T, xlsxFile);
        fprintf('Saved slice %d angle to %s\n', sliceIdx, xlsxFile);
    end

    fprintf('All slices processed. Results saved in %s\n', xlsxFile);
end


% ========================================================================
%                          CALLBACK FUNCTIONS
% ========================================================================

function onCmap(fig, src)
% Change colormap in real time (only active for the ORIGINAL image).
    S = getappdata(fig, 'S');
    H = getappdata(fig, 'H');
    idx = round(get(src, 'Value'));
    idx = max(1, min(numel(S.cmapList), idx));
    set(src, 'Value', idx);
    S.cmapIdx = idx;
    if ~S.showGrad
        colormap(H.ax, S.cmapList{idx});
    end
    set(H.hCmapTxt, 'String', S.cmapList{idx});
    setappdata(fig, 'S', S);
end

% ------------------------------------------------------------------------
function onGradToggle(fig, src)
% Swap the displayed image between the ORIGINAL and the black-and-white
% GRADIENT. Only one is shown at any time.
    S = getappdata(fig, 'S');
    H = getappdata(fig, 'H');

    S.showGrad = logical(get(src, 'Value'));

    if S.showGrad
        % --- Save the original image's window/level, switch to gradient ---
        S.imgLevel  = S.level;
        S.imgWindow = S.window;
        S.level     = S.gradLevel;
        S.window    = S.gradWindow;

        set(H.hImg, 'CData', S.gradImg);
        colormap(H.ax, 'gray');                 % force black & white
        applyCLim(H.ax, S);

        % Bright cyan = clearly distinct from the dark GUI and from amber
        set(src, 'String', 'GRADIENT: ON', ...
            'BackgroundColor', [0.10 0.92 0.92], ...
            'ForegroundColor', [0.00 0.12 0.14]);

        % Colormap slider is irrelevant while gradient is shown
        set(H.hCmapSlider, 'Enable', 'off');
        set(H.hCmapTxt, 'String', 'gray (locked)', 'ForegroundColor', [0.55 0.55 0.55]);

        set(H.hTitle, 'String', sprintf('Slice %d/%d - GRADIENT (edge) image', ...
            S.sliceIdx, S.nSlices));

    else
        % --- Save the gradient's window/level, switch back to original ---
        S.gradLevel  = S.level;
        S.gradWindow = S.window;
        S.level      = S.imgLevel;
        S.window     = S.imgWindow;

        set(H.hImg, 'CData', S.img);
        colormap(H.ax, S.cmapList{S.cmapIdx});  % restore chosen colormap
        applyCLim(H.ax, S);

        set(src, 'String', 'GRADIENT: OFF', ...
            'BackgroundColor', [0.95 0.62 0.05], ...
            'ForegroundColor', [0.08 0.05 0.00]);

        set(H.hCmapSlider, 'Enable', 'on');
        set(H.hCmapTxt, 'String', S.cmapList{S.cmapIdx}, ...
            'ForegroundColor', [1 0.85 0.35]);

        set(H.hTitle, 'String', sprintf('Slice %d/%d - ORIGINAL image', ...
            S.sliceIdx, S.nSlices));
    end

    setappdata(fig, 'S', S);
end

% ------------------------------------------------------------------------
function setMode(fig, mode)
% Switch between Window/Level ('wl') and Pick-Point ('pick') modes.
    S = getappdata(fig, 'S');
    H = getappdata(fig, 'H');
    S.mode = mode;
    S.dragging = false;

    if S.showGrad, imgName = 'GRADIENT'; else, imgName = 'ORIGINAL'; end

    switch mode
        case 'wl'
            set(H.hWLon,  'BackgroundColor', [0.10 0.62 0.95]);
            set(H.hWLoff, 'BackgroundColor', [0.22 0.55 0.32]);
            set(H.hStatus, 'String', ...
                'Mode: WINDOW/LEVEL  |  Click-drag in image: left/right = contrast, up/down = brightness. (Point picking OFF.)', ...
                'ForegroundColor', [0.55 0.85 1]);
            set(H.hTitle, 'String', sprintf('Slice %d/%d - %s - WINDOW/LEVEL mode', ...
                S.sliceIdx, S.nSlices, imgName));
        case 'pick'
            set(H.hWLon,  'BackgroundColor', [0.20 0.42 0.68]);
            set(H.hWLoff, 'BackgroundColor', [0.15 0.85 0.40]);
            set(H.hStatus, 'String', ...
                'Mode: PICK POINT  |  Click once in the image to record the angle point. (Window/Level OFF.)', ...
                'ForegroundColor', [0.70 1 0.70]);
            set(H.hTitle, 'String', sprintf('Slice %d/%d - %s - PICK POINT: click once', ...
                S.sliceIdx, S.nSlices, imgName));
    end
    setappdata(fig, 'S', S);
end

% ------------------------------------------------------------------------
function onResetContrast(fig)
% Reset window/level of whichever image is currently displayed.
    S = getappdata(fig, 'S');
    H = getappdata(fig, 'H');
    if S.showGrad, D = S.gradImg; else, D = S.img; end
    lo = min(D(:)); hi = max(D(:));
    if hi <= lo, hi = lo + 1; end
    S.level  = (hi + lo) / 2;
    S.window = (hi - lo);
    applyCLim(H.ax, S);
    setappdata(fig, 'S', S);
end

% ------------------------------------------------------------------------
function onMouseDown(fig)
    S = getappdata(fig, 'S');
    H = getappdata(fig, 'H');

    cp = get(H.ax, 'CurrentPoint');
    x = cp(1,1); y = cp(1,2);
    xl = get(H.ax, 'XLim'); yl = get(H.ax, 'YLim');
    if ~(x >= xl(1) && x <= xl(2) && y >= yl(1) && y <= yl(2)), return; end

    switch S.mode
        case 'wl'
            S.dragging   = true;
            S.dragOrigin = [x, y];
            S.win0       = S.window;
            S.lev0       = S.level;
            setappdata(fig, 'S', S);
        case 'pick'
            recordPoint(fig, x, y);
    end
end

% ------------------------------------------------------------------------
function onMouseMove(fig)
    S = getappdata(fig, 'S');
    if ~strcmp(S.mode, 'wl') || ~S.dragging, return; end
    H = getappdata(fig, 'H');

    cp = get(H.ax, 'CurrentPoint');
    x = cp(1,1); y = cp(1,2);

    if S.showGrad, D = S.gradImg; else, D = S.img; end
    [rows, cols] = size(D);

    dx = (x - S.dragOrigin(1)) / cols;   % left/right -> window (contrast)
    dy = (y - S.dragOrigin(2)) / rows;   % up/down    -> level  (brightness)

    fullRange = max(D(:)) - min(D(:));
    if fullRange <= 0, fullRange = 1; end

    newWindow = S.win0 + dx * fullRange * 2;
    newLevel  = S.lev0 - dy * fullRange * 2;

    S.window = max(fullRange * 0.005, newWindow);
    S.level  = newLevel;

    applyCLim(H.ax, S);

    set(H.hStatus, 'String', sprintf(...
        'Mode: WINDOW/LEVEL  |  Window (contrast): %.2f   Level (brightness): %.2f', ...
        S.window, S.level), 'ForegroundColor', [0.55 0.85 1]);

    setappdata(fig, 'S', S);
end

% ------------------------------------------------------------------------
function onMouseUp(fig)
    S = getappdata(fig, 'S');
    if strcmp(S.mode, 'wl') && S.dragging
        S.dragging = false;
        setappdata(fig, 'S', S);
    end
end

% ------------------------------------------------------------------------
function applyCLim(ax, S)
    lo = S.level - S.window/2;
    hi = S.level + S.window/2;
    if hi <= lo, hi = lo + 1; end
    caxis(ax, [lo hi]);
end

% ------------------------------------------------------------------------
function recordPoint(fig, x, y)
    S = getappdata(fig, 'S');
    H = getappdata(fig, 'H');

    S.P1 = [x, y];

    P1_x = x;          P1_y = y;
    P2_x = S.centerX;  P2_y = y;

    set(H.hP1, 'XData', P1_x, 'YData', P1_y);
    set(H.hP2, 'XData', P2_x, 'YData', P2_y);
    set(H.hL1, 'XData', [S.centerX P1_x], 'YData', [S.centerY P1_y]);
    set(H.hL2, 'XData', [S.centerX P2_x], 'YData', [S.centerY P2_y]);

    vec1_x = P1_x - S.centerX;  vec1_y = P1_y - S.centerY;
    vec2_x = P2_x - S.centerX;  vec2_y = P2_y - S.centerY;

    angle1_deg = atan2d(vec1_y, vec1_x);
    angle2_deg = atan2d(vec2_y, vec2_x);

    angleDiff = abs(angle1_deg - angle2_deg);
    if angleDiff > 180
        angleDiff = 360 - angleDiff;
    end

    S.angleDiff = angleDiff;
    S.picked    = true;

    set(H.hTitle, 'String', sprintf('Slice %d/%d - Angle: %.2f deg  (click again to re-pick)', ...
        S.sliceIdx, S.nSlices, angleDiff));
    set(H.hStatus, 'String', sprintf(...
        'Point recorded. Angle = %.2f deg. Click again to re-pick, or press Confirm & Next.', ...
        angleDiff), 'ForegroundColor', [1 1 0.6]);
    set(H.hDoneBtn, 'Enable', 'on');

    setappdata(fig, 'S', S);
end