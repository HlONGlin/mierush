# mierush · mieru 一键部署与节点管理

参考 [rysh](https://github.com/HlONGlin/rysh) 的 `sh` 数字面板形式，使用官方 **mita** 服务端部署 mieru 节点，生成 `mierus://` 分享链接。支持 Alpine/OpenRC、Debian/Ubuntu/systemd 和 RHEL 系列/systemd，架构为 amd64 或 arm64。

## 一键安装

以 root 执行（不需要 bash）：

```sh
curl -fsSL https://raw.githubusercontent.com/HlONGlin/mierush/main/one-click.sh -o /tmp/mierush-oneclick.sh
sh /tmp/mierush-oneclick.sh
```

选择 `1` 安装，再选择 `6` 进入节点面板。安装后可在任意目录执行：

```sh
mi
```

本地部署也可以执行 `sh mierush.sh install`。默认安装官方核心 **v3.38.1**，下载 tar.gz 并验证官方 SHA256 文件。更新核心可执行 `MIERUSH_CORE_VERSION=3.38.1 sh mierush.sh install`。更新管理脚本请重新运行一键安装。

## 功能

- 创建单个或批量节点，自动分配空闲端口、随机用户名和密码。
- TCP / UDP，默认 TCP、MTU 1400、`HANDSHAKE_NO_WAIT`、`MULTIPLEXING_OFF`。
- 查看、重命名、修改公网地址、启停和删除节点，重置单个或全部凭据。
- 输出分享链接、终端二维码（可选安装 `qrencode`）、全部链接和 Base64 订阅。
- OpenRC / systemd 开机自启、服务管理、状态日志和官方用户流量统计。
- 节点数据以 JSON 保存，不把用户输入作为 shell 代码执行；凭据文件默认权限 600。

## 创建和导入

面板选择 `2`，填写名称、公网 IP / 域名、端口、协议和数量。IPv6 输入不加方括号，链接中会自动补全。服务器在 NAT 后面时，填写客户端实际访问的地址，并保证填写的端口与外部映射端口一致。

创建后输出的链接形式与示例一致：

```text
mierus://<用户名>:<密码>@<服务器>?handshake-mode=HANDSHAKE_NO_WAIT&mtu=1400&multiplexing=MULTIPLEXING_OFF&port=5102&profile=default&protocol=TCP&traffic-pattern=CCo%3D#%E9%A6%99%E6%B8%AF1%28if%29
```

中文名称和特殊字符会进行 URL 编码，客户端解析后显示原名称。`traffic-pattern` 来自本机服务端的实际 `trafficPattern.seed`，默认 seed 为 42（编码 `CCo=`），不复制示例服务器的流量模式或凭据。修改全局 seed / MTU 后，应重新导出并导入链接。需要支持 `mierus://` 及这些参数的客户端。

请放行节点对应协议的系统防火墙端口和云安全组端口。脚本不会替你修改现有防火墙。服务器和客户端需要保持时间同步。

### 多节点模型

所有节点由同一个 mita 实例管理，每条节点记录拥有独立的分享地址、端口和凭据。**官方 mita 的用户列表作用于整个实例，任意已启用用户均可在任意已启用监听端口认证**，并非严格的端口与用户隔离。禁用节点会同时从配置移除该记录的用户和端口。

流量面板调用 `mita get users`，显示官方 1/7/30 天滚动统计。当前版本不提供 rysh 的自然月限额、到期封禁和 tc 限速。

## 常用命令

```sh
mierush install              # 安装/更新核心和依赖
mierush create               # 交互创建/批量创建
mierush list                 # 节点列表
mierush link <节点ID>        # 单条链接
mierush export               # 导出所有已启用节点
mierush subscription         # Base64 订阅内容
mierush gen                  # 输出服务端 JSON（包含凭据）
mierush apply                # 生成配置并重启，检查 RUNNING 状态
mierush start
mierush stop
mierush restart
mierush status
mierush reset-credentials    # 确认后重置全部凭据
mierush uninstall            # 输入 DELETE 后卸载程序和节点数据
mierush version
```

导出文件请限制权限：

```sh
umask 077
mierush export > /root/mierush-links.txt
mierush subscription > /root/mierush-subscription.txt
```

## 文件位置

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/mierush`、`/usr/local/bin/mi` | 管理脚本与快捷命令 |
| `/usr/local/bin/mita` | 官方服务端核心 |
| `/etc/mierush/nodes/*.json` | 节点记录及明文凭据 |
| `/etc/mierush/settings.json` | 默认公网地址、MTU 和 seed |
| `/etc/mierush/server.json` | 自动生成的服务端配置 |
| `/etc/mierush/runtime/mita.sock` | 本机管理 socket |
| `/etc/init.d/mierush` | OpenRC 服务 |
| `/etc/systemd/system/mierush.service` | systemd 服务 |
| `/var/log/mierush.log` | OpenRC 日志；systemd 使用 journal |
| `/var/lib/mita/metrics.pb` | 官方核心的流量持久化文件 |

卸载保留系统依赖、mita 系统账号及 `/var/lib/mita` 的官方统计数据。此目录也可能被其他 mita 安装使用。

## 开发校验

```sh
sh -n mierush.sh
sh -n one-click.sh
python3 tests/test_links.py
```

链接测试需要 `sh`、`jq`、`base64` 和 Python 3，覆盖链接解析、特殊字符、IPv6、配置与流量模式一致性、禁用节点过滤以及非法节点 ID。
