#!/usr/bin/env bash

# This script takes the matrix market format files (normally available on
# staging) for a single cell experiment and does the following steps:
# - Transforms those files into a long (melted) table of experiment id,
#   cell/run id, and expression. This takes care of avoiding large chunks of
#   data being kept in memory for long, at the expense of writing to disk (too)
#   often.
# - Creates a partition table on postgres (requires postgres 10) for the
#   experiment (deleting previous partitions for the experiment.)
# - Loads transformed data into the partition table.
# - Postprocess table and attach it to the main scxa-analytics table.
set -e

scriptDir=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $scriptDir/db_scxa_common.sh

postgres_scripts_dir=$scriptDir/../postgres_routines

dbConnection=${dbConnection:-$1}
EXP_ID=${EXP_ID:-$2}
EXPERIMENT_MATRICES_PATH=${EXPERIMENT_MATRICES_PATH:-$3}
EXPRESSION_TYPE=${EXPRESSION_TYPE:-"aggregated_filtered_normalised_counts"}

# Check that necessary environment variables are defined.
[ -z ${dbConnection+x} ] && echo "Env var dbConnection for the database connection needs to be defined. This includes the database name." && exit 1
[ -z ${EXP_ID+x} ] && echo "Env var EXP_ID for the id/accession of the experiment needs to be defined." && exit 1
[ -z ${EXPERIMENT_MATRICES_PATH+x} ] && echo "Env var EXPERIMENT_MATRICES_PATH for location of SC experiment for web needs to be defined." && exit 1

# Check that files are in place.
matrix_path=$EXPERIMENT_MATRICES_PATH/$EXP_ID\.$EXPRESSION_TYPE\.mtx.gz
genes_path=$EXPERIMENT_MATRICES_PATH/$EXP_ID\.$EXPRESSION_TYPE\.mtx_rows.gz
runs_path=$EXPERIMENT_MATRICES_PATH/$EXP_ID\.$EXPRESSION_TYPE\.mtx_cols.gz
for f in $matrix_path $genes_path $runs_path; do
  [ ! -e $f ] && echo "$EXP_ID: Matrix file $f missing, exiting." && exit 1
done

# Check that database connection is valid
checkDatabaseConnection $dbConnection

# Transform experiment accession so that it can be used as a table name.
lc_exp_acc=$(echo $EXP_ID | tr '[:upper:]' '[:lower:]' | sed 's/-/_/g')
# Delete partition for experiment if already exists
sed "s/<EXP-ACCESSION>/$lc_exp_acc/" $postgres_scripts_dir/01-delete_existing_partition.sql.template | \
psql -v ON_ERROR_STOP=1 $dbConnection

# Create file with data
matrixMarket2csv.js -m $matrix_path \
                    -r $genes_path \
                    -c $runs_path \
                    -e $EXP_ID \
                    -s 50000 \
                    -o $EXPERIMENT_MATRICES_PATH/expression2load.csv


# Create and load partition table in the same transaction.
sed "s/<EXP-ACCESSION>/$lc_exp_acc/" $postgres_scripts_dir/02-create_and_load_partition_table.sql.template | \
    sed "s+<PATH-TO-DATA>+$EXPERIMENT_MATRICES_PATH/expression2load.csv+" | \
    psql -v ON_ERROR_STOP=1 $dbConnection

rm $EXPERIMENT_MATRICES_PATH/expression2load.csv

# Create primary key.
echo "Create PK"
time sed "s/<EXP-ACCESSION>/$lc_exp_acc/g" $postgres_scripts_dir/04-build_pk.sql.template | \
    psql -v ON_ERROR_STOP=1 $dbConnection

# Post-process partition table
sed "s/<EXP-ACCESSION>/$lc_exp_acc/g" $postgres_scripts_dir/05-post_processing.sql.template | \
    sed "s/<EXP-ACC-UC>/$EXP_ID/g" | \
    psql -v ON_ERROR_STOP=1 $dbConnection

echo "Post-processing done"

# Attach partition
sed "s/<EXP-ACCESSION>/$lc_exp_acc/g" $postgres_scripts_dir/06-attach_partition.sql.template | \
    sed "s/<EXP-ACC-UC>/$EXP_ID/g" | \
    psql -v ON_ERROR_STOP=1 $dbConnection

echo "Partition table loaded for experiment $EXP_ID succesfully."
