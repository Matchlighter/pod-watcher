#!/usr/bin/env bash
set -e

echo "Installing dependencies..."
shards install

echo "Building Crystal pod-watcher..."
crystal build --release main.cr -o pod-watcher

echo "Build complete! Binary: ./pod-watcher"
echo "Binary size:"
ls -lh pod-watcher
