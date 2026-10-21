#!/bin/sh
# mierush - POSIX sh terminal manager for the official mieru server (mita).
set -eu
umask 077
MIERUSH_VERSION="1.0.0"
DATA="${MIERUSH_DATA_DIR:-/etc/mierush}"
MITA="${MIERUSH_MITA_BIN:-/usr/local/bin/mita}"
SELF="/usr/local/bin/mierush"
RELEASE="${MIERUSH_CORE_VERSION:-3.38.1}"
DOWNLOAD_BASE="${MIERUSH_DOWNLOAD_BASE:-https://github.com/enfein/mieru/releases/download}"

say() { printf '%s\n' "$*"; }
die() { say "错误: $*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
root() { [ "$(id -u)" = 0 ] || die "请使用 root 运行"; }
deps() { has jq || die "缺少 jq，请先运行 install"; }
init_data() {
    mkdir -p "$DATA/nodes" "$DATA/runtime"
    chmod 700 "$DATA" "$DATA/nodes" "$DATA/runtime"
    if [ ! -f "$DATA/settings.json" ]; then
        printf '%s\n' '{"host":"","mtu":1400,"seed":42}' > "$DATA/settings.json"
    fi
}
ask() {
    printf '%s' "$1" >&2
    IFS= read -r answer || return 1
    printf '%s' "$answer"
}
pause() { ask '按回车返回...' >/dev/null || true; }
number() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
port_ok() { number "$1" && [ "$1" -ge 1025 ] && [ "$1" -le 65535 ]; }
node_file() {
    case "$1" in ''|*[!0-9a-f]*) die "无效节点 ID" ;; esac
    NODE="$DATA/nodes/$1.json"
    [ -f "$NODE" ] || die "节点不存在: $1"
}
all_nodes() {
    # Empty directories must produce [], not a literal unmatched glob.
    for f in "$DATA"/nodes/*.json; do
        [ -f "$f" ] || continue
        cat "$f"
    done | jq -s .
}
random_hex() { od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'; }
host_ok() {
    [ -n "$1" ] || return 1
    case "$1" in *[!a-zA-Z0-9.:%_-]*) return 1 ;; esac
}
port_free() {
    all_nodes | jq -e --argjson p "$1" 'all(.[]; .port != $p)' >/dev/null || return 1
    if has ss; then
        [ -z "$(ss -H -lntu "sport = :$1" 2>/dev/null)" ] || return 1
    fi
}
free_port() {
    p=5102
    while [ "$p" -le 65535 ]; do
        if port_free "$p"; then printf '%s' "$p"; return; fi
        p=$((p + 1))
    done
    die "没有可用端口"
}
core() {
    MITA_CONFIG_JSON_FILE="$DATA/server.json" MITA_UDS_PATH="$DATA/runtime/mita.sock" "$MITA" "$@"
}
generate() {
    all_nodes | jq --slurpfile s "$DATA/settings.json" '
      [.[] | select(.enabled)] as $n |
      {portBindings: ($n | map({port, protocol}) | unique),
       users: ($n | map({name: .username, password})),
       loggingLevel: "INFO", mtu: $s[0].mtu,
       dns: {dualStack: "PREFER_IPv4"}, trafficPattern: {seed: $s[0].seed}}'
}
service_action() {
    if has rc-service; then
        rc-service mierush "$1"
    elif has systemctl; then
        systemctl "$1" mierush.service
    else
        die "需要 OpenRC 或 systemd"
    fi
}
apply_config() {
    tmp=$(mktemp "$DATA/server.XXXXXX")
    generate > "$tmp"
    # mita requires at least one port binding; no active nodes means stop.
    if ! jq -e '.portBindings | length > 0' "$tmp" >/dev/null; then
        service_action stop || true
        mv "$tmp" "$DATA/server.json"
        return
    fi
    if [ -x "$MITA" ] && [ -S "$DATA/runtime/mita.sock" ]; then
        if ! core replace config "$tmp"; then
            rm -f "$tmp"
            die "mita 拒绝配置，运行配置未替换"
        fi
    fi
    mv "$tmp" "$DATA/server.json"
    service_action restart
    # Service activation alone doesn't prove that the proxy bound its ports.
    i=0
    while [ "$i" -lt 10 ]; do
        if core status 2>&1 | grep -q '"RUNNING"'; then return; fi
        i=$((i + 1)); sleep 1
    done
    die "代理未进入 RUNNING，请使用 mierush status 查看日志"
}
pattern() {
    seed=$(jq -r .seed "$DATA/settings.json")
    oct=$(printf '%03o' "$seed")
    # TrafficPattern.seed is protobuf field 1, wire type 0 (0x08).
    printf '\010' ; printf "\\$oct"
}
link() {
    node_file "$1"
    tp=$(pattern | base64 | tr -d '\r\n')
    jq -r --slurpfile s "$DATA/settings.json" --arg tp "$tp" '
      def host: if contains(":") then "[" + . + "]" else . end;
      "mierus://" + (.username|@uri) + ":" + (.password|@uri) + "@" +
      (.host|host) + "?handshake-mode=" + .handshake + "&mtu=" + ($s[0].mtu|tostring) +
      "&multiplexing=" + .multiplexing + "&port=" + (.port|tostring) +
      "&profile=default&protocol=" + .protocol + "&traffic-pattern=" + ($tp|@uri) +
      "#" + (.name|@uri)' "$NODE"
}
list_nodes() {
    printf 'ID\t名称\t端口\t协议\t启用\t地址\n'
    all_nodes | jq -r '.[] | [.id,.name,.port,.protocol,.enabled,.host] | @tsv'
}
create_node() {
    name=$(ask '节点名称 [mieru]: '); name=${name:-mieru}
    host=$(jq -r .host "$DATA/settings.json")
    value=$(ask "公网 IP / 域名 [$host]: "); host=${value:-$host}
    host_ok "$host" || die "请输入有效 IP 或域名（IPv6 不加方括号）"
    port=$(ask '监听端口 [自动，从 5102 开始]: ')
    port=${port:-$(free_port)}
    port_ok "$port" || die "端口范围为 1025-65535"
    port_free "$port" || die "端口已被占用"
    protocol=$(ask '协议 TCP / UDP [TCP]: '); protocol=${protocol:-TCP}
    case "$protocol" in TCP|UDP) ;; *) die "协议只能是 TCP 或 UDP" ;; esac
    count=$(ask '创建数量 [1]: '); count=${count:-1}
    number "$count" && [ "$count" -ge 1 ] && [ "$count" -le 100 ] || die "数量范围为 1-100"
    n=1
    while [ "$n" -le "$count" ]; do
        [ "$n" = 1 ] || port=$(free_port)
        id=$(random_hex 6); username="m$(random_hex 4)"; password=$(random_hex 16)
        label=$name; [ "$count" = 1 ] || label="$name-$n"
        jq -n --arg id "$id" --arg name "$label" --arg host "$host" \
          --arg username "$username" --arg password "$password" \
          --arg protocol "$protocol" --argjson port "$port" '
          {id:$id,name:$name,host:$host,port:$port,protocol:$protocol,
           username:$username,password:$password,enabled:true,
           handshake:"HANDSHAKE_NO_WAIT",multiplexing:"MULTIPLEXING_OFF"}' > "$DATA/nodes/$id.json"
        n=$((n + 1))
    done
    apply_config
    say '创建完成（请在云防火墙/安全组放行对应 TCP 或 UDP 端口）。'
    export_links
}
export_links() {
    for f in "$DATA"/nodes/*.json; do
        [ -f "$f" ] || continue
        jq -e .enabled "$f" >/dev/null || continue
        id=$(jq -r .id "$f")
        link "$id"
    done
}
edit_node() {
    list_nodes
    id=$(ask '节点 ID: '); node_file "$id"
    say '1. 名称  2. 公网地址  3. 重置凭据  4. 启用/禁用  5. 删除'
    choice=$(ask '选项: ')
    tmp=$(mktemp "$DATA/nodes/.edit.XXXXXX")
    case "$choice" in
        1) value=$(ask '新名称: '); [ -n "$value" ] || die "名称不能为空"
           jq --arg v "$value" '.name=$v' "$NODE" > "$tmp" ;;
        2) value=$(ask '新 IP / 域名: '); host_ok "$value" || die "地址无效"
           jq --arg v "$value" '.host=$v' "$NODE" > "$tmp" ;;
        3) jq --arg u "m$(random_hex 4)" --arg p "$(random_hex 16)" '.username=$u | .password=$p' "$NODE" > "$tmp" ;;
        4) jq '.enabled = (.enabled|not)' "$NODE" > "$tmp" ;;
        5) rm -f "$tmp"; value=$(ask '输入 DELETE 确认删除: ')
           [ "$value" = DELETE ] || return 0
           rm -f "$NODE"; apply_config; return ;;
        *) rm -f "$tmp"; return ;;
    esac
    mv "$tmp" "$NODE"
    apply_config
    link "$id"
}
settings() {
    host=$(jq -r .host "$DATA/settings.json")
    value=$(ask "默认公网 IP / 域名 [$host]: "); host=${value:-$host}
    host_ok "$host" || die "地址无效"
    mtu=$(jq -r .mtu "$DATA/settings.json")
    value=$(ask "MTU [$mtu]: "); mtu=${value:-$mtu}
    number "$mtu" && [ "$mtu" -ge 1280 ] && [ "$mtu" -le 1500 ] || die "MTU 范围为 1280-1500"
    seed=$(jq -r .seed "$DATA/settings.json")
    value=$(ask "流量模式 seed，修改后需重新导入全部链接 [$seed]: "); seed=${value:-$seed}
    number "$seed" && [ "$seed" -le 127 ] || die "seed 范围为 0-127"
    tmp=$(mktemp "$DATA/settings.XXXXXX")
    jq -n --arg host "$host" --argjson mtu "$mtu" --argjson seed "$seed" \
      '{host:$host,mtu:$mtu,seed:$seed}' > "$tmp"
    mv "$tmp" "$DATA/settings.json"
    apply_config
}
download() { curl -fL --retry 3 --connect-timeout 15 -o "$2" "$1"; }
install_core() {
    root
    # Service paths are intentionally fixed for installed deployments.
    [ "$DATA" = /etc/mierush ] && [ "$MITA" = /usr/local/bin/mita ] || die "install 不支持自定义数据/核心路径"
    if has apk; then
        apk add --no-cache curl jq ca-certificates tar coreutils iproute2
    elif has apt-get; then
        apt-get update
        apt-get install -y curl jq ca-certificates tar coreutils iproute2
    elif has dnf; then
        dnf install -y curl jq ca-certificates tar coreutils iproute
    elif has yum; then
        yum install -y curl jq ca-certificates tar coreutils iproute
    else die "不支持的包管理器"; fi
    deps; init_data
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
        *) die "官方 mita 仅提供 amd64 / arm64 服务端发行包" ;;
    esac
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    asset="mita_${RELEASE}_linux_${arch}.tar.gz"
    url="$DOWNLOAD_BASE/v$RELEASE/$asset"
    download "$url" "$work/$asset"
    download "$url.sha256.txt" "$work/checksum"
    expected=$(awk 'NR==1 {print $1}' "$work/checksum")
    actual=$(sha256sum "$work/$asset" | awk '{print $1}')
    [ "$expected" = "$actual" ] || die "核心 SHA256 校验失败"
    tar -xzf "$work/$asset" -C "$work"
    binary=$(find "$work" -type f -name mita | head -n 1)
    [ -n "$binary" ] || die "发行包内未找到 mita"
    "$binary" version
    mkdir -p /usr/local/bin /var/lib/mita
    # mita's management socket expects an OS account named mita.
    if ! id mita >/dev/null 2>&1; then
        if has apk; then addgroup -S mita; adduser -S -D -H -G mita mita
        else useradd --system --no-create-home --shell /usr/sbin/nologin mita; fi
    fi
    if [ -f "$SELF" ]; then service_action stop || true; fi
    install -m 755 "$binary" "$MITA"
    if [ "$(readlink -f "$0")" != "$SELF" ]; then install -m 755 "$0" "$SELF"; fi
    if [ ! -e /usr/local/bin/mi ] || [ -L /usr/local/bin/mi ]; then ln -sf "$SELF" /usr/local/bin/mi; fi
    generate > "$DATA/server.json"
    install_service
    say "安装完成，运行 mi 进入面板。核心版本: $RELEASE"
}
install_service() {
    if has rc-service; then
        cat > /etc/init.d/mierush <<'RC'
#!/sbin/openrc-run
description="mierush / mita proxy server"
command="/usr/local/bin/mita"
command_args="run"
command_background=true
pidfile="/run/mierush.pid"
output_log="/var/log/mierush.log"
error_log="/var/log/mierush.log"
export MITA_CONFIG_JSON_FILE="/etc/mierush/server.json"
export MITA_UDS_PATH="/etc/mierush/runtime/mita.sock"
depend() { need net; after firewall; }
start_pre() { checkpath -d -m 0700 /etc/mierush/runtime; }
RC
        chmod 755 /etc/init.d/mierush
        rc-update add mierush default
    elif has systemctl; then
        cat > /etc/systemd/system/mierush.service <<'UNIT'
[Unit]
Description=mierush / mita proxy server
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
Environment=MITA_CONFIG_JSON_FILE=/etc/mierush/server.json
Environment=MITA_UDS_PATH=/etc/mierush/runtime/mita.sock
ExecStart=/usr/local/bin/mita run
Restart=on-failure
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable mierush.service
    else die "需要 OpenRC 或 systemd"; fi
    if all_nodes | jq -e 'any(.[]; .enabled)' >/dev/null; then apply_config; fi
}
status() {
    core status || true
    if has rc-service; then
        rc-service mierush status || true
        tail -n 30 /var/log/mierush.log 2>/dev/null || true
    elif has systemctl; then
        systemctl --no-pager status mierush.service || true
        journalctl -u mierush.service -n 30 --no-pager || true
    fi
}
reset_credentials() {
    confirm=$(ask '重置全部节点凭据，旧链接将失效。输入 RESET: ')
    [ "$confirm" = RESET ] || return 0
    for f in "$DATA"/nodes/*.json; do
        [ -f "$f" ] || continue
        tmp=$(mktemp "$DATA/nodes/.reset.XXXXXX")
        jq --arg u "m$(random_hex 4)" --arg p "$(random_hex 16)" '.username=$u|.password=$p' "$f" > "$tmp"
        mv "$tmp" "$f"
    done
    apply_config; export_links
}
uninstall() {
    confirm=$(ask '删除程序、节点和凭据，输入 DELETE: ')
    [ "$confirm" = DELETE ] || return 0
    service_action stop || true
    if has rc-update; then rc-update del mierush default || true; fi
    if has systemctl; then systemctl disable mierush.service || true; fi
    rm -f /etc/init.d/mierush /etc/systemd/system/mierush.service
    if has systemctl; then systemctl daemon-reload; fi
    [ "$(readlink /usr/local/bin/mi 2>/dev/null || true)" != "$SELF" ] || rm -f /usr/local/bin/mi
    rm -f "$SELF" "$MITA" /var/log/mierush.log
    rm -rf "$DATA"
    say 'mierush 已卸载。'
}
menu() {
    while :; do
        say "\n======== mierush $MIERUSH_VERSION · mieru 节点管理 ========"
        say ' 1. 安装/更新核心       2. 创建/批量创建节点'
        say ' 3. 查看节点列表       4. 查看链接/二维码'
        say ' 5. 导出全部链接       6. 修改/删除/启用节点'
        say ' 7. 重置全部凭据       8. 全局设置'
        say ' 9. 启动服务          10. 停止服务'
        say '11. 重启/应用配置     12. 状态/日志'
        say '13. 用户流量统计      14. 导出 Base64 订阅'
        say '15. 卸载               0. 退出'
        choice=$(ask '选项: ') || return 0
        # Isolate errors so invalid input doesn't close the interactive panel.
        case "$choice" in
            0) return ;;
            1) sh "$0" install || true ;;
            2) sh "$0" create || true ;;
            3) list_nodes ;;
            4) (list_nodes; id=$(ask '节点 ID: '); uri=$(link "$id"); say "$uri"
                if has qrencode; then qrencode -t ANSIUTF8 "$uri"; else say '安装 qrencode 可显示二维码'; fi) || true ;;
            5) export_links ;;
            6) sh "$0" edit || true ;;
            7) sh "$0" reset-credentials || true ;;
            8) sh "$0" settings || true ;;
            9) sh "$0" apply || true ;;
            10) service_action stop || true ;;
            11) sh "$0" apply || true ;;
            12) status ;;
            13) core get users || true ;;
            14) export_links | base64 | tr -d '\r\n'; printf '\n' ;;
            15) sh "$0" uninstall || true; return ;;
            *) say '无效选项' ;;
        esac
        pause
    done
}
usage() {
    say 'mierush [install|menu|create|list|link ID|export|subscription|gen|apply|start|stop|restart|status|reset-credentials|uninstall|version]'
}
case "${1:-menu}" in
    version|--version|-v) say "$MIERUSH_VERSION"; exit ;;
    help|--help|-h) usage; exit ;;
    install) install_core; exit ;;
esac
deps
case "${1:-menu}" in
    list) list_nodes ;;
    link) link "${2:-}" ;;
    export) export_links ;;
    subscription) export_links | base64 | tr -d '\r\n'; printf '\n' ;;
    gen) generate ;;
    *) root; init_data
       case "${1:-menu}" in
           menu) menu ;; create) create_node ;; edit) edit_node ;; settings) settings ;;
           apply|start|restart) apply_config ;;
           stop) service_action stop ;; status) status ;;
           reset-credentials) reset_credentials ;; uninstall) uninstall ;;
           *) usage; exit 1 ;;
       esac ;;
esac
