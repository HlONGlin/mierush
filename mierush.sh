#!/bin/sh
# mierush - POSIX sh terminal manager for the official mieru server (mita).
set -eu
umask 077
MIERUSH_VERSION="1.2.0"
DATA="${MIERUSH_DATA_DIR:-/etc/mierush}"
MITA="${MIERUSH_MITA_BIN:-/usr/local/bin/mita}"
SELF="/usr/local/bin/mierush"
RELEASE="${MIERUSH_CORE_VERSION:-}"
REPO_RAW="${MIERUSH_REPO_RAW:-https://raw.githubusercontent.com/HlONGlin/mierush/main}"
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
    if all_nodes | jq -e 'length == 0' >/dev/null; then
        say '暂无节点，选择「快速创建」即可生成第一个节点。'; return
    fi
    all_nodes | jq -r 'to_entries[] | "  [\(.key + 1)] \(.value.name)  ·  \(if .value.enabled then "已启用" else "已禁用" end)\n      \(.value.host):\(.value.port) / \(.value.protocol)  ID: \(.value.id)"'
}
select_node() {
    list_nodes >&2
    total=$(all_nodes | jq length)
    [ "$total" -gt 0 ] || return 1
    selected=$(ask '选择节点编号 [0 返回]: ') || return 1
    [ "$selected" != 0 ] && [ -n "$selected" ] || return 1
    number "$selected" && [ "$selected" -ge 1 ] && [ "$selected" -le "$total" ] || die '节点编号无效'
    all_nodes | jq -r --argjson n "$selected" '.[$n-1].id'
}
resolve_host() {
    host=$(jq -r .host "$DATA/settings.json")
    if ! host_ok "$host"; then
        printf '正在识别公网地址...\n' >&2
        for endpoint in https://api.ipify.org https://ipv4.icanhazip.com https://api6.ipify.org; do
            host=$(curl -fsS --connect-timeout 2 --max-time 4 "$endpoint" 2>/dev/null) || host=''
            host_ok "$host" && break
        done
        if ! host_ok "$host"; then
            host=$(ask '自动识别失败，请输入公网 IP / 域名（仅首次需要）: ')
        fi
        host_ok "$host" || die '公网地址无效'
        tmp=$(mktemp "$DATA/settings.XXXXXX")
        jq --arg host "$host" '.host=$host' "$DATA/settings.json" > "$tmp"
        mv "$tmp" "$DATA/settings.json"
    fi
}
create_node() {
    mode=${1:-quick}
    say '──────────────── 创建 mieru 节点 ────────────────'
    resolve_host
    port=$(free_port); protocol=TCP; count=1
    next=$(all_nodes | jq 'length + 1')
    name=$(ask "节点名称 [mieru-$next，回车直接创建]: "); name=${name:-mieru-$next}
    case "$mode" in
      batch)
        count=$(ask '创建数量 [5]: '); count=${count:-5} ;;
      custom)
        value=$(ask "公网 IP / 域名 [$host]: "); host=${value:-$host}
        host_ok "$host" || die '公网地址无效'
        value=$(ask "监听端口 [$port]: "); port=${value:-$port}
        protocol=$(ask '协议 TCP / UDP [TCP]: '); protocol=${protocol:-TCP}
        count=$(ask '创建数量 [1]: '); count=${count:-1} ;;
    esac
    port_ok "$port" || die "端口范围为 1025-65535"
    port_free "$port" || die "端口已被占用"
    case "$protocol" in TCP|UDP) ;; *) die "协议只能是 TCP 或 UDP" ;; esac
    number "$count" && [ "$count" -ge 1 ] && [ "$count" -le 100 ] || die "数量范围为 1-100"
    say "地址: $host  |  协议: $protocol  |  数量: $count"
    created=''
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
        created="$created $id"
        n=$((n + 1))
    done
    apply_config
    say '✓ 节点创建成功，复制下方链接导入客户端：'
    for id in $created; do
        node_file "$id"
        jq -r '"\n【" + .name + "】 " + .host + ":" + (.port|tostring) + " / " + .protocol' "$NODE"
        link "$id"
    done
    say '提示：请在云防火墙/安全组放行上述端口。'
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
    id=$(select_node) || return 0
    node_file "$id"
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
show_link() {
    id=$(select_node) || return 0
    uri=$(link "$id")
    say ''; say "$uri"; say ''
    if has qrencode; then qrencode -t ANSIUTF8 "$uri"; fi
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
update_manager() (
    root
    has curl || die '缺少 curl，请使用一键脚本安装'
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    say '下载最新版管理脚本...'
    download "$REPO_RAW/mierush.sh" "$work/mierush.sh"
    grep -q '^MIERUSH_VERSION=' "$work/mierush.sh" || die '管理脚本内容无效'
    sh -n "$work/mierush.sh"
    say "管理脚本: $MIERUSH_VERSION → $(sh "$work/mierush.sh" version)"
    sh "$work/mierush.sh" install
)
resolve_release() {
    if [ -z "$RELEASE" ]; then
        say '查询官方最新稳定版核心...' >&2
        metadata=$(curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 \
            https://api.github.com/repos/enfein/mieru/releases/latest) || die '查询最新版本失败，可设置 MIERUSH_CORE_VERSION 指定版本重试'
        RELEASE=$(printf '%s' "$metadata" | jq -er '.tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) | ltrimstr("v")') || die '官方版本信息无效'
    fi
    printf '%s' "$RELEASE" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die '核心版本格式应为 x.y.z'
}
rollback_install() {
    code=$?
    trap - EXIT
    if [ "$code" -ne 0 ] && [ "$replacing" = yes ]; then
        say '安装失败，恢复更新前的程序和配置...' >&2
        service_action stop || true
        for item in mita mierush server.json openrc systemd; do
            case "$item" in
                mita) target=$MITA ;; mierush) target=$SELF ;; server.json) target="$DATA/server.json" ;;
                openrc) target=/etc/init.d/mierush ;; systemd) target=/etc/systemd/system/mierush.service ;;
            esac
            if [ -f "$work/backup/$item" ]; then cp -p "$work/backup/$item" "$target"; else rm -f "$target"; fi
        done
        if has systemctl; then systemctl daemon-reload || true; fi
        if [ "$was_running" = yes ]; then service_action start || true; fi
    fi
    rm -rf "$work"
    exit "$code"
}
install_core() (
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
    resolve_release
    say "目标核心版本: $RELEASE"
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
        *) die "官方 mita 仅提供 amd64 / arm64 服务端发行包" ;;
    esac
    work=$(mktemp -d)
    replacing=no; was_running=no
    trap rollback_install EXIT
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
    mkdir "$work/backup"
    [ ! -f "$MITA" ] || cp -p "$MITA" "$work/backup/mita"
    [ ! -f "$SELF" ] || cp -p "$SELF" "$work/backup/mierush"
    [ ! -f "$DATA/server.json" ] || cp -p "$DATA/server.json" "$work/backup/server.json"
    [ ! -f /etc/init.d/mierush ] || cp -p /etc/init.d/mierush "$work/backup/openrc"
    [ ! -f /etc/systemd/system/mierush.service ] || cp -p /etc/systemd/system/mierush.service "$work/backup/systemd"
    if [ -x "$MITA" ] && [ -S "$DATA/runtime/mita.sock" ]; then
        if core status 2>&1 | grep -q '"RUNNING"'; then was_running=yes; fi
    fi
    replacing=yes
    if [ -f "$SELF" ]; then service_action stop || true; fi
    install -m 755 "$binary" "$MITA"
    if [ "$(readlink -f "$0")" != "$SELF" ]; then install -m 755 "$0" "$SELF"; fi
    if [ ! -e /usr/local/bin/mi ] || [ -L /usr/local/bin/mi ]; then ln -sf "$SELF" /usr/local/bin/mi; fi
    generate > "$DATA/server.json"
    install_service
    replacing=no
    say "✓ 安装/更新成功：管理脚本 $MIERUSH_VERSION / 核心 $RELEASE"
    say '运行 mi 进入面板；没有节点时服务不监听，快速创建后自动启动。'
)
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
        if [ -t 1 ]; then printf '\033[2J\033[H'; fi
        printf '\n╭────────────────────────────────────────────╮\n'
        say "  mierush $MIERUSH_VERSION  ·  mieru 节点面板"
        say '╰────────────────────────────────────────────╯'
        summary=$(all_nodes | jq -r '"节点 \(length) 个 / 已启用 \([.[] | select(.enabled)] | length) 个"')
        state='未安装核心'
        if [ -x "$MITA" ]; then
            state='已停止'
            if [ -S "$DATA/runtime/mita.sock" ]; then
                if core status 2>&1 | grep -q '"RUNNING"'; then state='运行中'; else state='未就绪'; fi
            fi
        fi
        say "  服务: $state  |  $summary"
        public_host=$(jq -r '.host | if . == "" then "首次创建时自动识别" else . end' "$DATA/settings.json")
        say "  公网地址: $public_host"
        say '───────────────── 创建节点 ─────────────────'
        say ' 1. 快速创建         回车即可生成，默认 TCP'
        say ' 2. 批量创建         名称 + 数量'
        say ' 3. 自定义创建       指定地址 / 端口 / 协议'
        say '───────────────── 管理节点 ─────────────────'
        say ' 4. 节点列表         5. 链接 / 二维码'
        say ' 6. 修改 / 删除      7. 导出链接 / 订阅'
        say '───────────────── 服务设置 ─────────────────'
        say ' 8. 启动 / 重启      9. 停止服务'
        say '10. 状态 / 日志     11. 用户流量'
        say '12. 全局设置        13. 更新脚本与核心'
        say '14. 重置全部凭据    15. 卸载'
        say ' 0. 退出'
        choice=$(ask '选项: ') || return 0
        # Isolate errors so invalid input doesn't close the interactive panel.
        case "$choice" in
            0) return ;;
            1) sh "$0" create || true ;;
            2) sh "$0" batch || true ;;
            3) sh "$0" custom || true ;;
            4) list_nodes ;;
            5) sh "$0" show-link || true ;;
            6) sh "$0" edit || true ;;
            7) say '1. 原始分享链接  2. Base64 订阅'
               format=$(ask '导出格式 [1]: ') || return 0
               case "$format" in
                   ''|1) export_links ;;
                   2) export_links | base64 | tr -d '\r\n'; printf '\n' ;;
                   *) say '无效选项' ;;
               esac ;;
            8) sh "$0" apply || true ;;
            9) service_action stop || true ;;
            10) status ;;
            11) core get users || true ;;
            12) sh "$0" settings || true ;;
            13) sh "$0" update || true; say '更新后请退出并重新运行 mi，载入新版面板。' ;;
            14) sh "$0" reset-credentials || true ;;
            15) sh "$0" uninstall || true; return ;;
            *) say '无效选项' ;;
        esac
        pause
    done
}
usage() {
    say 'mierush [install|update|menu|create|batch|custom|list|show-link|edit|settings|link ID|export|subscription|gen|apply|start|stop|restart|status|reset-credentials|uninstall|version]'
}
case "${1:-menu}" in
    version|--version|-v) say "$MIERUSH_VERSION"; exit ;;
    help|--help|-h) usage; exit ;;
    install) install_core; exit ;;
    update) update_manager; exit ;;
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
            batch) create_node batch ;; custom) create_node custom ;; show-link) show_link ;;
           apply|start|restart) apply_config ;;
           stop) service_action stop ;; status) status ;;
           reset-credentials) reset_credentials ;; uninstall) uninstall ;;
           *) usage; exit 1 ;;
       esac ;;
esac
