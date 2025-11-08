function success = multiCropVideos()

%multiCropVideos Detects arenas, allows user to move ROIs, creates a movie
%for each ROI
%   If run without any inputs, user will be asked to select a folder
%   containing the movies to split and subMovies will be created



%% Ask user to select movies to crop
% The movies should have similar number of chambers and placement of
% chambers.

% Prompt the user to select a folder
folderPath = uigetdir(pwd, 'Select a folder containing movies files');

% Check if the user canceled the folder selection
if folderPath == 0
    disp('Folder selection cancelled.');
    return;
end

% Get a list of all mp4 files in the selected folder
movieFiles = dir(fullfile(folderPath, '*.mp4'));

% Create a cell array with full paths of the mp4 files
moviePaths = fullfile({movieFiles.folder}, {movieFiles.name});

%% pre-allocate variables
data.vinfo = []; %change to vidobj
data.movieFile = [];
data.moviePath = [];
data.n_chambers = [];
data.chamber_diam = [];
data.chamber_config = [];
data.img = [];
data.bg_mean = [];
data.ppm = [];
data.centers = [];
data.r = [];
data.rectROIs = [];
data.rectPositions = [];

%% Create background image and ask user to pixels per mm
for i = 1:length(moviePaths) %loop through movies


    % open movie
    % try with VideoReader (more stable)
    %vinfo = VideoReader(moviePaths{i});
    % if that fails, try video_open
    vinfo = video_open(moviePaths{i});
    data(i).vinfo = vinfo;
    data(i).movieFile = vinfo.vidobj.Name;
    data(i).moviePath = vinfo.vidobj.Path;

    if i == 1
        % Ask user to calibrate pixels per mm with ruler
        % show image
        img = video_read_frame(vinfo,floor(vinfo.n_frames/2));
        data(i).img = img;
        figure, imshow(img);
        title('Draw line and double-click when done')

        % Let user draw a line
        h = drawline();

        % Get line coordinates
        pos = h.Position;  % pos is a 2x2 matrix: [x1 y1; x2 y2]

        % Ask user length of ruler in mm
        prompt = {'Enter the real-world length of the line (in mm):'};
        dlgtitle = 'Calibrate Scale';
        dims = [1 50];
        definput = {'10'};  % default value
        answer = inputdlg(prompt, dlgtitle, dims, definput);

        % Convert string input to numeric
        if isempty(answer)
            error('User cancelled the input dialog.');
        end
        length_mm = str2double(answer{1});

        % Check for valid number
        if isnan(length_mm) || length_mm <= 0
            error('Invalid input. Please enter a positive number.');
        end

        % Calculate length & pixels per mm
        dx = pos(2,1) - pos(1,1);
        dy = pos(2,2) - pos(1,2);
        length_px = sqrt(dx^2 + dy^2);

        % Calculate scale
        ppm = length_px / length_mm;
        data(i).ppm = ppm;

        % Ask user for number of chambers and size of each chamber in mm
        prompt = {'Number of chambers:', 'Chamber size (diameter in mm):',...
            'Rows:','Columns:'};
        dlgtitle = 'Chamber Configuration';
        dims = [1 50];
        definput = {'4', '16','2','2'};  % Default values: 2 chamber, 5 mm diameter
        answer = inputdlg(prompt, dlgtitle, dims, definput);

        % Check if user canceled
        if isempty(answer)
            error('User cancelled the input dialog.');
        end

        % Parse user input
        n_chambers = str2double(answer{1});
        chamber_diam = str2double(answer{2});
        ch_rows = str2double(answer{3});
        ch_cols = str2double(answer{4});

        % Validate n_chambers & ch_rows v ch_cols
        if isnan(n_chambers) || n_chambers <= 0 || mod(n_chambers,1) ~= 0
            error('Invalid number of chambers.');
        end
        if ch_rows * ch_cols ~= n_chambers
            error('Invalid number of chambers, row, or columns')
        end

        data(i).n_chambers = n_chambers;

        % Validate chamber_diam
        if isnan(chamber_diam) || chamber_diam <= 0
            error('Invalid chamber size.');
        end

        % convert chamber_diam to radius in pixels
        r = ceil((chamber_diam * ppm)/2);
        r = 8 * ceil(r/8); % make sure that diameter will be multiple of 16 for video writing

        data(i).chamber_diam = chamber_diam;
        data(i).chamber_config = [ch_rows ch_cols];
        data(i).r = r;

        close all;
    else
        img = video_read_frame(vinfo,floor(vinfo.n_frames/2));
        data(i).img = img;
        data(i).ppm = data(1).ppm;
        data(i).n_chambers = data(1).n_chambers;
        data(i).chamber_diam = data(1).chamber_diam;
        data(i).chamber_config = data(1).chamber_config;
        data(i).r = data(1).r;
    end

    % Shape of chambers
    chamber_shape = 'circular';


    % Autodetect chambers

    % get background image
    bg = calib_bg_estimate(vinfo, ppm);
    data(i).bg_mean = bg.bg_mean;

    % detect chambers
    [centers, ~, ~, ~] = calib_chamber_detect(bg, n_chambers); %centers = [y x];
    % centers = [y,x]!

    % make sure width is in a multiple of 4 for proper video writing
    r = data(i).r;
    
    if size(centers,1) ~= n_chambers
    % if number of centers doesn't match number of chambers, just create x
    % number of ROIs for user to move

    % space between squares (corresponds to upper left corner of first
    % row,col
    imgW = size(img,2); % width
    imgH = size(img,1); % height
    x_gap = (imgW-(2 * r * ch_cols))/(ch_cols+1); 
    y_gap = (imgH-(2 * r * ch_rows))/(ch_rows+1); 
    
    xCenters = linspace(x_gap+r,imgW-x_gap-r,ch_cols);
    yCenters = linspace(y_gap+r,imgH-y_gap-r,ch_rows);

    [X,Y] = meshgrid(xCenters,yCenters);
    centers = [Y(:),X(:)];
    end


    % sort centers
    sorted_centers = sortcenters(centers,data(i).chamber_config(1),data(i).chamber_config(2));
    data(i).centers = sorted_centers;

    
    % convert to rectangles
    % calculate top-left corner
    rect_x = sorted_centers(:,2) - r;
    rect_y = sorted_centers(:,1) - r;

    % calculate rectangle ROI positions [x_min y_min width heigth]
    rectROIs = [rect_x, rect_y, repmat(r*2,[n_chambers,1]), repmat(r*2,[n_chambers,1])];

    % make sure that all ROIs are within movie frame, if not move
    imgHeight = data(i).vinfo.vidobj.Height;
    imgWidth = data(i).vinfo.vidobj.Width;

    for iROI = 1:n_chambers
        % check that chamber doesn't exceed
rectROIs(iROI,:) = keepROIinBounds(rectROIs(iROI,:), imgWidth, imgHeight);
    end

    data(i).rectROIs = rectROIs;

    % To add: adjust position of ROI if they go off side of movie

    % show background image
    fig = figure('Name', sprintf('Movie %d', i), ...
        'NumberTitle', 'off', ...
        'KeyPressFcn', @(~, event) ...
        strcmp(event.Key, 'return') && uiresume(fig));  % Press Enter to continue

    imshow(data(i).img);
    title('Drag rectangles into place. Press Enter or close window to continue.');

    % Initialize storage for rectangle objects and their positions
    rectHandles = gobjects(n_chambers,1);
    rectPositions = zeros(n_chambers,4);

    for c = 1:n_chambers
        %draw draggable rectagles
        rectHandles(c) = drawrectangle('Position', rectROIs(c,:), ...
            'Color', 'm', ...
            'LineWidth', 2, ...
            'Label',num2str(c),...
            'DrawingArea',[1, 1, data(i).vinfo.sy, data(i).vinfo.sx],...
            'InteractionsAllowed', 'translate');


        % Store initial position
        rectPositions(c, :) = rectHandles(c).Position;

        % Add listener to track position changes
        addlistener(rectHandles(c), 'ROIMoved', @(src, evt) onRectMove(src, c));
        %disp(['Listener added for rectangle ', num2str(c)]);
    end

    uiwait(fig);  % Waits for user to press Enter or close the figure

    if isvalid(fig)
        close(fig);
    end

    data(i).rectROIs = rectROIs;
    data(i).rectPositions = rectPositions;

end

%% Crop videos
for i = 1:length(data)

    % params
    max_file_length = 255;
    nSubVideos=(data(i).n_chambers); % total number of coordinates vectors
    inVideoPath = data(i).moviePath;
    videoName = data(i).movieFile;
    % video ext
    [~,videoName,videoExt] = fileparts(videoName);

    % out videos
    outVideoPath = inVideoPath; % default. Can be added as option later
    outVideos=cell(1,nSubVideos); % outVideo Names
    ObjOutVideo = cell(1,nSubVideos); % outVideo obj for videoWriter

    % Video info from VideoReader
    ObjInVideo = data(i).vinfo.vidobj;
    nFrames=ObjInVideo.NumberOfFrames;

    % format for outVideos
    switch videoExt
        case '.mp4'
            writerProfile = 'MPEG-4';
            outputExt = '.mp4';

        case '.avi'
            writerProfile = 'Motion JPEG AVI';
            outputExt = '.avi';

        otherwise
            error('Unsupported file format: %s', videoExt);
    end

    %% Generate outVideo Names and objects
    for iSubVid = 1:nSubVideos

        % outVideo Name
        outVideos{iSubVid}=fullfile(outVideoPath,[videoName '_CH' num2str(iSubVid) outputExt]);

        % shorten name if over max_file_length
        if length(outVideos{iSubVid})>max_file_length
            [~,oldName,ext] = fileparts(outVideos{iSubVid});
            newName = regexprep(oldName, '_\d{4}_\d{2}_\d{2}T\d{2}_\d{2}_\d{2}', '');
            outVideos{iSubVid}=fullfile(outVideoPath,[newName ext]);
        end

        % Open VideoWriter object
        ObjOutVideo{iSubVid} = VideoWriter(outVideos{iSubVid}, writerProfile);
        ObjOutVideo{iSubVid}.FrameRate=ObjInVideo.FrameRate;
        ObjOutVideo{iSubVid}.Quality = 100;
        open(ObjOutVideo{iSubVid});

    end

    % Get positions of ROIs
    rectPosCell = data(i).rectPositions;

    %% Write Video
    % Status
    % fprintf('\nVideo %s slising to parts started: %s \n', [videoName, videoExt],...
    %     datestr(now,'dd-mmm-yyyy HH:MM:SS'));

    % videocrop_tic=tic;
    h = waitbar(0, 'Starting...', 'Name', ['Processing: ', videoName]);

    % Write subVideos
    for frame_ind = 1 : nFrames % loop through all frames
        currFrame=read(ObjInVideo, frame_ind);
        for iSubVid=1:nSubVideos % Crop all sub videos from each frame and store them.
            % This way we read input movie only once. Assuming written movies volume sum
            % is smaller the read movie volume, this ordering should be slightly faster.
            % in case of overlaping regions, changing loops orders may be better option.
            posVec=rectPosCell(iSubVid,:);
            xmin = floor(posVec(1)); ymin = floor(posVec(2)); width = ceil(posVec(3)); height = ceil(posVec(4));
            subFrame = currFrame(ymin:ymin+height-1, xmin:xmin+width-1,:);

            %write frame
            writeVideo(ObjOutVideo{iSubVid}, subFrame);

        end % for iSubMovie=1:nSubVideos % cut out all sub videos from each frame, and save

        % Update waitbar every frame or every N frames (e.g., 100)
        if ~rem(frame_ind, 100)
            waitbar(frame_ind / nFrames, h, ...
                sprintf('Processing frame %d of %d', frame_ind, nFrames));
        end

        % % Optional console update
        % if ~rem(frame_ind,100)
        %     fprintf('\nVideo %s progress: %s / %s \n', videoName, ...
        %         num2str(frame_ind), num2str(nFrames));
        % end

    end % for frame_ind = 1 : nFrames % loop through all frames


    %close(h);
    for iSubVid=1:nSubVideos % close all video objects
        close(ObjOutVideo{iSubVid});
    end

    close(h);  % Close waitbar when done

end %loop through movies to process

%% Callback functions
% Callback function to record new rectangle positions
    function onRectMove(src, idx)
        rectPositions(idx, :) = src.Position;
        % fprintf('Rectangle %d moved to [%.2f, %.2f, %.2f, %.2f]\n', ...
        %     idx, rectPositions(idx, :));
    end
end

%% Additional functions

function sorted_centers = sortcenters(centers, nRows, nCols)
% centers: Mx2 matrix of [y x] coordinates
% nRows: number of rows in grid
% nCols: number of columns in grid

    if size(centers,1) ~= nRows * nCols
        error('Number of centers does not match the specified grid size (%d x %d)', nRows, nCols);
    end

    % Step 1: Sort by y-coordinate to group by rows
    [~, y_idx] = sort(centers(:,1));
    centers_sorted_y = centers(y_idx, :);

    sorted_centers = zeros(size(centers));

    % Step 2: For each row, sort by x-coordinate
    for r = 1:nRows
        row_idx = (r-1)*nCols + 1 : r*nCols;
        row_centers = centers_sorted_y(row_idx, :);
        
        [~, x_idx] = sort(row_centers(:,2));  % sort by x within the row
        sorted_centers(row_idx, :) = row_centers(x_idx, :);
    end
end

function adjustedPos = keepROIinBounds(pos, imgWidth, imgHeight)
    x = pos(1); y = pos(2); w = pos(3); h = pos(4);

    % Ensure rectangle stays inside the image by adjusting position (not size)
    if x < 1
        x = 1;
    elseif (x + w - 1) > imgWidth
        x = imgWidth - w + 1;
    end

    if y < 1
        y = 1;
    elseif (y + h - 1) > imgHeight
        y = imgHeight - h + 1;
    end

    adjustedPos = [x, y, w, h];
end