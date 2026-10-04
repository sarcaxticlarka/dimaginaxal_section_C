#!/bin/bash

echo "======================================"
echo " HTTP Cache-Control Test"
echo "======================================"

URL="https://app.dimaginaxal.test/api/status"

echo ""
echo "Checking response headers..."
echo ""

curl -I "$URL"

echo ""
echo "Expected:"
echo "Cache-Control: public, max-age=60"