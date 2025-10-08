#!/bin/bash

# dat2bart.sh - Convert Siemens .dat file to BART format
# Usage: dat2bart.sh <datfile_fullpath>
# Output: Creates BART files for each dataset in the .dat file

set -e  # Exit on any error

# Check arguments
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <datfile_fullpath> [-f]"
    echo "Example: $0 /path/to/meas_MID00203_FID02135_vfMRI_multiVENC_maxFlow_2_4_6_8_10cmPs.dat"
    echo "         $0 /path/to/meas_MID00203_FID02135_vfMRI_multiVENC_maxFlow_2_4_6_8_10cmPs.dat -f"
    echo ""
    echo "Options:"
    echo "  -f    Force recreation of .info file and BART files (overwrite existing)"
    exit 1
fi

DATFILE="$1"
FORCE_FLAG=""
if [ $# -eq 2 ] && [ "$2" = "-f" ]; then
    FORCE_FLAG="true"
fi

# Check if file exists
if [ ! -f "$DATFILE" ]; then
    echo "Error: File $DATFILE does not exist"
    exit 1
fi

# Get basename for output files
BASENAME=$(basename "$DATFILE" .dat)
OUTPUT_DIR="/scratch/users/Proulx-S/tools/bassRecon/tmp"

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo "Converting Siemens .dat file to BART format..."
echo "Input file: $DATFILE"
echo "Output directory: $OUTPUT_DIR"
echo ""

# Load BART module
ml bart

# Check if .info file exists, if not create it (or recreate if force flag is set)
INFO_FILE="${DATFILE%.dat}.info"
if [ ! -f "$INFO_FILE" ] || [ "$FORCE_FLAG" = "true" ]; then
    if [ "$FORCE_FLAG" = "true" ] && [ -f "$INFO_FILE" ]; then
        echo "Force flag set - recreating info file: $INFO_FILE"
        rm -f "$INFO_FILE"
    fi
    
    echo "Reading dimensions from .dat file (this is slow because it relies on mapVBVD.m)..."
    matlab -batch "read_twix_dims('$DATFILE')" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to read dimensions from $DATFILE"
        exit 1
    fi
    
    if [ ! -f "$INFO_FILE" ]; then
        echo "Error: Info file was not created: $INFO_FILE"
        exit 1
    fi
    
    echo "Info file created: $INFO_FILE"
else
    echo "Using existing info file: $INFO_FILE"
fi

# Read dimensions from info file
DIM_INFO=$(cat "$INFO_FILE")

# Check if we got valid dimension information
if [ -z "$DIM_INFO" ] || ! echo "$DIM_INFO" | grep -q "Number of datasets found:"; then
    echo "Error: No valid dimension information in info file"
    echo "Info file contents: $DIM_INFO"
    exit 1
fi

# Extract number of datasets from info file
NUM_DATASETS=$(echo "$DIM_INFO" | grep "Number of datasets found:" | cut -d':' -f2 | tr -d ' ')

if [ -z "$NUM_DATASETS" ]; then
    echo "Error: Could not determine number of datasets"
    exit 1
fi

echo "Found $NUM_DATASETS datasets in the .dat file"
echo ""

# Convert each dataset
for i in $(seq 1 $NUM_DATASETS); do
    # Use simple sequential naming
    OUTPUT_FILE="$OUTPUT_DIR/${BASENAME}_dataset${i}"
    
    # Check if BART files already exist
    if [ -f "${OUTPUT_FILE}.cfl" ] && [ -f "${OUTPUT_FILE}.hdr" ] && [ "$FORCE_FLAG" != "true" ]; then
        echo "Dataset $i already exists: ${BASENAME}_dataset${i}"
        echo "  Skipping conversion (use -f flag to force recreation)"
        continue
    fi
    
    if [ "$FORCE_FLAG" = "true" ] && [ -f "${OUTPUT_FILE}.cfl" ]; then
        echo "Force flag set - removing existing dataset $i files"
        rm -f "${OUTPUT_FILE}".*
    fi
    
    echo "Converting dataset $i..."
    
    # Extract dimensions for this dataset from MATLAB output
    DATASET_INFO=$(echo "$DIM_INFO" | sed -n "/Dataset $i:/,/Dataset $((i+1)):/p" | head -n -1)
    
    READOUT=$(echo "$DATASET_INFO" | grep "Readout:" | sed 's/.*Readout: \([0-9]*\).*/\1/')
    PHASE=$(echo "$DATASET_INFO" | grep "Phase:" | sed 's/.*Phase: \([0-9]*\).*/\1/')
    COIL=$(echo "$DATASET_INFO" | grep "Coil:" | sed 's/.*Coil: \([0-9]*\).*/\1/')
    VENC_SIZE=$(echo "$DATASET_INFO" | grep "Set:" | sed 's/.*Set: \([0-9]*\).*/\1/')
    REP_SIZE=$(echo "$DATASET_INFO" | grep "Rep:" | sed 's/.*Rep: \([0-9]*\).*/\1/')
    SLICE=$(echo "$DATASET_INFO" | grep "Slice:" | sed 's/.*Slice: \([0-9]*\).*/\1/')
    
    echo "  Dimensions: Readout=$READOUT, Phase=$PHASE, Coil=$COIL, VENC=$VENC_SIZE, Rep=$REP_SIZE, Slice=$SLICE"
    
    # Convert using explicit dimensions for all datasets
    # This ensures we get the correct dataset each time
    bart twixread -X -x $READOUT -y $PHASE -c $COIL -n $REP_SIZE -f $VENC_SIZE "$DATFILE" "$OUTPUT_FILE"
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to convert dataset $i"
        exit 1
    fi
    
    echo "  Conversion successful!"
done

echo ""
echo "Output files: $OUTPUT_DIR"
for file in "$OUTPUT_DIR/${BASENAME}_dataset"*.cfl; do
    if [ -f "$file" ]; then
        basename_file=$(basename "$file" .cfl)
        echo "  $basename_file"
        bart show -m "${file%.cfl}"
    fi
done

echo ""
echo "File sizes:"
ls -lh "$OUTPUT_DIR/${BASENAME}_"*.* 2>/dev/null

echo ""
echo "To check dimensions of any file, run:"
echo "  bart show -m <filename>"
