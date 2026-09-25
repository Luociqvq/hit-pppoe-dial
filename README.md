# 哈工大校园网一键上网：有线 PPPoE 拨号 + WiFi 门户认证

两个零依赖的 Windows PowerShell 脚本，把"每次上网都要手动输账号密码"变成双击一下：

| 脚本 | 管什么 | 状态 |
| --- | --- | --- |
| `dial.ps1` | 有线 PPPoE 拨号 / 断开 / 掉线自动重连 | **已实测跑通**（Windows 11 + PowerShell 5.1，含错误 651 现场） |
| `wifi.ps1` | 连接 `HIT-WLAN` 并自动完成 ePortal 门户认证，不开浏览器 | **未在有门户的环境验证过**，见下面的说明 |

只用系统自带的 `rasdial` / `netsh wlan` / `curl.exe` 和 NetAdapter 系列 cmdlet，无第三方依赖、无 GUI、无需管理员权限。

## 快速开始

1. 在系统里建好宽带连接（控制面板 → 网络和共享中心 → 设置新的连接或受限的连接 → 连接到 Internet → 宽带 PPPoE），记住名字，默认 `宽带连接`。
2. `copy config.example.ini config.ini`，填入 `ACCOUNT` / `PASSWORD`。
3. 生成桌面图标：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File dial.ps1 -Action install   # 「宽带拨号」
   powershell -NoProfile -ExecutionPolicy Bypass -File wifi.ps1 -Action install   # 「校园网WiFi」
   ```

4. 双击图标。`dial.ps1` 已连接时再双击 = 断开；`wifi.ps1` 双击 = 连 WiFi 并认证。

排错时可以直接在控制台跑，结果会打印出来：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File dial.ps1 -Action status
powershell -NoProfile -ExecutionPolicy Bypass -File wifi.ps1 -Action status
```

## dial.ps1（有线 PPPoE）

| `-Action` | 作用 |
| --- | --- |
| `toggle`（默认） | 已连接就断开，未连接就拨号。桌面图标走的就是这个 |
| `dial` / `hangup` | 只拨号 / 只断开 |
| `status` | 是否已连接 + 当前 IP |
| `watch` | 前台跑断线重连循环（一般由脚本自己在后台拉起） |
| `config` | 用记事本打开 `config.ini` |
| `install` / `uninstall` | 创建 / 移除桌面图标（`uninstall` 会一并停掉后台监控） |

行为：

- 拨号成功后自动拉起一个隐藏的后台监控进程，每隔 `RETRY_SECONDS` 秒检查一次，掉线就自动重拨。
- **连续 5 次重连失败后监控自行停止** —— 避免密码错了还拿错误凭据反复砸运营商认证。
- **手动断开会同时停掉后台监控**，否则你会发现"断不掉"（刚断就被重拨回来）。
- `WATCHER=0` 彻底关掉自动重连；`-Quiet` 只写日志不弹窗。
- 成功**不弹窗**，失败才弹窗（带错误码含义）；过程写 `dial.log`。

### 踩过的三个坑（这部分对别的机器也通用）

1. **PPPoE 接口在 `Get-NetAdapter` 里可能根本查不到。** 实测有一类机器上，`Get-NetAdapter`、`Get-NetAdapter -IncludeHidden`、`Win32_NetworkAdapter` 都列不出宽带连接对应的接口（`Get-NetIPInterface` 里却有，ifIndex 是个"多出来"的值）。用 `Get-NetAdapter` 判在线状态会稳定误报"未连接"，于是对着已经连好的线再拨一次。这里改用：

   ```powershell
   Get-NetIPInterface -InterfaceAlias 宽带连接 -AddressFamily IPv4   # ConnectionState -eq 'Connected'
   ```

   顺带说：那些靠 `rasphone.exe` 弹窗再模拟点击"连接"按钮的方案，多半也是被这类接口可见性问题逼出来的。

2. **`.ps1` 必须存成 UTF-8 带 BOM**。否则 Windows PowerShell 5.1 会按系统 ANSI（GBK）读取，脚本里的 `宽带连接` 变成乱码字符串，拨号直接报 623「找不到电话簿条目」。

3. **不要解析 `rasdial` 的文本来判断成败。** 它的输出是本地化的，中文环境下还是 GBK。用退出码：`& rasdial ... ; $LASTEXITCODE`。

   附带一个零风险的权限探测法：拿一个不存在的连接名去拨

   ```powershell
   rasdial __probe__ a b
   ```

   返回 `623`（找不到条目）说明普通用户权限就能拨号；返回 `5`（拒绝访问）才需要提权。它不会碰到你的真实账号。

## wifi.ps1（WiFi + ePortal 门户认证）

校园网 WiFi 的认证是在层 2 之外另做一次的：`HIT-WLAN` 这个 SSID 本身**是开放式、没有 WPA 密钥**（`netsh wlan show profile name=HIT-WLAN` 可确认），连上之后所有流量被门户拦着，要在浏览器里登录。所以脚本可以完全不碰浏览器，三步搞定：

| `-Action` | 作用 |
| --- | --- |
| `connect`（默认） | 关联 `HIT-WLAN` → 等 IP → 探测门户 → 静默提交认证 → 复检是否放行 |
| `status` | 只读：是否已认证；未认证时把扫到的门户 URL 打印出来 |
| `logout` | 向门户提交登出 + 断开无线 |
| `disconnect` | 只断开无线 |
| `install` / `uninstall` | 桌面「校园网WiFi」图标 |

原理（和你在浏览器里点登录时发生的请求一模一样）：

1. `netsh wlan connect name=HIT-WLAN` —— 关联。注意这条命令**只要周边有信号就会立刻回"已成功完成连接"**（它只是把请求排进队列），所以脚本判定成败用的是"无线有没有拿到 IPv4"，不是它的返回值。
2. `GET http://www.msftconnecttest.com/redirect` —— 返回体里含 `go.microsoft.com/fwlink` 表示已认证；否则从返回的引号字符串里抓出 `.../eportal/index.jsp?...` 的门户地址和它的 `queryString`。
3. `POST http://202.118.253.94:8080/eportal/InterFace.do?method=login`，表单字段 `userId / password / service / queryString / operatorPwd / operatorUserId / validcode / passwordEncrypt`，返回 JSON `{"result":"success|fail","message":"..."}`。另有 `method=logout`。

这两个 HTTP 请求都用 `curl.exe --interface <无线网卡IP>` **绑定无线口**发出，否则机器上同时插着网线时探测会从有线口出去、被误判成"已认证"。

### ⚠️ 还没验证的部分

**这套流程我没有跑通过一次真实认证**，因为手边的机器在 WiFi 上扫不到任何 SSID（`netsh wlan show networks` 返回"当前没有可见的网络"），只有失败分支是实测过的（关联不起来时正确报"检查范围内有没有这个 SSID"，并且**不会**误发认证）。请在能连上校园网 WiFi 的设备上试，然后：

- **先跑 `wifi.ps1 -Action status`**（纯只读、不提交任何凭据），看它打印出来的门户地址是不是 `http://202.118.253.94:8080/eportal/index.jsp?...`。那个 IP 来自 2019 年的公开逆向项目 [jeffswt/hitwifi-automata](https://github.com/jeffswt/hitwifi-automata)（MIT），学校可能已经换了地址 —— 换了就用 `config.ini` 里的 `EPORTAL_BASE=` 覆盖。
- 两处编码细节是我按浏览器行为猜的，出错先怀疑它们：
  - `queryString` 我做了**一层** URL 编码（curl 的 `--data-urlencode`）；上面那个 Python 项目实际做了两层。如果门户回了个说不通的错误（不是"用户密码错误"这种明确语义），八成是这里。
  - `service` 字段留空。有些 ePortal 要求填运营商标识。
- 把 `wifi.log` 里"门户应答："那一行原文贴出来，就能定位。

### 用 WiFi 前要知道的两件事

- **在线数限制**：校园网一般限制同账号在线设备数。如果有线 PPPoE 还挂着，无线认证可能回"用户已在线"，或者把有线那条踢掉。脚本不会替你处理这个 —— 按设计它们本来就是二选一。
- **明文提交**：`passwordEncrypt=false` 意味着密码以明文走 **HTTP** 发到 `202.118.253.94:8080`。这是门户自己的设计，你在浏览器里点登录也是同样的明文提交，脚本不会额外变差。但如果校园账号和统一身份认证是同一套，强烈建议在自助系统里把上网密码改成独立的一个。

## 常见错误码（拨号）

| 码 | 含义 |
| --- | --- |
| 691 | 账号或密码错误，或欠费 / 在线设备数超限（账号已在线） |
| 678 | 远程计算机无响应：网线、光猫桥接、运营商侧 |
| 651 | 连接设备报告错误：光猫/线路/运营商侧，**多为瞬时故障**，等 30–60 秒再拨通常就好（实测出现过两次，第三次就成功了） |
| 633 | 拨出端口不可用（WAN Miniport 或网线问题） |
| 676 | 线路忙 |
| 629 | 远程端关闭连接：校园侧/运营商侧终止认证，等 1–2 分钟再试 |
| 623 | 电话簿里找不到这个连接名，检查 `config.ini` 的 `ENTRY` |
| 720 | 该连接缺网络组件，删掉条目重建 |

## 安全说明

- 密码按明文放在 `config.ini`（这是刻意选的简单方案）：`config.ini`、`dial.log`、`wifi.log` 都已写进 `.gitignore`，**永远不要提交或转发这三个文件**（日志里会带账号和门户应答）。
- 拨号时密码会作为命令行参数传给 `rasdial`，那几秒钟出现在进程列表里；WiFi 认证走 `curl --data-urlencode`，同样会短暂出现在 `curl.exe` 的命令行参数里。单用户机器风险很低；介意的话改用 DPAPI 加密存储 + `RasDial` API / `Invoke-WebRequest`（见下面 QuickPPPoE 的做法）。
- 多人共用的电脑建议改用 Windows DPAPI（`ConvertFrom-SecureString`，当前用户范围）或凭据管理器。

## 如果你同时用 Clash

拨号成功后所有流量以系统路由为准。若 Clash 处于 TUN 模式，网卡和路由由 TUN 接管，拨号/认证状态看起来正常但流量走 TUN；关掉 TUN 后需要确认 `ProxyEnable` 也一并复原。这部分不在本仓库职责内。

## 同类项目（都值得一看）

| 项目 | 特点 |
| --- | --- |
| [SakuraChanNya/QuickPPPoE](https://github.com/SakuraChanNya/QuickPPPoE) | C# GUI + 托盘，直接调 `RasDial` API（密码不上命令行）、DPAPI 记住密码，最完整 |
| [jeffswt/hitwifi-automata](https://github.com/jeffswt/hitwifi-automata) | HIT-WLAN 门户认证逆向来源，本项目 `wifi.ps1` 的接口细节参考了它（MIT） |
| [MagicunlimitedWorld/hit-campus-pppoe-clash-fix](https://github.com/MagicunlimitedWorld/hit-campus-pppoe-clash-fix) | 哈工大校园网 PPPoE + Clash Verge 的 TUN / NRPT / split route 修复 |
| [hitlug/hit-network-resources](https://github.com/hitlug/hit-network-resources) | 哈工大网络资源汇总，含 PPPoE / 锐捷 / WLAN 开户缴费说明 |
| [huang051127/broadband-reconnect](https://github.com/huang051127/broadband-reconnect) | 弹窗 + 模拟点击方案，但任务计划触发器（登录后 / 睡眠恢复事件 507）总结得好 |
| [0xRadikal/pppoe-vlan-gpon-diagnostics](https://github.com/0xRadikal/pppoe-vlan-gpon-diagnostics) | 专治错误 651：PPPoE 发现报文 / VLAN / GPON 侧诊断 |

## 文件

```
dial.ps1              有线 PPPoE：拨号 / 断开 / 断线自动重连
dial.bat              控制台启动器（排错用，输出直接打印在窗口里）
wifi.ps1              WiFi：关联 HIT-WLAN + ePortal 门户认证
config.example.ini    配置模板
config.ini            你的真实配置（不提交）
dial.log / wifi.log   运行日志（不提交）
```
