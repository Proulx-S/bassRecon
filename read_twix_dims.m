function read_twix_dims(datfile)
% Read dimensions from Siemens .dat file and save to .info file
% Usage: read_twix_dims('/path/to/file.dat')
figure('MenuBar', 'none','ToolBar', 'none');
% Add zhRecon to path
addpath('/scratch/users/Proulx-S/tools/zhRecon');

% Create output filename
[path, name, ~] = fileparts(datfile);
infofile = fullfile(path, [name, '.info']);

try
    % Read the twix file using mapVBVD
    twixobj = mapVBVD(datfile);
    
    % Open info file for writing
    fid = fopen(infofile, 'w');
    if fid == -1
        error('Could not create info file: %s', infofile);
    end
    
    % Write header information
    fprintf(fid, 'Number of datasets found: %d\n', length(twixobj));
    
    % Write dimensions for each dataset
    for i = 1:length(twixobj)
        fprintf(fid, 'Dataset %d:\n', i);
        if isfield(twixobj{1,i}, 'image')
            img_obj = twixobj{1,i}.image;
        elseif isfield(twixobj{1,i}, 'noise')
            img_obj = twixobj{1,i}.noise;
        else
            error('No image field found in dataset %d', i);
        end
        
        % Extract dimensions
        ncol = img_obj.NCol;      % Readout samples
        nlin = img_obj.NLin;      % Phase encoding lines  
        ncha = img_obj.NCha;      % Channels/coils
        nset = img_obj.NSet;      % Sets (e.g. VENC)
        nrep = img_obj.NRep;      % Repetitions (temporal)
        nsli = img_obj.NSli;      % Slices
        npar = img_obj.NPar;      % Partitions
        
        fprintf(fid, '  Readout: %d, Phase: %d, Coil: %d, Set: %d, Rep: %d, Slice: %d\n', ...
                ncol, nlin, ncha, nset, nrep, nsli);
    end
    
    % Use the second dataset for dimensions (time-resolved data) if available
    if length(twixobj) >= 2
        img_obj = twixobj{1,2}.image;
        fprintf(fid, 'Using dataset 2 (time-resolved data) for reconstruction\n');
    else
        img_obj = twixobj{1,1}.image;
        fprintf(fid, 'Using dataset 1 (only dataset available)\n');
    end
    
    % Extract dimensions
    ncol = img_obj.NCol;      % Readout samples
    nlin = img_obj.NLin;      % Phase encoding lines  
    ncha = img_obj.NCha;      % Channels/coils
    nset = img_obj.NSet;      % Sets (VENC dimension)
    nrep = img_obj.NRep;      % Repetitions (temporal)
    nsli = img_obj.NSli;      % Slices
    npar = img_obj.NPar;      % Partitions
    
    % Output in bash-friendly format
    fprintf(fid, 'READOUT=%d\n', ncol);
    fprintf(fid, 'PHASE=%d\n', nlin);
    fprintf(fid, 'COIL=%d\n', ncha);
    fprintf(fid, 'VENC_SETS=%d\n', nset);
    fprintf(fid, 'REPETITIONS=%d\n', nrep);
    fprintf(fid, 'SLICES=%d\n', nsli);
    fprintf(fid, 'PARTITIONS=%d\n', npar);
    
    % Also output the full dimension array for BART
    fprintf(fid, 'DIMS=%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n', ...
            ncol, nlin, nsli, ncha, npar, 1, 1, 1, 1, 1, nrep, nset, 1, 1, 1, 1);
    
    fclose(fid);
    
    % Also print to stdout for immediate feedback
    fprintf('Info file created: %s\n', infofile);
    fprintf('Number of datasets found: %d\n', length(twixobj));
    
catch ME
    if exist('fid', 'var') && fid ~= -1
        fclose(fid);
    end
    fprintf('ERROR: %s\n', ME.message);
    exit(1);
end