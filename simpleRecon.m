function cropRange = simpleRecon(datfile,cropRange,coilMethod)
% This function reads a Siemens .dat file using mapVBVD and prepares
% the data for BART conversion. It stops after mapVBVD for manual
% data manipulation and BART conversion.

if ~exist('cropRange','var'); cropRange = []; end
if isempty(cropRange);        cropRange =  0; end
if ~exist('coilMethod','var'); coilMethod = ''; end
if isempty(coilMethod);        coilMethod =  'bartMap'; end


%% Dependencies 
% mapVBVD.m
addpath('/scratch/users/Proulx-S/tools/zhRecon');
% BART MATLAB
if strcmp(coilMethod,'bartMap')
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



% rep by rep because too large for matlab memory
img           = complex(zeros([twixobj{1,2}.hdr.Config.ImageColumns twixobj{1,2}.image.NLin 1 twixobj{1,2}.image.NCha 1 1 twixobj{1,2}.image.NSet 1 1 1 twixobj{1,2}.image.NRep 1 1 1 1 1]));
switch coilMethod
    case 'bartMap'
        kCoil = complex(zeros([twixobj{1,2}.hdr.Config.ImageColumns twixobj{1,2}.image.NLin 1 twixobj{1,2}.image.NCha 1 1                       1 1 1 1 twixobj{1,2}.image.NRep 1 1 1 1 1]));
    case 'k'
        kCoil = complex(zeros([                                   1                       1 1 twixobj{1,2}.image.NCha 1 1                       1 1 1 1 twixobj{1,2}.image.NRep 1 1 1 1 1]));
    otherwise
        error('Invalid coil method: %s', coilMethod);
end

parfor irep = 1:twixobj{1,2}.image.NRep
    fprintf('Processing rep %d\n', irep);

    %% Image data
    % 1) load single image data, 2) pad k-space lines to image-space lines, 3) resolve freq encode oversampling, 4) permute to match bart format --- single line for efficiency
    % kdata = mrir_fDFT_freqencode(mrir_image_crop(mrir_fDFT_freqencode(...
    %     permute(cat(3,sum(twixobj{1,2}.image(:,:,:,:,:,:,:,:,irep,:,:,:),11),zeros(sz)),[1 3 4 2 12 8 13 14 15 16 9 7 17 5 6 10 11]))));
    kdata = mrir_fDFT_freqencode(mrir_image_crop(mrir_fDFT_freqencode(...
        permute(cat(3,sum(twixobj{1,2}.image(:,:,:,:,:,:,:,:,irep,:,:,:),11),zeros(sz)),[1 3 4 2 12 8 10 13 14 15 9 7 17 5 6 16 11]))));

    % Phase resolution
    kdata = kdata(:,1:twixobj{1,2}.image.NLin,:,:,:,:,:);


    switch coilMethod
        case 'bartMap'
            % Accumulate kdata for later coil sensitivity map
            kCoil(:,:,:,:,:,:,:,:,:,:,irep,:,:,:,:,:) =      kdata(:,:,:,:,:,:,1,:,:,:,:,:,:,:,:,:);
        case 'k'
            % Coil phase
            kCoil(:,:,:,:,:,:,:,:,:,:,irep,:,:,:,:,:) = mean(kdata(:,:,:,:,:,:,1).*sos(kdata(:,:,:,:,:,:,1)),[1 2]);
        otherwise
            error('Invalid coil method: %s', coilMethod);
    end
    
    


    % kdata = permute(...
    %     mrir_fDFT_freqencode(mrir_image_crop(mrir_fDFT_freqencode(...
    %     permute(cat(3,sum(twixobj{1,2}.image(:,:,:,:,:,:,:,:,irep,:,:,:),11),zeros(sz)),[1 3 2]))))    ,[1 2 4 3]);

    %% Simple fft
    img(:,:,:,:,:,:,:,:,:,:,irep,:,:,:,:,:) = ifft2c(kdata);
    % imagesc(sum(abs(kdata(:,:,:,:,:,:,1)),4)); axis image; colormap gray; drawnow;
    % imagesc(sum(abs(img(:,:,:,:,:,:,1,:,:,:,irep)),4)); axis image; colormap gray; drawnow;


    
    % %% Recon with GRAPPA
    % % 1) reconstruct non-sampled k-space points, 2) fft to image space, 3) permute to match bart format --- single line for efficiency
    % grappaImg = permute(...
    %     ifft2c(GRAPPA(permute(kdata,[1 2 4 3]),permute(kcalib(64-17:64+18,64-17:64+18,:,:),[1 2 4 3]),[5,5],1e-2,0))    ,[1 2 4 3]);
    % figure('MenuBar','none','ToolBar','none');
    % imagesc(abs(grappaImg(:,:,1))); colormap gray; axis image; drawnow;

    % %% Recon with BART
    % % 1) estimate coil sensitivities, 2) reconstruct with SENSE (inverse FFT + SENSE) --- single line for efficiency
    % img(:,:,:,:,:,:,:,:,:,:,irep,:,:,:,:,:) = bart('pics', kdata,coilMap);
    % % imagesc(abs(img(:,:,1,1,1,1,1,1,1,1,irep,1,1,1,1,1))); colormap gray; axis image; drawnow;
end
fprintf('Recon done\n');




%% Combine coils
switch coilMethod
    case 'bartMap'
        % compute coil sensitivity/phase map
        display('Computing coil sensitivity/phase map');
        kCoil = mean(kCoil,11);
        iCoil = bart('ecalib -m1', kCoil);
        % multiply by coil sensitivity, remove coil phase and combine coils
        img = sum( img .* conj(iCoil) ,4);
    case 'k'
        img = sum(  img               .* exp(-1i * angle(mean(kCoil,11)))  ,4);
    otherwise
        error('Invalid coil method: %s', coilMethod);
end



%% Define crop range
if all(size(cropRange,[1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16])==[1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1]) && cropRange==1
    % Manual crop range selection routine
    cropRange = manual_crop_range(sos(mean(img(:,:,:,:,:,:,1,:,:,:,:,:,:,:,:,:),11)));
end


%% Crop data
if all(size(cropRange,[1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16])==[2 2 1 1 1 1 1 1 1 1 1 1 1 1 1 1])
    imgCropRef = mean(img(:,:,:,:),4);
    imgCropMsk = false(size(imgCropRef));
    imgCropMsk(cropRange(1,1):cropRange(1,2),cropRange(2,1):cropRange(2,2)) = true;

    img = img(cropRange(1,1):cropRange(1,2),cropRange(2,1):cropRange(2,2),:,:,:,:,:,:,:,:,:,:,:,:,:,:);
    outName = replace(datfile,'.dat',['_fft_coilComb-' coilMethod '_FEcrop' num2str(cropRange(1,1)) '-' num2str(cropRange(1,2)) '_PEcrop' num2str(cropRange(2,1)) '-' num2str(cropRange(2,2)) '.mat']);
else
    imgCropRef = mean(img(:,:,:,:,:,:,1,:,:,:,:,:,:,:,:,:),[4 11]);
    imgCropMsk = true(size(imgCropRef));
    outName = replace(datfile,'.dat',['_fft_coilComb-' coilMethod '.mat']);
end


%% Write data
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