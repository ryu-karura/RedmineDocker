#!/usr/bin/env bash

set -u

COMPOSE_FILE="compose.dev.yaml"

detect_runtime() {
    if command -v podman >/dev/null 2>&1; then
        echo "podman"
    elif command -v docker >/dev/null 2>&1; then
        echo "docker"
    else
        echo "NONE"
    fi
}

pause() {
    echo ""
    read -r -p "Enterで戻る > "
}

compose_cmd() {
    "$RUNTIME" compose -f "$COMPOSE_FILE" "$@"
}

show_containers() {
    echo ""
    echo "===== Container Status ====="
    "$RUNTIME" ps -a \
        --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}"
}

show_images() {
    echo ""
    echo "===== Image List ====="
    "$RUNTIME" images \
        --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Created}}\t{{.Size}}"
}

select_container_id() {
    mapfile -t CONTAINERS < <(
        "$RUNTIME" ps -a \
        --format "{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}"
    )

    [ "${#CONTAINERS[@]}" -eq 0 ] && return 1

    echo ""
    echo "===== Select Container ====="

    local i=1
    for row in "${CONTAINERS[@]}"; do
        IFS='|' read -r cid name status image <<< "$row"
        printf "%2d : %-12s %-20s %-20s %s\n" \
            "$i" "$cid" "$name" "$status" "$image"
        i=$((i + 1))
    done

    echo ""
    read -r -p "番号入力 > " no

    [[ "$no" =~ ^[0-9]+$ ]] || return 1

    if [ "$no" -lt 1 ] || [ "$no" -gt "${#CONTAINERS[@]}" ]; then
        return 1
    fi

    IFS='|' read -r SELECTED_CONTAINER_ID _ \
        <<< "${CONTAINERS[$((no - 1))]}"

    return 0
}

select_image_id() {
    mapfile -t IMAGES < <(
        "$RUNTIME" images \
        --format "{{.Repository}}|{{.Tag}}|{{.ID}}|{{.Size}}"
    )

    [ "${#IMAGES[@]}" -eq 0 ] && return 1

    echo ""
    echo "===== Select Image ====="

    local i=1
    for row in "${IMAGES[@]}"; do
        IFS='|' read -r repo tag iid size <<< "$row"

        printf "%2d : %-12s %-45s %s\n" \
            "$i" "$iid" "${repo}:${tag}" "$size"

        i=$((i + 1))
    done

    echo ""
    read -r -p "番号入力 > " no

    [[ "$no" =~ ^[0-9]+$ ]] || return 1

    if [ "$no" -lt 1 ] || [ "$no" -gt "${#IMAGES[@]}" ]; then
        return 1
    fi

    IFS='|' read -r _ _ SELECTED_IMAGE_ID _ \
        <<< "${IMAGES[$((no - 1))]}"

    return 0
}

show_usage() {
    cat <<EOF

Usage:
  ./menu.sh

  ./menu.sh ps
  ./menu.sh logs

  ./menu.sh up
  ./menu.sh stop
  ./menu.sh restart
  ./menu.sh down

  ./menu.sh build
  ./menu.sh rebuild

  ./menu.sh images
  ./menu.sh prune

  ./menu.sh cstop
  ./menu.sh crm
  ./menu.sh crmf

  ./menu.sh rmi

EOF
}

run_action() {

    case "$1" in

        11|ps)
            show_containers
            ;;

        12|logs)
            compose_cmd logs -f
            ;;

        21|up)
            compose_cmd up -d
            ;;

        22|stop)
            compose_cmd stop
            ;;

        23|restart)
            compose_cmd restart
            ;;

        24|down)
            compose_cmd down
            ;;

        25|cstop)
            if select_container_id; then
                "$RUNTIME" stop "$SELECTED_CONTAINER_ID"
            fi
            ;;

        26|crm)
            if select_container_id; then
                "$RUNTIME" rm "$SELECTED_CONTAINER_ID"
            fi
            ;;

        27|crmf)
            if select_container_id; then
                "$RUNTIME" rm -f "$SELECTED_CONTAINER_ID"
            fi
            ;;

        31|build)
            compose_cmd build
            ;;

        32|rebuild)
            compose_cmd up --build -d
            ;;

        41|images)
            show_images
            ;;

        42|prune)
            "$RUNTIME" image prune
            ;;

        43|rmi)
            if select_image_id; then
                "$RUNTIME" rmi "$SELECTED_IMAGE_ID"
            fi
            ;;

        99|exit|quit)
            exit 0
            ;;

        help|-h|--help)
            show_usage
            ;;

        *)
            echo "無効な指定: $1"
            show_usage
            return 1
            ;;
    esac
}

main_menu() {

    clear

    echo ""
    echo "Runtime : $RUNTIME"

    show_containers
    show_images

    echo ""
    echo "======================================"
    echo "[操作したい番号]：コマンド：操作内容"
    echo "======================================"
    echo "11：ps                    ：コンテナ一覧"
    echo "12：logs -f               ：ログ監視"
    echo "21：compose up -d         ：起動"
    echo "22：compose stop          ：停止"
    echo "23：compose restart       ：再起動"
    echo "24：compose down          ：削除"
    echo "25：stop [選択ID]         ：コンテナ停止"
    echo "26：rm [選択ID]           ：コンテナ削除"
    echo "27：rm -f [選択ID]        ：コンテナ強制削除"
    echo "31：compose build         ：ビルド"
    echo "32：compose up --build -d ：ビルド＋起動"
    echo "41：images                ：イメージ一覧"
    echo "42：image prune           ：dangling削除"
    echo "43：rmi [選択ID]          ：イメージ削除"
    echo "99：終了"
    echo "======================================"
    echo ""

    read -r -p "番号入力 > " N

    case "$N" in
        12)
            run_action "$N"
            ;;
        99)
            exit 0
            ;;
        *)
            run_action "$N"
            pause
            ;;
    esac
}

RUNTIME="$(detect_runtime)"

if [ "$RUNTIME" = "NONE" ]; then
    echo ""
    echo "ERROR : docker / podman が見つかりません"
    exit 1
fi

if [ $# -gt 0 ]; then
    run_action "$1"
    exit $?
fi

while true; do
    main_menu
done


