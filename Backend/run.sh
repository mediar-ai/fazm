#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building Fazm Backend..."
cargo build

echo "Starting Fazm Backend on :8080..."
cargo run
