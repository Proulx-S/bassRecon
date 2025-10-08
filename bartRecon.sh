#!/bin/bash

# bartRecon.sh - Perform SENSE reconstruction on BART format data
# Usage: bartRecon.sh <timeseries_bart_file> <calibration_bart_file> [output_dir]
# Example: bartRecon.sh /path/to/timeseries /path/to/calibration /path/to/output

set -e  # Exit on any error

# Check arguments
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "Usage: $0 <timeseries_bart_file> <calibration_bart_file> [output_dir]"
    echo "Example: $0 /path/to/timeseries /path/to/calibration /path/to/output"
    exit 1
fi

TIMESERIES_FILE="$1"
CALIB_FILE="$2"
OUTPUT_DIR="${3:-/local/users/Proulx-S/dbPhantom/20250906_multiVENCphantom02/offlineRecon}"

# Check if input files exist
if [ ! -f "${TIMESERIES_FILE}.cfl" ]; then
    echo "Error: Timeseries file ${TIMESERIES_FILE}.cfl does not exist"
    exit 1
fi

if [ ! -f "${CALIB_FILE}.cfl" ]; then
    echo "Error: Calibration file ${CALIB_FILE}.cfl does not exist"
    exit 1
fi

# Get basename for output files
BASENAME=$(basename "$TIMESERIES_FILE" _timeseries)
TMPPATH="/scratch/users/Proulx-S/tools/bassRecon/tmp"

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo "Performing SENSE reconstruction..."
echo "Timeseries file: $TIMESERIES_FILE"
echo "Calibration file: $CALIB_FILE"
echo "Output directory: $OUTPUT_DIR"
echo ""

# Load BART module
ml bart

# Get dimensions of timeseries data
echo "Getting timeseries data dimensions..."
bart show -m "$TIMESERIES_FILE" > "$TMPPATH/${BASENAME}_dims.txt"

# Extract dimensions from the output
# Format: AoD: 800 397 1 32 1 1 1 1 1 1 128 6 1 1 1 1
DIMS=$(grep "AoD:" "$TMPPATH/${BASENAME}_dims.txt" | awk '{print $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17}')

# Parse dimensions (assuming standard order: readout, phase, slice, coil, ..., rep, venc, ...)
READOUT=$(echo $DIMS | awk '{print $1}')
PHASE=$(echo $DIMS | awk '{print $2}')
SLICE=$(echo $DIMS | awk '{print $3}')
COIL=$(echo $DIMS | awk '{print $4}')

# Find repetition and VENC dimensions (look for non-1 values in later dimensions)
REP_DIM=0
VENC_DIM=0
REP_SIZE=1
VENC_SIZE=1

for i in {5..16}; do
    dim_val=$(echo $DIMS | awk -v i=$i '{print $i}')
    if [ "$dim_val" -gt 1 ]; then
        if [ $REP_DIM -eq 0 ]; then
            REP_DIM=$i
            REP_SIZE=$dim_val
        elif [ $VENC_DIM -eq 0 ]; then
            VENC_DIM=$i
            VENC_SIZE=$dim_val
        fi
    fi
done

echo "Detected dimensions:"
echo "  Readout: $READOUT"
echo "  Phase: $PHASE"
echo "  Slice: $SLICE"
echo "  Coil: $COIL"
echo "  Repetitions: $REP_SIZE (dimension $REP_DIM)"
echo "  VENC sets: $VENC_SIZE (dimension $VENC_DIM)"
echo ""

# Estimate coil sensitivities from calibration data
echo "Estimating coil sensitivities from calibration data..."
bart ecalib -r 20 -m 1 "$CALIB_FILE" "$TMPPATH/${BASENAME}_sensitivities"

if [ $? -ne 0 ]; then
    echo "Error: Failed to estimate coil sensitivities"
    exit 1
fi

echo "Coil sensitivity estimation completed successfully!"
echo ""

# Process all repetitions and VENC sets
echo "Processing all temporal frames and VENC sets..."
for rep in $(seq 0 $((REP_SIZE-1))); do
    for venc in $(seq 0 $((VENC_SIZE-1))); do
        echo "Processing repetition $((rep+1))/$REP_SIZE, VENC $((venc+1))/$VENC_SIZE"
        
        # Extract k-space data for this rep/venc combination
        bart slice $REP_DIM $rep "$TIMESERIES_FILE" "$TMPPATH/${BASENAME}_kspace_rep"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to extract repetition $rep from timeseries data"
            exit 1
        fi
        
        bart slice $VENC_DIM $venc "$TMPPATH/${BASENAME}_kspace_rep" "$TMPPATH/${BASENAME}_kspace_current"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to extract VENC $venc from repetition $rep"
            exit 1
        fi
        
        # Perform SENSE reconstruction
        bart pics -R L:7:0:0.01 -i 50 "$TMPPATH/${BASENAME}_kspace_current" "$TMPPATH/${BASENAME}_sensitivities" "$TMPPATH/${BASENAME}_sense_${rep}_${venc}"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to perform SENSE reconstruction for rep $rep, VENC $venc"
            exit 1
        fi
        
        # Convert to magnitude
        bart rss 8 "$TMPPATH/${BASENAME}_sense_${rep}_${venc}" "$TMPPATH/${BASENAME}_sense_mag_${rep}_${venc}"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to convert to magnitude for rep $rep, VENC $venc"
            exit 1
        fi
        
        # Clean up intermediate files
        rm -f "$TMPPATH/${BASENAME}_kspace_rep" "$TMPPATH/${BASENAME}_kspace_current" "$TMPPATH/${BASENAME}_sense_${rep}_${venc}"
    done
done

# Combine all reconstructed images into a single dataset
echo "Combining reconstructed images..."
bart join $REP_DIM $(ls "$TMPPATH/${BASENAME}_sense_mag_"*_0.cfl | sed 's/\.cfl$//' | sort -V) "$TMPPATH/${BASENAME}_sense_mag_all_reps"
if [ $? -ne 0 ]; then
    echo "Error: Failed to join repetitions"
    exit 1
fi

bart join $VENC_DIM $(ls "$TMPPATH/${BASENAME}_sense_mag_0_"*.cfl | sed 's/\.cfl$//' | sort -V) "$TMPPATH/${BASENAME}_sense_mag_all_vencs"
if [ $? -ne 0 ]; then
    echo "Error: Failed to join VENC sets"
    exit 1
fi

# Save final combined results
cp "$TMPPATH/${BASENAME}_sense_mag_all_reps"* "$OUTPUT_DIR/${BASENAME}_sense_mag_all_reps"
if [ $? -ne 0 ]; then
    echo "Error: Failed to copy combined repetitions file"
    exit 1
fi

cp "$TMPPATH/${BASENAME}_sense_mag_all_vencs"* "$OUTPUT_DIR/${BASENAME}_sense_mag_all_vencs"
if [ $? -ne 0 ]; then
    echo "Error: Failed to copy combined VENC file"
    exit 1
fi

# Convert to PNG for visualization (first frame, first VENC)
echo "Converting to PNG for visualization..."
bart toimg "$TMPPATH/${BASENAME}_sense_mag_0_0" "$OUTPUT_DIR/${BASENAME}_sense_mag_sample"
if [ $? -ne 0 ]; then
    echo "Error: Failed to convert to PNG"
    exit 1
fi

# Clean up temporary files for this measurement
rm -f "$TMPPATH/${BASENAME}_"*

echo ""
echo "Reconstruction completed successfully!"
echo "Output saved to: $OUTPUT_DIR"
echo ""
echo "Output files:"
echo "  Combined repetitions: ${BASENAME}_sense_mag_all_reps"
echo "  Combined VENC sets: ${BASENAME}_sense_mag_all_vencs"
echo "  Sample image: ${BASENAME}_sense_mag_sample.png"
