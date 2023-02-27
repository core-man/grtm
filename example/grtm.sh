#!/usr/bin/env bash

# a distance of 100 km for a surface source
./grtm.pl -Mcrust1.0/0 -N10/0.04  100
# a distance of 100 km for a 10 km depth source
./grtm.pl -Mcrust1.0/10 -N10/0.04  100
