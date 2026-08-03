#!/bin/sh

usage() {
    echo "Usage: $0 [--appid ID] <host>"
}

HOST=
APPID=
BUILD_DIR=build-sync

while [ "$#" -gt 0 ]; do
    case "$1" in
        --appid)
            if [ "$#" -lt 2 ]; then
                echo "--appid requires a Steam application ID" >&2
                usage >&2
                exit 1
            fi
            APPID=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [ -n "$HOST" ]; then
                echo "Only one host may be specified" >&2
                usage >&2
                exit 1
            fi
            HOST=$1
            shift
            ;;
    esac
done

if [ -z "$HOST" ]; then
    usage >&2
    exit 1
fi

case "$APPID" in
    "") ;;
    0|*[!0-9]*)
        echo "Invalid Steam application ID: $APPID" >&2
        exit 1
        ;;
esac

set -e

if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    meson setup "$BUILD_DIR" -Dmangoapp=true
else
    meson configure "$BUILD_DIR" -Dmangoapp=true
fi
ninja -C "$BUILD_DIR"

ssh "$HOST" mkdir -p ./deploy
scp \
    "$BUILD_DIR/src/mangoapp" \
    "$BUILD_DIR/src/libMangoHud.so" \
    "$BUILD_DIR/src/libMangoHud_opengl.so" \
    "$BUILD_DIR/src/libMangoHud_shim.so" \
    "${HOST}:deploy/"

ssh "$HOST" /bin/bash -s -- "$APPID" <<'EOF'
    set -e

    appid=$1
    deploy_dir="$HOME/deploy"
    steam_pipe="$HOME/.steam/steam.pipe"
    old_steam_pids=
    cleanup() {
        rm -f \
            "$deploy_dir/mangoapp" \
            "$deploy_dir/libMangoHud.so" \
            "$deploy_dir/libMangoHud_opengl.so" \
            "$deploy_dir/libMangoHud_shim.so"
        rmdir "$deploy_dir" 2>/dev/null || true
    }
    trap cleanup EXIT

    if [ -n "$appid" ]; then
        old_steam_pids=$(lsof -t "$steam_pipe" 2>/dev/null || true)
    fi

    sudo rpm-ostree usroverlay || true
    sudo install -m 755 "$deploy_dir/mangoapp" /usr/bin/mangoapp
    sudo install -m 755 "$deploy_dir/libMangoHud.so" /usr/lib64/mangohud/libMangoHud.so
    sudo install -m 755 "$deploy_dir/libMangoHud_opengl.so" /usr/lib64/mangohud/libMangoHud_opengl.so
    sudo install -m 755 "$deploy_dir/libMangoHud_shim.so" /usr/lib64/mangohud/libMangoHud_shim.so

    if ! mountpoint -q /etc/plasmalogin.conf; then
        sudo cp --preserve=context /etc/plasmalogin.conf /run/plasmalogin.conf
        sudo sed -i '/^\[Autologin\]$/a Relogin=true' /run/plasmalogin.conf
        sudo mount --bind /run/plasmalogin.conf /etc/plasmalogin.conf
    fi
    sudo systemctl restart plasmalogin
    pkill mangoapp || true

    if [ -n "$appid" ]; then
        attempts=0
        while :; do
            steam_pid=$(lsof -t "$steam_pipe" 2>/dev/null | head -n 1 || true)
            if [ -n "$steam_pid" ] && ! printf '%s\n' "$old_steam_pids" | grep -Fxq "$steam_pid"; then
                break
            fi

            attempts=$((attempts + 1))
            if [ "$attempts" -ge 120 ]; then
                echo "Timed out waiting for Steam to accept launch requests" >&2
                exit 1
            fi
            sleep 0.5
        done

        game_uri="steam://rungameid/$appid"
        if ! timeout 5 sh -c 'printf "%s\n" "$1" > "$2"' sh "$game_uri" "$steam_pipe"; then
            echo "Failed to send Steam launch request for app $appid" >&2
            exit 1
        fi
        echo "Requested Steam app $appid"
    fi
EOF
