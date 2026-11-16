#!/usr/bin/env bash
# Runs all tests. Start the server first: ./http_server 8080
PORT=${1:-8080}

echo "########## Part 1: file server"
./test_server.sh "$PORT"; r1=$?

echo
echo "########## Part 2: pub-sub broker"
./test_broker.sh "$PORT"; r2=$?

echo
[ $r1 -eq 0 ] && [ $r2 -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"