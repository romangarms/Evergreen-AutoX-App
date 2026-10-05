#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

ENV_FILE=.env
APPLE_TEAM_ID_DEFAULT=98GQ88N9TN

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
  read-key       Print the key the website sends to read unlisted leaderboards.
  new-read-key   Replace that key. The website stops seeing unlisted boards
                 until it is rebuilt with the new one.
  apple-key FILE [KEY_ID]
                 Store a Sign in with Apple key (the AuthKey_XXXXXXXXXX.p8
                 downloaded from the developer portal) so deleting an account
                 revokes its Apple sign-in. The key ID is read from the file
                 name unless given.
  help           Show this message.

Credentials live in $ENV_FILE (gitignored) as LEADERBOARD_ADMIN_USER,
LEADERBOARD_ADMIN_PASSWORD, LEADERBOARD_READ_KEY and the APPLE_ values. Restart
the server after changing them.
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

write_read_key() {
    local tmp
    tmp=$(mktemp)
    if [ -f "$ENV_FILE" ]; then
        grep -v '^LEADERBOARD_READ_KEY=' "$ENV_FILE" > "$tmp" || true
    fi
    printf "LEADERBOARD_READ_KEY='%s'\n" "$(openssl rand -hex 24)" >> "$tmp"
    mv "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

ensure_read_key() {
    [ -n "$(env_value LEADERBOARD_READ_KEY)" ] || write_read_key
}

write_apple_key() {
    local file=$1 key_id=$2 name tmp
    if [ -z "$file" ] || [ ! -f "$file" ]; then
        echo "Usage: ./start.sh apple-key path/to/AuthKey_XXXXXXXXXX.p8 [KEY_ID]" >&2
        exit 1
    fi
    if ! openssl pkey -in "$file" -noout 2>/dev/null; then
        echo "$file is not a private key. It should be the .p8 file from the developer portal." >&2
        exit 1
    fi
    if [ -z "$key_id" ]; then
        name=$(basename "$file" .p8)
        key_id=${name#AuthKey_}
    fi
    if [[ ! "$key_id" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "Could not read a 10-character key ID from the file name; pass it as the second argument." >&2
        exit 1
    fi
    tmp=$(mktemp)
    if [ -f "$ENV_FILE" ]; then
        grep -v '^APPLE_\(TEAM_ID\|KEY_ID\|PRIVATE_KEY\)=' "$ENV_FILE" > "$tmp" || true
    fi
    # The whole PEM, BEGIN and END lines included, on one line with a literal
    # \n at each line break; server/apple.py turns those back into newlines.
    printf "APPLE_TEAM_ID='%s'\nAPPLE_KEY_ID='%s'\nAPPLE_PRIVATE_KEY='%s'\n" \
        "$APPLE_TEAM_ID_DEFAULT" "$key_id" "$(awk 'NF {printf "%s\\n", $0}' "$file")" >> "$tmp"
    mv "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "Saved key $key_id to $ENV_FILE. Restart the server to pick it up (./start.sh)."
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
        ensure_read_key
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
        ensure_read_key
        run_local
        ;;
    set-password)
        prompt_credentials
        echo "Restart the server to pick up the change (./start.sh)."
        ;;
    read-key)
        ensure_read_key
        env_value LEADERBOARD_READ_KEY
        ;;
    new-read-key)
        write_read_key
        env_value LEADERBOARD_READ_KEY
        echo "Restart the server (./start.sh), then rebuild the website with this key." >&2
        ;;
    apple-key)
        write_apple_key "$2" "$3"
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
