#!/bin/bash

echo "======================================"
echo " Private DNS Test"
echo "======================================"

DNS_SERVER="10.7.2.83"
DOMAIN="app.dimaginaxal.test"

echo ""
echo "DNS Server : $DNS_SERVER"
echo "Domain     : $DOMAIN"
echo ""

dig @"$DNS_SERVER" "$DOMAIN"

echo ""
echo "Expected IP: 10.7.1.138"