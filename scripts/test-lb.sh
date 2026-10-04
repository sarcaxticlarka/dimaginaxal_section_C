#!/bin/bash

echo "======================================"
echo " HTTPS Load Balancing Test"
echo "======================================"

URL="https://app.dimaginaxal.test/api/status"

for i in 1 2 3 4 5 6
do
    echo "Request $i:"
    curl -s "$URL"
    echo ""
done