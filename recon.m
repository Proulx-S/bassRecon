function [outName,img] = recon(datFile,datNoiseFile,datPhaseFile,coilMethod,cropRange,verbose,force)

if ~exist('cropRange','var'); cropRange = []; end
if isempty(cropRange);        cropRange =  0; end
if ~exist('coilMethod','var'); coilMethod = ''; end
if isempty(coilMethod);        coilMethod =  'bartEspirit'; end
if ~exist('verbose','var'); verbose = ''; end
if isempty(verbose);        verbose =  0; end
if ~exist('force','var'); force = []; end
if isempty(force);        force =  false; end

datPhaseFlag = false;
if (~exist('datFile','var')      ||  isempty(datFile)     ) && ...
   (~exist('datNoiseFile','var') ||  isempty(datNoiseFile)) && ...
   (exist('datPhaseFile','var')  && ~isempty(datPhaseFile))
   datPhaseFlag = true;
   datFile      = datPhaseFile;
end
        
%%%%%%%%%%%%%%%
%% Dependencies
%%%%%%%%%%%%%%%
toolDir = fileparts(fileparts(mfilename('fullpath')));
% BART
if strcmp(coilMethod,'bartEspirit')
    % matlab wrapper
    tool = 'bart-matlab'; repoURL = 'https://github.com/mrirecon/bart.git'; repoSubDir = 'matlab'; branch = '';
    gitClone(repoURL, fullfile(toolDir, tool), repoSubDir, branch);
    % binaries
    setenv('TOOLBOX_PATH', '/home/sebp/neurocommand/neurodesk/containers/bart_0.9.00_20240723');
    setenv('PATH', [getenv('PATH') ':/home/sebp/neurocommand/neurodesk/containers/bart_0.9.00_20240723']);
end

tool = 'HotellingT2'; repoURL = 'https://www.mathworks.com/matlabcentral/mlc-downloads/downloads/submissions/2844/versions/1/download/zip';
mathworksClone(repoURL, fullfile(toolDir, tool));
%% %%%%%%%%%%%%




outNameTmp = replace(datFile,'.dat','.mat');
if ~exist(outNameTmp,'file') || force

    datFile;
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% Frame-by-frame reconstruction
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    
    % Check if input file exists
    if                                                          ~exist(datFile     , 'file'); error('File does not exist: %s', datFile     ); end
    if exist('datNoiseFile','var') && ~isempty(datNoiseFile) && ~exist(datNoiseFile, 'file'); error('File does not exist: %s', datNoiseFile); end
    if exist('datNoiseFile','var') && ~isempty(datNoiseFile) && ~exist(datNoiseFile, 'file'); error('File does not exist: %s', datNoiseFile); end
    if exist('datPhaseFile','var') && ~isempty(datPhaseFile) && ~exist(datPhaseFile, 'file'); error('File does not exist: %s', datPhaseFile); end
    [~, datFileName, datFileExt] = fileparts(datFile); datFileName = [datFileName datFileExt]; 

    % Map the twix file
    disp(['Mapping ' datFileName ' mapping...']);
    twixobj = mapVBVD(datFile);
    disp(['Mapping ' datFileName ' done.']);
    
    % Format from twix
    % [1-Columns   x  2-Channels/Coils x  3-Lines       x  4-Partitions      x  5-Slices    x  6-Averages          x  7-(Cardiac-) Phases  x  8-Contrasts/Echoes  x  9-Measurements  x  10-Sets        x  11-Segments     x  12-Ida               x  13-Idb        x  14-Idc           x  15-Idd      x  16-Ide                      ] (see mapVBVD.m)
    % to bart
    % [1-READ_DIM  x  2-PHS1_DIM       x  3-PHS2_DIM    x  4-COIL_DIM        x  5-MAPS_DIM  x  6-TE_DIM            x  7-COEFF_DIM          x  8-COEFF2_DIM        x  9-ITER_DIM      x  10-CSHIFT_DIM  x  11-TIME_DIM     x  12-TIME2_DIM         x  13-LEVEL_DIM  x  14-SLICE_DIM     x  15-AVG_DIM  x  16-BATCH_DIM                ] (see https://github.com/mrirecon/bart/blob/master/src/misc/mri.h)
    % Twix reordered:
    % [1-Columns   x  3-Lines          x  4-Partitions  x  2-Channels/Coils  x  12-Ida      x  8-Contrasts/Echoes  x  10-Sets              x  13-Idb              x  14-Idb          x  15-Idb         x  9-Measurements  x  7-(Cardiac-) Phases  x  17            x  5-Slices         x  6-Averages  x  16-Idb        x  11-Segments] (see mapVBVD.m)
    % [1 3 4 2 12 8 10 13 14 15 9 7 17 5 6 16 11]

    % Initialize image and coil sensitivity arrays
    img           = complex(zeros([twixobj{1,2}.hdr.Config.ImageColumns twixobj{1,2}.image.NLin 1 twixobj{1,2}.image.NCha 1 1 twixobj{1,2}.image.NSet 1 1 1 twixobj{1,2}.image.NRep 1 1 1 1 1]));
    switch coilMethod
        case 'bartEspirit'
            kCoil = complex(zeros([twixobj{1,2}.hdr.Config.ImageColumns twixobj{1,2}.image.NLin 1 twixobj{1,2}.image.NCha 1 1                       1 1 1 1 twixobj{1,2}.image.NRep 1 1 1 1 1]));
        otherwise
            error('Invalid coil method: %s', coilMethod);
    end
    sz = twixobj{1,2}.image.dataSize;
    sz(3) = twixobj{1,2}.hdr.Config.ImageLines - twixobj{1,2}.image.NLin;
    sz([9 11]) = 1;

    % Recon frame-by-frame
    disp(['Recon ' datFileName '. Doing...']);
    parfor irep = 1:twixobj{1,2}.image.NRep
        % Get k-space data
        % 1) load single image data, 2) pad k-space lines to image-space lines, 3) resolve freq encode oversampling, 4) permute to match bart format --- single line for efficiency
        kdata = mrir_fDFT_freqencode(mrir_image_crop(mrir_fDFT_freqencode(...
            permute(cat(3,sum(twixobj{1,2}.image(:,:,:,:,:,:,:,:,irep,:,:,:),11),zeros(sz)),[1 3 4 2 12 8 10 13 14 15 9 7 17 5 6 16 11]))));
        % 5) adjust to phase resolution
        kdata = kdata(:,1:twixobj{1,2}.image.NLin,:,:,:,:,:);

        % Get coil data (first set for the velocity compensated acquisition in phase contrast data; probably also first set for anything else)
        set = 1;
        switch coilMethod
            case 'bartEspirit'
                % Accumulate kdata for later coil sensitivity map (velocity compensated set)
                kCoil(:,:,:,:,:,:,:,:,:,:,irep,:,:,:,:,:) =      kdata(:,:,:,:,:,:,set,:,:,:,:,:,:,:,:,:);
            otherwise
                error('Invalid coil method: %s', coilMethod);
        end

        % Reconstruct with simple FFT (fully sampled k-space only)
        img(:,:,:,:,:,:,:,:,:,:,irep,:,:,:,:,:) = ifft2c(kdata);    
    end
    % Average coil data over time
    kCoil = mean(kCoil,11);

    disp(['Recon ' datFileName '. Done.']);
    %% %%%%%%%%%%%%%%%%%%%%%%%%
    img;
    kCoil;

    % % Look at Siemens noise data
    % figure;
    % coil = 1;
    % rep  = 1;
    % imagesc(abs(squeeze(twixobj{1,1}.noise(:,coil,:,:,:,rep)))); axis image off; colormap gray; drawnow;
    % imagesc(angle(squeeze(twixobj{1,1}.noise(:,coil,:,:,:,rep)))); axis image off; colormap hsv; drawnow;
    % figure;
    % rho = corr( permute(reshape(permute(twixobj{1,1}.noise(:,:,:,:,:,rep),[2 1 3 4 5 6]),[twixobj{1,1}.noise.dataSize(2) prod(twixobj{1,1}.noise.dataSize([1 3])) 1 1 1]),[2 1 3 4 5]) );
    % imagesc(rho.*conj(rho)); axis image off; drawnow; colorbar

    % %% Recon with GRAPPA
    % % 1) reconstruct non-sampled k-space points, 2) fft to image space, 3) permute to match bart format --- single line for efficiency
    % grappaImg = permute(...
    %     ifft2c(GRAPPA(permute(kdata,[1 2 4 3]),permute(kcalib(64-17:64+18,64-17:64+18,:,:),[1 2 4 3]),[5,5],1e-2,0))    ,[1 2 4 3]);
    % figure('MenuBar','none','ToolBar','none');
    % imagesc(abs(grappaImg(:,:,1))); colormap gray; axis image; drawnow;

    kCoil;
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% Compute coil sensitivity/phase map
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    display(['Coil sensitivity/phase map (' coilMethod '). Computing...']);
    switch coilMethod
        case 'bartEspirit' % ESPIRIT
            iCoil = bart('ecalib -m1', kCoil);
        otherwise
            error('Invalid coil method: %s', coilMethod);
    end
    display(['Coil sensitivity/phase map (' coilMethod '). Done.']);
    %% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    iCoil;


    img;
    iCoil;
    %%%%%%%%%%%%%%%%
    %% Combine coils
    %%%%%%%%%%%%%%%%
    display(['Coil combination (' coilMethod '). Doing...']);
    % plot before
    if verbose>1
        s = 1;
        f = {};
        nRows = floor(size(iCoil,4)/ceil(sqrt(size(iCoil,4))));
        nCols = ceil(size(iCoil,4)/nRows);

        f{end+1} = figure;
        ht = tiledlayout(nRows,nCols); ht.TileSpacing = 'compact'; ht.Padding = 'compact'; ht.TileIndexing = 'columnmajor'; ax = {};
        for k = 1:size(iCoil,4)
            ax{end+1} = nexttile;
            imagesc(angle(mean(img(:,:,:,k,:,:,s,:,:,:,:),11)),[-pi pi]); axis image off; colormap(ax{end},hsv); drawnow;
        end
        title(ht,'original phase map from each coil')

        phaseMap = exp(1i.*angle(mean(img(:,:,:,:,:,:,s,:,:,:,:),[4 11])));

        f{end+1} = figure;
        ht = tiledlayout(nRows,nCols); ht.TileSpacing = 'compact'; ht.Padding = 'compact'; ht.TileIndexing = 'columnmajor'; ax = {};
        for k = 1:size(iCoil,4)
            ax{end+1} = nexttile;
            imagesc(angle(mean(img(:,:,:,k,:,:,s,:,:,:,:).*conj(phaseMap),11)),[-pi pi]); axis image off; colormap(ax{end},hsv); drawnow;
        end
        title(ht,'original phase map from each coil after subtracting the phase map of the coil-averaged image')

        f{end+1} = figure;
        ht = tiledlayout(nRows,nCols); ht.TileSpacing = 'compact'; ht.Padding = 'compact'; ht.TileIndexing = 'columnmajor'; ax = {};
        for k = 1:size(iCoil,4)
            ax{end+1} = nexttile;
            imagesc(angle(mean(iCoil(:,:,:,k,:,:,s,:,:,:,:),11)),[-pi pi]); axis image off; colormap(ax{end},hsv); drawnow;
        end
        title(ht,'phase of bart''s coil sensitivity map')
    end

    % multiply by coil sensitivity, remove coil phase and average across coils
    img = sum( img .* conj(iCoil) ,4);

    % plot after
    if verbose>1
        f{end+1} = figure;
        ht = tiledlayout(nRows,nCols); ht.TileSpacing = 'compact'; ht.Padding = 'compact'; ht.TileIndexing = 'columnmajor'; ax = {};
        for k = 1:size(iCoil,4)
            ax{end+1} = nexttile;
            imagesc(angle(mean(img(:,:,:,k,:,:,s,:,:,:,:).*conj(iCoil(:,:,:,k)),11)),[-pi pi]); axis image off; colormap(ax{end},hsv); drawnow;
        end
        title(ht,'bart-corrected phase map from each coil')

        phaseMap = exp(1i.*angle(mean(img(:,:,:,:,:,:,s,:,:,:,:).* conj(iCoil),[4 11])));

        f{end+1} = figure;
        ht = tiledlayout(nRows,nCols); ht.TileSpacing = 'compact'; ht.Padding = 'compact'; ht.TileIndexing = 'columnmajor'; ax = {};
        for k = 1:size(iCoil,4)
            ax{end+1} = nexttile;
            imagesc(angle(mean(img(:,:,:,k,:,:,s,:,:,:,:).* conj(iCoil(:,:,:,k)).*conj(phaseMap),11)),[-pi pi]); axis image off; colormap(ax{end},hsv); drawnow;
        end
        title(ht,'bart-corrected phase map from each coil after subtracting the phase map of the coil-averaged image')
    end
    display(['Coil combination (' coilMethod '). Doing...']);
    %% %%%%%%%%%%%%%
    img;


    img;
    iCoil;
    %%%%%%%%%%%%%%%%%%
    %% Save recon data
    %%%%%%%%%%%%%%%%%%
    imgInfo.vencList = [twixobj{1,2}.hdr.MeasYaps.sAngio.sFlowArray.asElm{1:twixobj{1,2}.hdr.MeasYaps.sAngio.sFlowArray.lSize}];
    imgInfo.vencList = permute([inf imgInfo.vencList.nVelocity],[1 3 4 5 6 7 2 8 9 10 11 12 13 14 15 16]);
    imgInfo.fov = [twixobj{1,2}.hdr.Config.ReadFoV twixobj{1,2}.hdr.Config.PhaseFoV];
    imgInfo.mat = [twixobj{1,2}.hdr.Config.ImageLines twixobj{1,2}.hdr.Config.PhaseEncodingLines];
    imgInfo.dim = strjoin({'READ' 'PHS1' 'PHS2' 'COIL' 'MAPS' 'TE' 'COEFF=venc' 'COEFF2' 'ITER' 'CSHIFT' 'TIME1' 'TIME2' 'LEVEL' 'SLICE' 'AVG' 'BATCH'},' x ');
    imgInfo.datFile      = datFile;
    imgInfo.datPhaseFile = datPhaseFile;
    imgInfo.datNoiseFile = datNoiseFile;

    save(outNameTmp,'img','iCoil','imgInfo');
    %% %%%%%%%%%%%%%%%
    imgInfo;
    outNameTmp;
else
    %%%%%%%%%%%%%%%%%%
    %% Load recon data
    %%%%%%%%%%%%%%%%%%
    load(outNameTmp);
    %% %%%%%%%%%%%%%%%
    iCoil;
    img;
    imgInfo;
end



outName = replace(datFile,'.dat',['_fft_coilComb-' coilMethod '.mat']);
if ~exist(outName,'file') || force

    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% Background phase correction
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % Remove background phase using velocity-compensated set (phase difference; only for velocity-encoded data)
    % if size(img,7)>1
    %     img = img ./ exp(1i*angle( mean(img(:,:,:,:,:,:,1,:,:,:,:,:,:,:,:,:),11) ));
    % end

    % Process datPhaseFile if provided
    if exist('datPhaseFile','var') && ~isempty(datPhaseFile)
        if ~datPhaseFlag
            [~,imgPhase] = recon([],[],datPhaseFile,coilMethod);
        else
            outName   = [];
            cropRange = [];

            % Extract venc-dependent background phase
            set = 1;
            img = img ./ exp(1i*angle( mean(img(:,:,:,:,:,:,set,:,:,:,:,:,:,:,:,:),11) ));
            
            % Get mask of trustworthy phases (statistically significant phases using multivariate Hotelling's T2 test)
            maskRecon = ~all(iCoil==0,4);
            X = permute(img,[11 4 1 2 3 7 5 6 8 9 10 12 13 14 15 16]);
            X = cat(2,real(X),imag(X));
            sz = size(X);
            tmpMask = repmat(maskRecon,[1 1 sz(5:end)]);
            % test for significance (non-zero mag vector) at each voxel and each venc
            stats = T2Hot1(X,[],[],tmpMask);
            mask = false(sz(3:end));
            mask(tmpMask) = mafdr(stats.P(tmpMask))<0.05; clear tmpMask stats
            % select voxels with significant signals at all vencs
            mask = all(mask(:,:,:,:),4);
            % morphological processing to get a single  smooothish mask
            mask = imclose(bwareafilt(imopen(imfill(mask,'holes'), strel('disk', 1)), 1), strel('disk', 1));

            % figure('MenuBar', 'none','ToolBar', 'none');
            % hT = tiledlayout(1,4); hT.TileSpacing = 'compact'; hT.Padding = 'compact'; ax = {};
            % ax{end+1} = nexttile(hT);
            % imagesc(abs(mean(img(:,:,:,:,:,:,set,:,:,:,:,:,:,:,:,:),11))); axis image off;
            % ax{end}.Colormap = gray;
            % ax{end+1} = nexttile(hT);
            % imagesc(mask); axis image off;
            % ax{end}.Colormap = gray;

            % Average across time and mask out voxels with poorly defined phase
            img = permute(mean(img,11),[4 5 6 7 8 9 10 11 12 13 14 15 16 1 2 3]);
            img(:,:,:,:,:,:,:,:,:,:,:,:,:,~mask) = nan;
            img = permute(img,[14 15 16 1 2 3 4 5 6 7 8 9 10 11 12 13]);
            return;
        end
    end
    % Remove venc-dependent background phase using phase reference data (dataRefFile; only for velocity-encoded data)
    if size(img,7)>1
        if size(img,7)~=size(imgPhase,7); error('datPhaseFile and datFile have different number of velocity-encoded sets'); end
        % subtract phase (will mask out voxels not covered by datPhaseFile)
        img = img ./ exp(1i*angle(imgPhase));
    end
    %% %%%%%%%%%%%%%%%%%%%%%%%%%%%


    %%%%%%%%%%%%%%%%%%%%
    %% Define crop range
    %%%%%%%%%%%%%%%%%%%%
    if all(size(cropRange,[1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16])==[1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1]) && cropRange==1
        % Manual crop range selection routine
        cropRange = manual_crop_range(sos(mean(img(:,:,:,:,:,:,1,:,:,:,:,:,:,:,:,:),11)));
    end
    %% %%%%%%%%%%%%%%%%%

    %%%%%%%%%%%%
    %% Crop data
    %%%%%%%%%%%%
    imgCropRef = mean(img(:,:,:,:),4);
    if all(size(cropRange,[1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16])==[2 2 1 1 1 1 1 1 1 1 1 1 1 1 1 1])
        imgCropMsk = false(size(imgCropRef));
        imgCropMsk(cropRange(1,1):cropRange(1,2),cropRange(2,1):cropRange(2,2)) = true;

        img = img(cropRange(1,1):cropRange(1,2),cropRange(2,1):cropRange(2,2),:,:,:,:,:,:,:,:,:,:,:,:,:,:);
    else
        imgCropMsk = true(size(imgCropRef));
        cropRange = [1 size(imgCropRef,1); 1 size(imgCropRef,2)];
    end
    %% %%%%%%%%%

    %%%%%%%%%%%%%
    %% Write data
    %%%%%%%%%%%%%
    fprintf('Writing data\n');
    try
        save(outName,'img','imgInfo');
    catch ME
        if strcmp(ME.identifier, 'MATLAB:save:couldNotWriteFile') || ...
        (isfield(ME, 'message') && contains(ME.message, 'exceeds the maximum variable size'))
            warning('File too large for default MAT-file format. Retrying save with -v7.3 flag.');
            save(outName,'img','imgInfo','-v7.3');
        else
            warning(ME);
        end
    end
    fprintf('Data written to %s\n', outName);
    %% %%%%%%%%%%

else
    fprintf('Data already exists: %s\n', outName);
end
