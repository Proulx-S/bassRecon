#!/bin/bash

# Siemens MRI Data Reconstruction Script using BART with SENSE
# Author: Generated for multiVENC phantom reconstruction
# Date: $(date)

# Usage function
usage() {
    echo "Usage: $0 [OPTIONS] [FILEPATH1] [FILEPATH2] ..."
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -a, --all      Process all .dat files in the data directory (default if no filenames provided)"
    echo ""
    echo "Arguments:"
    echo "  FILEPATH1, FILEPATH2, ...  Specific .dat files to process (full path with .dat extension)"
    echo "                             Can be absolute paths or relative to current directory"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Process all .dat files in data directory"
    echo "  $0 -a                                 # Process all .dat files in data directory"
    echo "  $0 /path/to/meas_MID00203_FID02135_vfMRI_multiVENC_maxFlow_2_4_6_8_10cmPs.dat"
    echo "  $0 meas_MID00203_FID02135_vfMRI_multiVENC_maxFlow_2_4_6_8_10cmPs.dat"
    echo "  $0 file1.dat file2.dat file3.dat"
    echo ""
    exit 1
}

# Parse command line arguments
PROCESS_ALL=false
SPECIFIC_FILES=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -a|--all)
            PROCESS_ALL=true
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            SPECIFIC_FILES+=("$1")
            shift
            ;;
    esac
done

# Load BART module
ml bart

# Set paths
DATAPATH="/local/users/Proulx-S/dbPhantom/20250906_multiVENCphantom02/raw"
OUTPUTPATH="/local/users/Proulx-S/dbPhantom/20250906_multiVENCphantom02/offlineRecon"
TMPPATH="/scratch/users/Proulx-S/tools/bassRecon/tmp"

# Create output directories
mkdir -p "$OUTPUTPATH"
mkdir -p "$TMPPATH"

# Function to extract measurement info from filename
extract_info() {
    local filename="$1"
    # Extract VENC values from filename (e.g., "2_4_6_8_10cmPs" -> "2 4 6 8 10")
    echo "$filename" | sed 's/.*maxFlow_\([0-9_]*\)cmPs.*/\1/' | tr '_' ' '
}

# Function to reconstruct a single .dat file
reconstruct_file() {
    local datfile="$1"
    local basename=$(basename "$datfile" .dat)
    local outputdir="$OUTPUTPATH/$basename"
    
    echo "=========================================="
    echo "Processing: $basename"
    echo "=========================================="
    
    # Create output directory for this measurement
    mkdir -p "$outputdir"
    
    # Get dimensions directly from .dat file using MATLAB
    echo "Reading dimensions from .dat file. This is slow for no good reason..."
    DIM_INFO=$(matlab -batch "read_twix_dims('$datfile')" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to read dimensions from $datfile"
        return 1
    fi
    
    # Check if we got valid dimension information
    if [ -z "$DIM_INFO" ] || ! echo "$DIM_INFO" | grep -q "READOUT="; then
        echo "Error: No valid dimension information received from MATLAB"
        echo "MATLAB output was: $DIM_INFO"
        return 1
    fi
    
    # Parse the dimension information
    READOUT=$(echo "$DIM_INFO" | grep "READOUT=" | cut -d'=' -f2)
    PHASE=$(echo "$DIM_INFO" | grep "PHASE=" | cut -d'=' -f2)
    COIL=$(echo "$DIM_INFO" | grep "COIL=" | cut -d'=' -f2)
    VENC_SIZE=$(echo "$DIM_INFO" | grep "VENC_SETS=" | cut -d'=' -f2)
    REP_SIZE=$(echo "$DIM_INFO" | grep "REPETITIONS=" | cut -d'=' -f2)
    SLICE=$(echo "$DIM_INFO" | grep "SLICES=" | cut -d'=' -f2)
    
    # Convert BART dimension array to find dimension indices
    DIMS=$(echo "$DIM_INFO" | grep "DIMS=" | cut -d'=' -f2)
    
    # Find repetition and VENC dimensions (look for non-1 values in later dimensions)
    REP_DIM=0
    VENC_DIM=0
    
    for i in {5..16}; do
        dim_val=$(echo $DIMS | awk -v i=$i '{print $i}')
        if [ "$dim_val" -gt 1 ]; then
            if [ $REP_DIM -eq 0 ]; then
                REP_DIM=$i
            elif [ $VENC_DIM -eq 0 ]; then
                VENC_DIM=$i
            fi
        fi
    done
    
    # Convert Siemens .dat to BART format using the detected dimensions
    echo "Converting Siemens .dat to BART format..."
    bart twixread -X -x $READOUT -y $PHASE -c $COIL -n $REP_SIZE -f $VENC_SIZE "$datfile" "$TMPPATH/${basename}_raw"
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to convert $datfile"
        return 1
    fi

    # Print BART-format files for inspection
    echo "BART-format files created:"
    ls -lh "$TMPPATH/${basename}_raw".*
    
    echo "Detected dimensions:"
    echo "  Readout: $READOUT"
    echo "  Phase: $PHASE"
    echo "  Slice: $SLICE"
    echo "  Coil: $COIL"
    echo "  Repetitions: $REP_SIZE (dimension $REP_DIM)"
    echo "  VENC sets: $VENC_SIZE (dimension $VENC_DIM)"
    
    # Extract k-space data for calibration (use multiple repetitions for better calibration)
    echo "Extracting k-space data for calibration..."
    bart slice $REP_DIM 0 "$TMPPATH/${basename}_raw" "$TMPPATH/${basename}_kspace_cal"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to extract calibration k-space data"
        return 1
    fi
    
    bart slice $VENC_DIM 0 "$TMPPATH/${basename}_kspace_cal" "$TMPPATH/${basename}_kspace_cal"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to extract VENC slice for calibration"
        return 1
    fi
    
    # Estimate coil sensitivities using ESPIRiT with more conservative parameters
    echo "Estimating coil sensitivities..."
    bart ecalib -r 20 -m 1 -c 0.95 "$TMPPATH/${basename}_kspace_cal" "$TMPPATH/${basename}_sensitivities"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to estimate coil sensitivities with ESPIRiT"
        echo "Trying alternative calibration approach..."
        
        # Alternative: Use simple sum-of-squares for coil combination
        echo "Using sum-of-squares coil combination instead..."
        bart ones 1 $COIL "$TMPPATH/${basename}_sensitivities"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to create dummy sensitivities"
            return 1
        fi
    fi
    
    # Process all repetitions and VENC sets
    echo "Processing all temporal frames and VENC sets..."
    for rep in $(seq 0 $((REP_SIZE-1))); do
        for venc in $(seq 0 $((VENC_SIZE-1))); do
            echo "Processing repetition $((rep+1))/$REP_SIZE, VENC $((venc+1))/$VENC_SIZE"
            
            # Extract k-space data for this rep/venc combination
            bart slice $REP_DIM $rep "$TMPPATH/${basename}_raw" "$TMPPATH/${basename}_kspace_rep"
            if [ $? -ne 0 ]; then
                echo "Error: Failed to extract repetition $rep from raw data"
                return 1
            fi
            
            bart slice $VENC_DIM $venc "$TMPPATH/${basename}_kspace_rep" "$TMPPATH/${basename}_kspace_current"
            if [ $? -ne 0 ]; then
                echo "Error: Failed to extract VENC $venc from repetition $rep"
                return 1
            fi
            
            # Perform reconstruction (SENSE if sensitivities available, otherwise sum-of-squares)
            use_sense=false
            if [ -f "$TMPPATH/${basename}_sensitivities.cfl" ]; then
                # Check if sensitivities are dummy (all ones)
                bart show -m "$TMPPATH/${basename}_sensitivities" > /tmp/sens_dims.txt
                sens_dims=$(cat /tmp/sens_dims.txt | grep "AoD:" | awk '{print $2, $3, $4, $5}')
                if [ "$sens_dims" != "1 $COIL 1 1" ]; then
                    # Real sensitivities - use SENSE
                    bart pics -R L:7:0:0.01 -i 50 "$TMPPATH/${basename}_kspace_current" "$TMPPATH/${basename}_sensitivities" "$TMPPATH/${basename}_sense_${rep}_${venc}"
                    use_sense=true
                fi
            fi
            
            if [ "$use_sense" = false ]; then
                # No sensitivities or dummy sensitivities - use sum-of-squares directly
                bart rss 8 "$TMPPATH/${basename}_kspace_current" "$TMPPATH/${basename}_sense_mag_${rep}_${venc}"
            else
                # SENSE reconstruction - convert to magnitude
                bart rss 8 "$TMPPATH/${basename}_sense_${rep}_${venc}" "$TMPPATH/${basename}_sense_mag_${rep}_${venc}"
            fi
            
            if [ $? -ne 0 ]; then
                echo "Error: Failed to perform reconstruction for rep $rep, VENC $venc"
                return 1
            fi
            
            # Clean up intermediate files
            rm -f "$TMPPATH/${basename}_kspace_rep" "$TMPPATH/${basename}_kspace_current" "$TMPPATH/${basename}_sense_${rep}_${venc}"
        done
    done
    
    # Combine all reconstructed images into a single dataset
    echo "Combining reconstructed images..."
    bart join $REP_DIM $(ls "$TMPPATH/${basename}_sense_mag_"*_0.cfl | sed 's/\.cfl$//' | sort -V) "$TMPPATH/${basename}_sense_mag_all_reps"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to join repetitions"
        return 1
    fi
    
    bart join $VENC_DIM $(ls "$TMPPATH/${basename}_sense_mag_0_"*.cfl | sed 's/\.cfl$//' | sort -V) "$TMPPATH/${basename}_sense_mag_all_vencs"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to join VENC sets"
        return 1
    fi
    
    # Save final combined results
    cp "$TMPPATH/${basename}_sense_mag_all_reps"* "$outputdir/${basename}_sense_mag_all_reps"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to copy combined repetitions file"
        return 1
    fi
    
    cp "$TMPPATH/${basename}_sense_mag_all_vencs"* "$outputdir/${basename}_sense_mag_all_vencs"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to copy combined VENC file"
        return 1
    fi
    
    # Convert to PNG for visualization (first frame, first VENC)
    echo "Converting to PNG for visualization..."
    bart toimg "$TMPPATH/${basename}_sense_mag_0_0" "$outputdir/${basename}_sense_mag_sample"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to convert to PNG"
        return 1
    fi
    
    # Clean up temporary files for this measurement
    rm -f "$TMPPATH/${basename}_"*
    
    echo "Completed reconstruction for: $basename"
    echo "Output saved to: $outputdir"
    echo ""
}

# Function to validate and find dat file
find_dat_file() {
    local filepath="$1"
    
    # If the filepath already has .dat extension, use it as-is
    if [[ "$filepath" == *.dat ]]; then
        if [ -f "$filepath" ]; then
            echo "$filepath"
            return 0
        else
            echo "Error: File not found: $filepath" >&2
            return 1
        fi
    else
        # If no extension, try adding .dat and look in data directory
        local datfile="$DATAPATH/${filepath}.dat"
        if [ -f "$datfile" ]; then
            echo "$datfile"
            return 0
        else
            echo "Error: File not found: $datfile" >&2
            return 1
        fi
    fi
}

# Main processing loop
echo "Starting Siemens MRI reconstruction with SENSE"
echo "Data path: $DATAPATH"
echo "Output path: $OUTPUTPATH"
echo ""

# Determine which files to process
if [ ${#SPECIFIC_FILES[@]} -eq 0 ] || [ "$PROCESS_ALL" = true ]; then
    # Process all .dat files
    echo "Processing all .dat files in data directory..."
    for datfile in "$DATAPATH"/*.dat; do
        if [ -f "$datfile" ]; then
            reconstruct_file "$datfile"
        fi
    done
else
    # Process specific files
    echo "Processing specific files: ${SPECIFIC_FILES[*]}"
    for filepath in "${SPECIFIC_FILES[@]}"; do
        datfile=$(find_dat_file "$filepath")
        if [ $? -eq 0 ]; then
            reconstruct_file "$datfile"
        else
            echo "Skipping: $filepath"
        fi
    done
fi

echo "=========================================="
echo "All reconstructions completed!"
echo "Results saved in: $OUTPUTPATH"
echo "=========================================="

# Optional: Create a summary script to view results
cat > "$OUTPUTPATH/view_results.sh" << 'EOF'
#!/bin/bash
echo "Available reconstructed datasets:"
find . -name "*.nii" | sort
echo ""
echo "To view with FSL:"
echo "fsleyes *.nii"
echo ""
echo "To view with ITK-SNAP:"
echo "itksnap *.nii"
EOF

chmod +x "$OUTPUTPATH/view_results.sh"

echo "Created view_results.sh script in output directory"

