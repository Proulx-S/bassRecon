function bartRecon(datfile)
% Perform SENSE reconstruction on BART format data
% Usage: bartRecon('/path/to/file.dat')
% 
% This function reads a Siemens .dat file using mapVBVD and prepares
% the data for BART conversion. It stops after mapVBVD for manual
% data manipulation and BART conversion.


%% Dependencies 
% BART MATLAB
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
% mapVBVD.m
addpath('/scratch/users/Proulx-S/tools/zhRecon');

% Configure BART path for MATLAB wrapper
setenv('TOOLBOX_PATH', '/home/sebp/neurocommand/neurodesk/containers/bart_0.9.00_20240723');
setenv('PATH', [getenv('PATH') ':/home/sebp/neurocommand/neurodesk/containers/bart_0.9.00_20240723']);



%% Read data

% Check if file exists
if ~exist(datfile, 'file')
    error('File does not exist: %s', datfile);
end

fprintf('Reading Siemens .dat file: %s\n', datfile);

% Read the twix file using mapVBVD
twixobj = mapVBVD(datfile);

fprintf('Successfully loaded .dat file with mapVBVD\n');


sz = twixobj{1,2}.image.dataSize;
sz(3) = twixobj{1,2}.hdr.Config.ImageLines - twixobj{1,2}.image.NLin;
% sz(9:11) = 1;
sz([9 11]) = 1;



% format from twix
% [1-Columns x 2-Channels/Coils x 3-Lines x 4-Partitions x 5-Slices x 6-Averages x 7-(Cardiac-) Phases x 8-Contrasts/Echoes x 9-Measurements x 10-Sets x 11-Segments x 12-Ida x 13-Idb x 14-Idc x 15-Idd x 16-Ide] (see mapVBVD.m)
% to bart
% [1-READ_DIM  x  2-PHS1_DIM  x  3-PHS2_DIM    x  4-COIL_DIM        x  5-MAPS_DIM  x  6-TE_DIM            x  7-COEFF_DIM  x  8-COEFF2_DIM  x  9-ITER_DIM  x  10-CSHIFT_DIM  x  11-TIME_DIM     x  12-TIME2_DIM         x  13-LEVEL_DIM  x  14-SLICE_DIM  x  15-AVG_DIM  x  16-BATCH_DIM              ] (see https://github.com/mrirecon/bart/blob/master/src/misc/mri.h)
% twix reordered:
% [1-Columns   x  3-Lines     x  4-Partitions  x  2-Channels/Coils  x  12-Ida      x  8-Contrasts/Echoes  x  13-Idb       x  14-Idc        x  15-Idd      x  16-Ide         x  9-Measurements  x  7-(Cardiac-) Phases  x  17            x  5-Slices      x  6-Averages  x  10-Sets       x  11-Segments] (see mapVBVD.m)

% format from twix to bart to reordered twix
% [1-Columns   x  2-Channels/Coils x  3-Lines       x  4-Partitions      x  5-Slices    x  6-Averages          x  7-(Cardiac-) Phases  x  8-Contrasts/Echoes  x  9-Measurements  x  10-Sets        x  11-Segments     x  12-Ida               x  13-Idb        x  14-Idc           x  15-Idd      x  16-Ide                      ] (see mapVBVD.m)
% [1-READ_DIM  x  2-PHS1_DIM       x  3-PHS2_DIM    x  4-COIL_DIM        x  5-MAPS_DIM  x  6-TE_DIM            x  7-COEFF_DIM          x  8-COEFF2_DIM        x  9-ITER_DIM      x  10-CSHIFT_DIM  x  11-TIME_DIM     x  12-TIME2_DIM         x  13-LEVEL_DIM  x  14-SLICE_DIM     x  15-AVG_DIM  x  16-BATCH_DIM                ] (see https://github.com/mrirecon/bart/blob/master/src/misc/mri.h)
% [1-Columns   x  3-Lines          x  4-Partitions  x  2-Channels/Coils  x  12-Ida      x  8-Contrasts/Echoes  x  10-Sets              x  13-Idb              x  14-Idb          x  15-Idb         x  9-Measurements  x  7-(Cardiac-) Phases  x  17            x  5-Slices         x  6-Averages  x  16-Idb        x  11-Segments] (see mapVBVD.m)
% [1 3 4 2 12 8 10 13 14 15 9 7 17 5 6 16 11]

%% Calibration data
% 1) load calibration data
kcalib = permute(twixobj{1,2}.refscan(:,:,:,:,:,:,:,:,:,:,:,:,:,:,:,:),[1 3 4 2]);
% 2) pad calibration data to match image data
pad1 = twixobj{1,2}.hdr.Config.ImageColumns - size(kcalib,1);
pad2 = twixobj{1,2}.hdr.Config.ImageLines - size(kcalib,2);
pre1 = floor(pad1/2); post1 = ceil(pad1/2);
pre2 = floor(pad2/2); post2 = ceil(pad2/2);
kcalib = padarray(kcalib, [pre1 pre2], 0, 'pre');
kcalib = padarray(kcalib, [post1 post2], 0, 'post');
% 3) estimate coil sensitivities
coilMap = bart('ecalib -m1', kcalib);



% rep by rep because too large for matlab memory
img = complex(zeros([twixobj{1,2}.hdr.Config.ImageColumns twixobj{1,2}.hdr.Config.ImageLines 1 1 1 1 twixobj{1,2}.image.NSet 1 1 1 twixobj{1,2}.image.NRep]));
for irep = 1:twixobj{1,2}.image.NRep
    fprintf('Processing rep %d\n', irep);

    %% Image data
    % 1) load single image data, 2) pad k-space lines to image-space lines, 3) resolve freq encode oversampling, 4) permute to match bart format --- single line for efficiency
    % kdata = mrir_fDFT_freqencode(mrir_image_crop(mrir_fDFT_freqencode(...
    %     permute(cat(3,sum(twixobj{1,2}.image(:,:,:,:,:,:,:,:,irep,:,:,:),11),zeros(sz)),[1 3 4 2 12 8 13 14 15 16 9 7 17 5 6 10 11]))));
    kdata = mrir_fDFT_freqencode(mrir_image_crop(mrir_fDFT_freqencode(...
        permute(cat(3,sum(twixobj{1,2}.image(:,:,:,:,:,:,:,:,irep,:,:,:),11),zeros(sz)),[1 3 4 2 12 8 10 13 14 15 9 7 17 5 6 16 11]))));

    % kdata = permute(...
    %     mrir_fDFT_freqencode(mrir_image_crop(mrir_fDFT_freqencode(...
    %     permute(cat(3,sum(twixobj{1,2}.image(:,:,:,:,:,:,:,:,irep,:,:,:),11),zeros(sz)),[1 3 2]))))    ,[1 2 4 3]);



    
    % %% Recon with GRAPPA
    % % 1) reconstruct non-sampled k-space points, 2) fft to image space, 3) permute to match bart format --- single line for efficiency
    % grappaImg = permute(...
    %     ifft2c(GRAPPA(permute(kdata,[1 2 4 3]),permute(kcalib(64-17:64+18,64-17:64+18,:,:),[1 2 4 3]),[5,5],1e-2,0))    ,[1 2 4 3]);
    % figure('MenuBar','none','ToolBar','none');
    % imagesc(abs(grappaImg(:,:,1))); colormap gray; axis image; drawnow;

    %% Recon with BART
    % 1) estimate coil sensitivities, 2) reconstruct with SENSE (inverse FFT + SENSE) --- single line for efficiency
    img(:,:,:,:,:,:,:,:,:,:,irep,:,:,:,:,:) = bart('pics', kdata,coilMap);
    % imagesc(abs(img(:,:,1,1,1,1,1,1,1,1,irep,1,1,1,1,1))); colormap gray; axis image; drawnow;
end

%% Crop data
if exist('crop','var') && ~isempty(crop)
    % img = img(171:187,193:209,:,:,:,:,:,:,:,:,:,:,:,:,:,:);
    img = img(151:250,151:250,:,:,:,:,:,:,:,:,:,:,:,:,:,:);
end

%% Write data
venc = [twixobj{1,2}.hdr.MeasYaps.sAngio.sFlowArray.asElm{:}];
venc = permute([inf venc.nVelocity],[1 3 4 5 6 7 2 8 9 10 11 12 13 14 15 16]);

save(replace(datfile,'.dat','_bart.mat'),'img','venc');
