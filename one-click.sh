#!/bin/sh
set -eu
REPO_RAW="${MIERUSH_REPO_RAW:-https://raw.githubusercontent.com/HlONGlin/mierush/main}"
BIN=/usr/local/bin/mierush
install_manager() (
    [ "$(id -u)" = 0 ] || { printf '请使用 root 运行\n' >&2; exit 1; }
    if ! command -v curl >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then apk add --no-cache curl ca-certificates
        elif command -v apt-get >/dev/null 2>&1; then apt-get update; apt-get install -y curl ca-certificates
        elif command -v dnf >/dev/null 2>&1; then dnf install -y curl ca-certificates
        elif command -v yum >/dev/null 2>&1; then yum install -y curl ca-certificates
        else printf '请先安装 curl\n' >&2; exit 1; fi
    fi
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    curl -fL --retry 3 --connect-timeout 15 "$REPO_RAW/mierush.sh" -o "$work/mierush.sh"
    grep -q '^MIERUSH_VERSION=' "$work/mierush.sh"
    sh -n "$work/mierush.sh"
    # Install from its temporary path: the main script copies itself after setup.
    sh "$work/mierush.sh" install
)
run_manager() {
    [ -x "$BIN" ] || { printf '请先安装 mierush\n' >&2; return 1; }
    "$BIN" "$@"
}
case "${1:-menu}" in
    install) install_manager ;;
    start|stop|restart|status) run_manager "$1" ;;
    reset) run_manager reset-credentials ;;
    purge) run_manager uninstall ;;
    menu)
        while :; do
            printf '\n=== mierush 一键部署 ===\n1. 安装/更新\n2. 启动\n3. 停止\n4. 彻底卸载\n5. 重置节点凭据\n6. 节点管理面板\n0. 退出\n选项: '
            IFS= read -r choice || exit 0
            case "$choice" in
                1) sh "$0" install || true ;; 2) run_manager start || true ;;
                3) run_manager stop || true ;; 4) run_manager uninstall || true ;;
                5) run_manager reset-credentials || true ;; 6) run_manager menu || true ;;
                0) exit ;; *) printf '无效选项\n' ;;
            esac
        done ;;
    *) printf '用法: one-click.sh [install|start|stop|restart|status|reset|purge|menu]\n'; exit 1 ;;
esac
