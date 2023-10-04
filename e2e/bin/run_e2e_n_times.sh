#!/bin/sh

set -e

NUM_RUNS=30

NEW_TESTS_DIR="custom_tests"
rm -rf "$NEW_TESTS_DIR"
mkdir "$NEW_TESTS_DIR"

cp tests/_satellite_macros.luxinc $NEW_TESTS_DIR
cp tests/_shared.luxinc $NEW_TESTS_DIR
cp tests/compose.yaml $NEW_TESTS_DIR
cp tests/Makefile $NEW_TESTS_DIR

for i in $(seq 1 $NUM_RUNS) ; do
    cp tests/03.04_node_satellite_correctly_updates_serialization_caches.lux $NEW_TESTS_DIR/$i.lux
done

TEST="custom_tests" make single_test

rm -rf "$NEW_TESTS_DIR"

echo "Done!"
