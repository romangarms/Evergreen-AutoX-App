#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

if [ ! -d .venv ]; then
    echo "Creating virtualenv and installing dependencies..."
    python3 -m venv .venv
    ./.venv/bin/pip install -r requirements.txt
fi

exec ./.venv/bin/python server/app.py
