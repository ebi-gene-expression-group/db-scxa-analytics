#!/usr/bin/env bash

# This script takes the marker genes data, normally available in an irap
# sc_bundle, which is split in different files one per k_value (number of clusters)
# and loads it into the scxa_marker_genes table of AtlasProd.
set -e

# TODO this type of function should be loaded from a common set of scripts.

scriptDir=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $scriptDir/db_scxa_common.sh

dbConnection=${dbConnection:-$1}
EXP_ID=${EXP_ID:-$2}
EXPERIMENT_TSNE_PATH=${EXPERIMENT_TSNE_PATH:-$3}
TSNE_PREFIX=${TSNE_PREFIX:-"$EXP_ID.tsne_perp_"}
TSNE_SUFFIX=${TSNE_SUFFIX:-".tsv"}

# Check that necessary environment variables are defined.
[ ! -z ${dbConnection+x} ] || (echo "Env var dbConnection for the database connection needs to be defined. This includes the database name." && exit 1)
[ ! -z ${EXP_ID+x} ] || (echo "Env var EXP_ID for the id/accession of the experiment needs to be defined." && exit 1)
[ ! -z ${EXPERIMENT_TSNE_PATH+x} ] || (echo "Env var EXPERIMENT_TSNE_PATH for location of marker genes files for web needs to be defined." && exit 1)

# Check that files are in place.
[ $(ls -1q $EXPERIMENT_TSNE_PATH/$TSNE_PREFIX*$TSNE_SUFFIX | wc -l) -gt 0 ] \
  || (echo "No tsne tsv files could be found on $EXPERIMENT_TSNE_PATH" && exit 1)

# Check that database connection is valid
checkDatabaseConnection $dbConnection

# Delete tsne table content for current EXP_ID
echo "Marker genes: Delete rows for $EXP_ID:"
echo "DELETE FROM scxa_tsne WHERE experiment_accession = \'$EXP_ID\'" | \
  psql $dbConnection

# Create file with data
# Please note that this relies on:
# - Column ordering on the marker genes file: tSNE_1 tSNE_2 Label
# - Table ordering of columns: experiment_accession cell_id x y perplexity
echo "Marker genes: Create data file for $EXP_ID..."
rm -f $EXPERIMENT_TSNE_PATH/tsneDataToLoad.csv
for f in $(ls $EXPERIMENT_TSNE_PATH/$TSNE_PREFIX*$TSNE_SUFFIX); do
  persp=$(echo $f | sed s+$EXPERIMENT_TSNE_PATH/$TSNE_PREFIX++ | sed s/$TSNE_SUFFIX// )
  tail -n +2 $f | awk -F'\t' -v EXP_ID="$EXP_ID" -v persp_value="$persp" 'BEGIN { OFS = ","; }
  { print EXP_ID, $3, $1, $2, persp_value }' >> $EXPERIMENT_TSNE_PATH/tsneDataToLoad.csv
done

# Load data
echo "TSNE: Loading data for $EXP_ID..."
printf "\copy scxa_tsne (experiment_accession, cell_id, x, y, perplexity) FROM '%s' WITH (DELIMITER ',');" $EXPERIMENT_TSNE_PATH/tsneDataToLoad.csv | \
  psql $dbConnection

rm $EXPERIMENT_TSNE_PATH/tsneDataToLoad.csv

echo "TSNE: Loading done for $EXP_ID..."
