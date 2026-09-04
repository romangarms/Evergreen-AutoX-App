#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

ENV_FILE=.env

usage() {
    cat <<EOF
Usage: ./start.sh [command]

  (none)         Set up and start the server on port 8321. Prompts for the
                 leaderboard admin password if .env has none, then runs
                 "docker compose up -d --build" when Docker Compose is
                 available, or the local virtualenv server otherwise.
  local          Always run from the local virtualenv (foreground), creating
                 .venv on first use. Handy for development.
  set-password   Set or change the leaderboard admin username/password in .env.
  help           Show this message.

Credentials live in $ENV_FILE (gitignored) as LEADERBOARD_ADMIN_USER and
LEADERBOARD_ADMIN_PASSWORD. Restart the server after changing them.
EOF
}

env_value() {
    [ -f "$ENV_FILE" ] || return 0
    sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | sed "s/^'\(.*\)'$/\1/"
}

has_password() {
    [ -n "$(env_value LEADERBOARD_ADMIN_PASSWORD)" ]
}

write_env() {
    local user=$1 password=$2 tmp
    tmp=$(mktemp)
    if [ -f "$ENV_FILE" ]; then
        grep -v '^LEADERBOARD_ADMIN_\(USER\|PASSWORD\)=' "$ENV_FILE" > "$tmp" || true
    fi
    printf "LEADERBOARD_ADMIN_USER='%s'\nLEADERBOARD_ADMIN_PASSWORD='%s'\n" "$user" "$password" >> "$tmp"
    mv "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

prompt_credentials() {
    if [ ! -t 0 ]; then
        echo "No leaderboard admin password in $ENV_FILE and no terminal to ask for one." >&2
        echo "Run ./start.sh set-password interactively, or add LEADERBOARD_ADMIN_PASSWORD to $ENV_FILE." >&2
        exit 1
    fi
    local current_user user p1 p2
    current_user=$(env_value LEADERBOARD_ADMIN_USER)
    echo "Leaderboard edits (dev console, API writes) need an admin login."
    read -r -p "Username [${current_user:-admin}]: " user
    user=${user:-${current_user:-admin}}
    while true; do
        read -r -s -p "Password: " p1; echo
        read -r -s -p "Confirm password: " p2; echo
        if [ -z "$p1" ]; then
            echo "Password cannot be empty."
        elif [ "$p1" != "$p2" ]; then
            echo "Passwords do not match, try again."
        elif [[ "$p1" == *"'"* ]]; then
            echo "Password cannot contain a single quote (')."
        else
            break
        fi
    done
    write_env "$user" "$p1"
    echo "Saved to $ENV_FILE (user: $user)."
}

ensure_password() {
    has_password || prompt_credentials
}

ensure_venv() {
    if [ ! -d .venv ]; then
        echo "Creating virtualenv and installing dependencies..."
        python3 -m venv .venv
        ./.venv/bin/pip install -r requirements.txt
    fi
}

load_env() {
    set -a
    # shellcheck disable=SC1090
    . "./$ENV_FILE"
    set +a
}

run_local() {
    ensure_venv
    load_env
    exec ./.venv/bin/python server/app.py
}

case "${1:-start}" in
    start)
        ensure_password
        if docker compose version >/dev/null 2>&1; then
            echo "Starting with Docker Compose..."
            docker compose up -d --build
        else
            echo "Docker Compose not found, running from the local virtualenv."
            run_local
        fi
        ;;
    local)
        ensure_password
        run_local
        ;;
    set-password)
        prompt_credentials
        echo "Restart the server to pick up the change (./start.sh)."
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        echo "Unknown command: $1" >&2
        usage >&2
        exit 1
        ;;
esac
