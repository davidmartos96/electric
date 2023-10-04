#!/bin/sh

set -e

NUM_RUNS=30

TEST_TO_RUN="tests/03.04_node_satellite_correctly_updates_serialization_caches.lux"

for i in $(seq 1 $NUM_RUNS) ; do
  echo "Run $i of $NUM_RUNS"
  
  TEST=$TEST_TO_RUN make single_test
done

echo "Done!"
