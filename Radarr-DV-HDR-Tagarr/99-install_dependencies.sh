#!/bin/bash

# Check if apt-get is available
if command -v apt-get &> /dev/null; then
    echo "Using apt-get to install dependencies..."
    apt-get update && \
    apt-get install -y jq ffmpeg && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
# Check if apk is available (Alpine Linux)
elif command -v apk &> /dev/null; then
    echo "Using apk to install dependencies..."
    apk update && \
    apk add jq ffmpeg wget && \
    rm -rf /var/cache/apk/*
else
    echo "No known package manager found (apt-get or apk). Cannot install dependencies."
    exit 1
fi

# Install dovi_tool
wget -O /tmp/dovi_tool.tar.gz https://github.com/quietvoid/dovi_tool/releases/download/2.1.2/dovi_tool-2.1.2-x86_64-unknown-linux-musl.tar.gz
tar -xzf /tmp/dovi_tool.tar.gz -C /usr/local/bin/
rm /tmp/dovi_tool.tar.gz

echo "Installation complete."

