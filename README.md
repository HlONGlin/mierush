# mierush · mieru 一键部署与节点管理

参考 [rysh](https://github.com/HlONGlin/rysh) 的 `sh` 数字面板形式，使用官方 **mita** 服务端部署 mieru 节点，生成 `mierus://` 分享链接。支持 Alpine/OpenRC、Debian/Ubuntu/systemd 和 RHEL 系列/systemd，架构为 amd64 或 arm64。

## 一键脚本

直接使用项目提供的一键脚本完成 mierush 的安装与管理（以 root 运行）：

```bash
bash <(curl -fsSL https://github.com/HlONGlin/mierush/raw/main/one-click.sh)
```

脚本提供数字菜单：

1. 安装或更新 mierush（含 mita 核心与依赖）
2. 启动 mierush / mita 服务
3. 停止 mierush / mita 服务
4. 彻底卸载并清除节点数据
5. 重置节点凭据（保留节点记录）
6. 进入 mierush 节点管理菜单
0. 退出

脚本会从本项目 `main` 分支下载 `mierush.sh`，安装到 `/usr/local/bin/mierush`，并自动安装依赖、mita 核心和 OpenRC / systemd 服务。安装完成后选择 `6` 进入节点管理菜单，即可创建第一个 mieru 节点。

Alpine 最小系统默认没有 `bash`，而 `bash <(...)` 需要 bash 才能执行，请先安装：

```sh
apk add bash curl ca-certificates
```

也可以不使用 bash：

```sh
curl -fsSL https://github.com/HlONGlin/mierush/raw/main/one-click.sh -o /tmp/mierush-oneclick.sh && sh /tmp/mierush-oneclick.sh
```

部署完成后，在任意目录输入 **`mi`** 即可直接唤出面板（等价于 `mierush`）：

```sh
mi
```

本地部署也可以执行 `sh mierush.sh install`。默认查询并安装官方**最新稳定版** mita 核心，下载 tar.gz 并验证官方 SHA256 文件。安装前显示目标核心版本，完成后显示管理脚本和核心版本。有已启用节点时，还会检查代理是否进入 `RUNNING` 状态。

### 更新已安装的版本

在节点面板选择 **`13` 更新脚本与核心**，或执行：

```sh
mierush update
```

此操作从本项目 `main` 分支下载新版管理脚本，并安装官方最新稳定版核心，保留节点和设置。更新后重新运行 `mi` 载入新版面板，也可重新执行上方一键脚本并选择 `1`。

需要指定核心版本时：

```sh
MIERUSH_CORE_VERSION=3.38.1 mierush update
```

下载、校验和二进制验证完成后才替换程序；替换后发生安装或启动失败时，会尝试恢复原程序、生成配置和服务定义，并恢复此前运行的服务。首次安装且没有节点时不启动监听，创建节点后自动启动。

## 功能

- 创建单个或批量节点，自动分配空闲端口、随机用户名和密码。
- TCP / UDP，默认 TCP、MTU 1400、`HANDSHAKE_NO_WAIT`、`MULTIPLEXING_OFF`。
- 查看、重命名、修改公网地址、启停和删除节点，重置单个或全部凭据。
- 输出分享链接、终端二维码（可选安装 `qrencode`）、全部链接和 Base64 订阅。
- OpenRC / systemd 开机自启、服务管理、状态日志和官方用户流量统计。
- 节点数据以 JSON 保存，不把用户输入作为 shell 代码执行；凭据文件默认权限 600。

## 创建和导入

进入 `mi` 面板后：

- **`1` 快速创建**：输入名称和监听端口，均可直接回车使用默认值。公网地址自动识别并保存，默认 TCP，凭据自动生成。
- **`2` 批量创建**：输入名称、数量和起始端口，默认创建 5 个节点。指定起始端口时连续分配，例如 `6000`、`6001`、`6002`；留空则自动选择空闲端口。指定范围会在创建前检查，存在占用或超出 65535 时停止本次创建。
- **`3` 自定义创建**：需要指定公网地址、端口或 UDP 时使用。

地址识别失败时只在首次创建时要求填写，后续复用已保存地址。可以在 `12` 全局设置中修改默认地址。IPv6 输入不加方括号，链接中会自动补全。服务器在 NAT 后面时，请填写客户端实际访问的地址，并保证填写的端口与外部映射端口一致。

面板顶部显示服务状态、节点总数、已启用数量和公网地址。查看链接、修改和删除节点时直接选择列表编号，无需复制节点 ID。创建成功后直接展示本次每个新建节点的名称、地址、端口和 `mierus://` 分享链接，复制即可导入客户端；稍后也可通过菜单 `5` 再次查看。

```text
  1. 快速创建          2. 批量创建
  3. 自定义创建        4. 节点列表
  5. 链接 / 二维码     6. 修改 / 删除
  7. 导出链接 / 订阅   8. 启动 / 重启
  9. 停止服务         10. 状态 / 日志
 11. 用户流量         12. 全局设置
 13. 更新脚本与核心   14. 重置全部凭据
 15. 卸载              0. 退出
```

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
mierush install              # 安装当前脚本及最新核心、依赖
mierush update               # 下载并更新管理脚本与最新核心
mierush create               # 快速创建，名称和端口可回车默认
mierush batch                # 批量创建，可指定连续起始端口
mierush custom               # 自定义地址、端口、协议和数量
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
