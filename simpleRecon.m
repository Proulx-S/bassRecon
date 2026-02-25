function [outName,cropRange] = simpleRecon(datfile,coilMethod,cropRange,verbose)
% simpleRecon  Reconstruct Siemens .dat and save coil-combined image to .mat
%
%   cropRange = simpleRecon(datfile,cropRange,coilMethod)
%
% Reads a Siemens .dat with mapVBVD, reconstructs (ifft2c), combines coils
% (BART ecalib for 'bartEspirit' or k-space phase for 'k'), optionally crops,
% and saves img, venc, kCoil, imgCropRef, imgCropMsk to a .mat file.
%
% Inputs:
%   datfile    - path to Siemens .dat file
%   cropRange  - (optional) [] or 0: no crop; 1: run manual_crop_range; [2x2]: [row;col] crop limits
%   coilMethod - (optional) 'bartEspirit' (default) or 'k'
%
% Output:
%   cropRange  - crop range used (from input or from manual_crop_range)
%
% Writes: <datfile_base>_fft_coilComb-<coilMethod>.mat (or _FEcrop..._PEcrop... if cropped)
% Dependencies: mapVBVD (zhRecon), optionally BART MATLAB (for coilMethod 'bartEspirit')

if ~exist('cropRange','var'); cropRange = []; end
if isempty(cropRange);        cropRange =  0; end
if ~exist('coilMethod','var'); coilMethod = ''; end
if isempty(coilMethod);        coilMethod =  'bartEspirit'; end
if ~exist('verbose','var'); verbose = ''; end
if isempty(verbose);        verbose =  0; end
        
%%%%%%%%%%%%%%%
%% Dependencies
%%%%%%%%%%%%%%%
% mapVBVD.m
addpath('/scratch/users/Proulx-S/tools/zhRecon');
% BART MATLAB
if strcmp(coilMethod,'bartEspirit')
    bartMatlabDir = '/scratch/users/Proulx-S/tools/bart-matlab';
    if ~exist(bartMatlabDir, 'dir')
        fprintf('BART MATLAB functions not found. Cloning from GitHub...\n');
        [status, msg] = system(sprintf('cd /scratch/users/Proulx-S/tools && git clone --filter=blob:none --sparse https://github.com/mrirecon/bart.git bart-matlab'));
        if status ~= 0
            error('Failed to clone BART MATLAB functions: %s', msg);
        end
        [status, msg] = system(sprintf('cd %s && git sparse-checkout set matlab', bartMatlabDir));
        if status ~= 0
            error('Failed to set sparse checkout: %s', msg);
        end
        fprintf('BART MATLAB functions cloned successfully.\n');
    end
    addpath(fullfile(bartMatlabDir, 'matlab'));
    % Configure BART path for MATLAB wrapper
    setenv('TOOLBOX_PATH', '/home/sebp/neurocommand/neurodesk/containers/bart_0.9.00_20240723');
    setenv('PATH', [getenv('PATH') ':/home/sebp/neurocommand/neurodesk/containers/bart_0.9.00_20240723']);
end
%% %%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Read data frame-by-frame
%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Check if file exists
if ~exist(datfile, 'file'); error('File does not exist: %s', datfile); end
[~, datfileName, datfileExt] = fileparts(datfile); datfileName = [datfileName datfileExt]; 

% Read the twix file using mapVBVD
disp(['Mapping ' datfileName ' mapping...']);
twixobj = mapVBVD(datfile);
disp(['Mapping ' datfileName ' done.']);

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

% Loop over repetitions
disp(['Reading data. Reading...']);
parfor irep = 1:twixobj{1,2}.image.NRep
    % Get k-space data
    % 1) load single image data, 2) pad k-space lines to image-space lines, 3) resolve freq encode oversampling, 4) permute to match bart format --- single line for efficiency
    kdata = mrir_fDFT_freqencode(mrir_image_crop(mrir_fDFT_freqencode(...
        permute(cat(3,sum(twixobj{1,2}.image(:,:,:,:,:,:,:,:,irep,:,:,:),11),zeros(sz)),[1 3 4 2 12 8 10 13 14 15 9 7 17 5 6 16 11]))));
    % 5) feal with phase resolution
    kdata = kdata(:,1:twixobj{1,2}.image.NLin,:,:,:,:,:);

    % Get coil data (first set for the velocity compensated acquisition in phase contrast data)
    set = 1;
    switch coilMethod
        case 'bartEspirit'
            % Accumulate kdata for later coil sensitivity map (velocity compensated set)
            kCoil(:,:,:,:,:,:,:,:,:,:,irep,:,:,:,:,:) =      kdata(:,:,:,:,:,:,set,:,:,:,:,:,:,:,:,:);
        otherwise
            error('Invalid coil method: %s', coilMethod);
    end

    % Get image-space data
    img(:,:,:,:,:,:,:,:,:,:,irep,:,:,:,:,:) = ifft2c(kdata);    
end
% Average coil data over time
kCoil = mean(kCoil,11);

disp(['Reading data. Done.']);
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


%%%%%%%%%%%%%%%%
%% Combine coils
%%%%%%%%%%%%%%%%
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
%% %%%%%%%%%%%%%
img;



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
    outName = replace(datfile,'.dat',['_fft_coilComb-' coilMethod '_FEcrop' num2str(cropRange(1,1)) '-' num2str(cropRange(1,2)) '_PEcrop' num2str(cropRange(2,1)) '-' num2str(cropRange(2,2)) '.mat']);
else
    imgCropMsk = true(size(imgCropRef));
    outName = replace(datfile,'.dat',['_fft_coilComb-' coilMethod '.mat']);
    cropRange = [1 size(imgCropRef,1); 1 size(imgCropRef,2)];
end
%% %%%%%%%%%

%%%%%%%%%%%%%
%% Write data
%%%%%%%%%%%%%
fprintf('Writing data\n');
lSize = twixobj{1,2}.hdr.MeasYaps.sAngio.sFlowArray.lSize;
venc = [twixobj{1,2}.hdr.MeasYaps.sAngio.sFlowArray.asElm{1:lSize}];
venc = permute([inf venc.nVelocity],[1 3 4 5 6 7 2 8 9 10 11 12 13 14 15 16]);
try
    save(outName,'img','venc','kCoil','imgCropRef','imgCropMsk');
catch ME
    if strcmp(ME.identifier, 'MATLAB:save:couldNotWriteFile') || ...
       (isfield(ME, 'message') && contains(ME.message, 'exceeds the maximum variable size'))
        warning('File too large for default MAT-file format. Retrying save with -v7.3 flag.');
        save(outName,'img','venc','kCoil','imgCropRef','imgCropMsk','-v7.3');
    else
        warning(ME);
    end
end
fprintf('Data written to %s\n', outName);
%% %%%%%%%%%%