#!/bin/bash

# Siemens MRI Data Reconstruction Script using BART with SENSE
# Author: Generated for multiVENC phantom reconstruction
# Date: $(date)

# Load BART module
module load bart

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
    
    # Convert Siemens .dat to BART format
    echo "Converting Siemens .dat to BART format..."
    bart twixread "$datfile" "$TMPPATH/${basename}_raw"
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to convert $datfile"
        return 1
    fi
    
    # Get dimensions
    echo "Getting data dimensions..."
    bart show -m "$TMPPATH/${basename}_raw"
    
    # Extract k-space data (assuming it's in the first dimension)
    echo "Extracting k-space data..."
    bart slice 15 0 "$TMPPATH/${basename}_raw" "$TMPPATH/${basename}_kspace"
    
    # Estimate coil sensitivities using ESPIRiT
    echo "Estimating coil sensitivities..."
    bart ecalib -r 20 -m 1 "$TMPPATH/${basename}_kspace" "$TMPPATH/${basename}_sensitivities"
    
    # Perform SENSE reconstruction
    echo "Performing SENSE reconstruction..."
    bart pics -R L:7:0:0.01 -i 50 "$TMPPATH/${basename}_kspace" "$TMPPATH/${basename}_sensitivities" "$outputdir/${basename}_sense"
    
    # Alternative: Simple SENSE reconstruction without regularization
    echo "Performing simple SENSE reconstruction..."
    bart pics -i 30 "$TMPPATH/${basename}_kspace" "$TMPPATH/${basename}_sensitivities" "$outputdir/${basename}_sense_simple"
    
    # Convert to magnitude images
    echo "Converting to magnitude images..."
    bart rss 8 "$outputdir/${basename}_sense" "$outputdir/${basename}_sense_mag"
    bart rss 8 "$outputdir/${basename}_sense_simple" "$outputdir/${basename}_sense_simple_mag"
    
    # Convert to NIfTI for visualization
    echo "Converting to NIfTI format..."
    bart toimg "$outputdir/${basename}_sense_mag" "$outputdir/${basename}_sense_mag.nii"
    bart toimg "$outputdir/${basename}_sense_simple_mag" "$outputdir/${basename}_sense_simple_mag.nii"
    
    # Clean up temporary files for this measurement
    rm -f "$TMPPATH/${basename}_"*
    
    echo "Completed reconstruction for: $basename"
    echo "Output saved to: $outputdir"
    echo ""
}

# Main processing loop
echo "Starting Siemens MRI reconstruction with SENSE"
echo "Data path: $DATAPATH"
echo "Output path: $OUTPUTPATH"
echo ""

# Process all .dat files
for datfile in "$DATAPATH"/*.dat; do
    if [ -f "$datfile" ]; then
        reconstruct_file "$datfile"
    fi
done

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

