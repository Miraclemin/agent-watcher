#!/bin/bash
set -e
cd "$(dirname "$0")/bridge"
echo "Installing Agent Watcher bridge dependencies..."
npm install
echo "Setup complete."
