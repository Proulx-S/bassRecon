function cropRange = manual_crop_range_v2(img)
    % img: 2D image
    sz = size(img);

    % Determine initial modes based on image size
    xEvenMode = (mod(sz(2), 2) == 0);
    yEvenMode = (mod(sz(1), 2) == 0);

    % Initial center position: center of image
    x = sz(2)/2;
    y = sz(1)/2;

    % Initial zoom: fits whole image
    zoom_w = round(sz(2) * 0.8);
    zoom_h = round(sz(1) * 0.8);

    % Minimum zoom window size
    min_w = 1;
    min_h = 1;

    % Create figure
    hFig = figure('MenuBar', 'none', 'ToolBar', 'none', 'Name', 'Manual Crop v2', 'KeyPressFcn', @keyPressCb, 'CloseRequestFcn', @cleanup);
    hAx  = axes('Parent', hFig);
    % Display image
    imagesc(abs(img), 'Parent', hAx); 
    axis(hAx, 'image');
    colormap(hAx, 'gray');
    hold(hAx, 'on');
    xlim(hAx, [1 sz(2)]);
    ylim(hAx, [1 sz(1)]);
    
    % Ensure figure has focus for key presses
    figure(hFig);

    % Instructions
    disp('Instructions for keyboard use:');
    disp(' Arrow keys - move center 10px (hold shift for 1px)');
    disp(' W/S - zoom vertically in/out 10px (hold shift for 2px)');
    disp(' A/D - zoom horizontally in/out 10px (hold shift for 2px)');
    disp(' X - toggle X-axis odd/even mode');
    disp(' Y - toggle Y-axis odd/even mode');
    disp(' Enter/Return - accept crop & exit');
    disp(' Esc/Q - cancel and exit');

    % Initial redraw to show title
    redraw();

    % State used in callback
    finished = false;
    quitflag = false;

    % Wait loop
    while ~finished && ishandle(hFig)
        pause(0.05); % Allow callbacks
    end

    if quitflag || ~ishandle(hFig)
        cropRange = [];
    else
        % Get final crop range
        rect = getZoomRect();
        cropRange = [rect(2), rect(2)+rect(4)-1; rect(1), rect(1)+rect(3)-1];
    end
    if ishandle(hFig)
        delete(hFig);
    end

    % --- Helper: Get current zoom rectangle [x y w h], keep in bounds
    function rect = getZoomRect()
        % Calculate bounds based on toggle modes
        % xEvenMode = true: even number of pixels (min 2)
        % xEvenMode = false: odd number of pixels (min 1)
        % Same for yEvenMode
        
        if xEvenMode
            % X even mode: use even number of pixels
            effective_w = max(zoom_w, 2);
            x1 = floor(x - effective_w/2) + 1;
            x2 = floor(x + effective_w/2);
        else
            % X odd mode: use odd number of pixels
            x1 = round(x - (zoom_w-1)/2);
            x2 = round(x + (zoom_w-1)/2);
        end
        
        if yEvenMode
            % Y even mode: use even number of pixels
            effective_h = max(zoom_h, 2);
            y1 = floor(y - effective_h/2) + 1;
            y2 = floor(y + effective_h/2);
        else
            % Y odd mode: use odd number of pixels
            y1 = round(y - (zoom_h-1)/2);
            y2 = round(y + (zoom_h-1)/2);
        end
        
        % Clamp to bounds
        if x1 < 1, x2 = x2 + (1-x1); x1 = 1; end
        if y1 < 1, y2 = y2 + (1-y1); y1 = 1; end
        if x2 > sz(2), x1 = x1 - (x2 - sz(2)); x2 = sz(2); end
        if y2 > sz(1), y1 = y1 - (y2 - sz(1)); y2 = sz(1); end
        % Still clamp
        x1 = max(1, x1); x2 = min(sz(2), x2);
        y1 = max(1, y1); y2 = min(sz(1), y2);
        rect = [x1 y1 x2-x1+1 y2-y1+1];
    end

    % --- Helper: Update view
    function redraw()
        % Get crop rectangle
        rect = getZoomRect();
        % Set axis to zoom window - ensure full pixels only
        xlim(hAx, [rect(1)-0.5, rect(1)+rect(3)-0.5]);
        ylim(hAx, [rect(2)-0.5, rect(2)+rect(4)-0.5]);
        % Update main cropRange variable
        cropRange = [rect(2), rect(2)+rect(4)-1; rect(1), rect(1)+rect(3)-1];
        nPixelsY = cropRange(1,2) - cropRange(1,1) + 1;
        nPixelsX = cropRange(2,2) - cropRange(2,1) + 1;
        % Add mode info for debugging
        xModeStr = 'even'; if ~xEvenMode, xModeStr = 'odd'; end
        yModeStr = 'even'; if ~yEvenMode, yModeStr = 'odd'; end
        titleStr = sprintf('Crop Range: Y[%d:%d] (%dpx) X[%d:%d] (%dpx) | X:%s Y:%s', ...
            cropRange(1,1), cropRange(1,2), nPixelsY, cropRange(2,1), cropRange(2,2), nPixelsX, xModeStr, yModeStr);
        title(hAx, titleStr, 'FontSize', 10, 'FontWeight', 'bold');
        drawnow;
    end

    % --- Callback for key press
    function keyPressCb(~, event)
        fprintf('Key pressed: %s\n', event.Key);
        m = event.Modifier;
        if any(strcmp(m,'shift'))
            % Fine control: 1 pixel movement, 2 pixel zoom
            moveStep = 1;
            zoomStepH = 2;
            zoomStepW = 2;
        else
            % Coarse control: larger steps
            moveStep = 10;
            zoomStepH = 10;
            zoomStepW = 10;
        end
        switch lower(event.Key)
            % CENTER MOVEMENT
            case 'uparrow'
                y = max(1, y-moveStep); 
                redraw();
            case 'downarrow'
                y = min(sz(1), y+moveStep); 
                redraw();
            case 'leftarrow'
                x = max(1, x-moveStep); 
                redraw();
            case 'rightarrow'
                x = min(sz(2), x+moveStep); 
                redraw();
            % ZOOM CONTROLS
            case 'w' % vertically zoom in (smaller h)
                if zoom_h - zoomStepH >= min_h
                    zoom_h = zoom_h - zoomStepH;
                    redraw();
                end
            case 's' % vertically zoom out (larger h)
                if zoom_h + zoomStepH <= sz(1)
                    zoom_h = zoom_h + zoomStepH;
                    redraw();
                end
            case 'a' % horizontally zoom in
                if zoom_w - zoomStepW >= min_w
                    zoom_w = zoom_w - zoomStepW;
                    redraw();
                end
            case 'd' % horizontally zoom out
                if zoom_w + zoomStepW <= sz(2)
                    zoom_w = zoom_w + zoomStepW;
                    redraw();
                end
            % MODE TOGGLES
            case 'x'
                if xEvenMode
                    x = x + 0.5;
                    zoom_w = zoom_w + 1;
                else
                    x = x - 0.5;
                    zoom_w = zoom_w - 1;
                end
                fprintf('X key pressed - before toggle: xEvenMode=%d\n', xEvenMode);
                xEvenMode = ~xEvenMode;
                xModeStr = 'even'; if ~xEvenMode, xModeStr = 'odd'; end
                fprintf('X mode changed to: %s (xEvenMode=%d)\n', xModeStr, xEvenMode);
                redraw();
                fprintf('After redraw call\n');
            case 'y'
                if yEvenMode
                    y = y + 0.5;
                    zoom_h = zoom_h + 1;
                else
                    y = y - 0.5;
                    zoom_h = zoom_h - 1;
                end
                fprintf('Y key pressed - before toggle: yEvenMode=%d\n', yEvenMode);
                yEvenMode = ~yEvenMode;
                yModeStr = 'even'; if ~yEvenMode, yModeStr = 'odd'; end
                fprintf('Y mode changed to: %s (yEvenMode=%d)\n', yModeStr, yEvenMode);
                redraw();
                fprintf('After redraw call\n');
            % ACCEPT/EXIT
            case {'return','enter'}
                finished = true;
            case {'escape','q'}
                finished = true;
                quitflag = true;
        end
    end

    % --- Cleanup: delete the figure if needed
    function cleanup(~,~)
        finished = true;
        delete(hFig);
    end

end
