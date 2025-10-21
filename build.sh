#!/bin/bash

if ! command -v odin &> /dev/null; then
    echo "Error: Odin compiler not found. Please install Odin first."
    exit 1
fi

mkdir -p bin

echo "Building HandMade Text Editor..."
odin build . -out:bin/editor -o:speed -debug

if [ $? -eq 0 ]; then
    echo "Program built successfully: ./bin/editor"
else
    echo "Failed to build"
    exit 1
fi
echo ""
