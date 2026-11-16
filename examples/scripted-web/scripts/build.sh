#!/bin/sh
set -eu
# Runs in the Dockerfile's Linux build stage, with /src as the working directory.
mkdir -p dist
cp -R public/. dist/
printf 'Built on %s\n' "$(uname -s)" > dist/build.txt
