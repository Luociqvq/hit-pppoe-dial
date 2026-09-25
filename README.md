# 一键 PPPoE 拨号（哈工大 HITnet 校园网实测 · 零依赖 · 断线自动重连）

一个双击就完成拨号的 Windows PowerShell 脚本：不用打开"网络连接"、不用每次手输账号密码，也不靠模拟鼠标点击。同样适用于光猫桥接的家用宽带。

在 Windows 11 + Windows PowerShell 5.1 上实测。仅调用系统自带的 `rasdial` 和 NetAdapter 系列 cmdlet，**无第三方依赖、无 GUI、无需管理员权限**。

## 适合谁

- 光猫桥接、每次上网都要手动拨一次并输账号密码的家用宽带
- 校园网有线 PPPoE（例如哈工大 `HITnet` 这类"账号 = 学号"的 PPPoE 接入）
- 只想要桌面上一个图标，不想装带界面的拨号工具

## 快速开始

1. 先在系统里建好宽带连接（控制面板 → 网络和共享中心 → 设置新的连接或受限的连接 → 连接到 Internet → 宽带 PPPoE），记住它的名字，默认 `宽带连接`。
2. `copy config.example.ini config.ini`，填入 `ACCOUNT` / `PASSWORD`（`ENTRY` 改成第 1 步的名字）。
3. 生成桌面图标：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File dial.ps1 -Action install
   ```

4. 双击桌面「宽带拨号」= 拨号；已连接时再双击 = 断开。

想先手动试一次（结果直接打印在控制台）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File dial.ps1 -Action dial
```

## 参数

| `-Action` | 作用 |
| --- | --- |
| `toggle`（默认） | 已连接就断开，未连接就拨号。桌面图标走的就是这个 |
| `dial` / `hangup` | 只拨号 / 只断开 |
| `status` | 显示是否已连接和当前 IP |
| `watch` | 前台跑断线重连循环（一般由脚本自己在后台拉起） |
| `config` | 用记事本打开 `config.ini` |
| `install` / `uninstall` | 创建 / 移除桌面图标（`uninstall` 会一并停掉后台监控） |

`-Quiet` 只写日志不弹窗。

## 行为

- 拨号成功后自动拉起一个隐藏的后台监控进程：每隔 `RETRY_SECONDS` 秒检查一次，掉线就自动重拨。
- 连续 5 次重连失败后监控自行停止 —— 避免密码错了还拿错误凭据反复砸运营商认证。
- **手动断开会同时停掉后台监控**，否则你会发现"断不掉"（刚断就被重拨回来）。
- `WATCHER=0` 可以彻底关掉自动重连。
- 成功**不弹窗**，失败才弹窗（并带上错误码的含义）；所有过程写在同目录 `dial.log` 里。

## 踩过的三个坑（这份代码主要价值在这儿）

1. **PPPoE 接口在 `Get-NetAdapter` 里可能根本查不到。** 实测有一类机器上，`Get-NetAdapter`、`Get-NetAdapter -IncludeHidden`、`Win32_NetworkAdapter` 都列不出宽带连接对应的接口（`Get-NetIPInterface` 里却有，ifIndex 是个"多出来"的值）。用 `Get-NetAdapter` 判在线状态会稳定误报"未连接"，于是对着已经连好的线再拨一次。这里改用：

   ```powershell
   Get-NetIPInterface -InterfaceAlias 宽带连接 -AddressFamily IPv4   # ConnectionState -eq 'Connected'
   ```

   顺带说：那些靠 `rasphone.exe` 弹窗再模拟点击"连接"按钮的方案，多半也是被这类接口可见性问题逼出来的。

2. **`.ps1` 必须存成 UTF-8 带 BOM**。否则 Windows PowerShell 5.1 会按系统 ANSI（GBK）读取，脚本里的 `宽带连接` 变成乱码字符串，拨号直接报 623「找不到电话簿条目」。

3. **不要解析 `rasdial` 的文本来判断成败。** 它的输出是本地化的，而且中文环境下是 GBK 编码。用退出码：`& rasdial ... ; $LASTEXITCODE`。

   附带一个零风险的权限探测法：拿一个不存在的连接名去拨

   ```powershell
   rasdial __probe__ a b
   ```

   返回 `623`（找不到条目）说明普通用户权限就能拨号；返回 `5`（拒绝访问）才需要提权。它不会碰到你的真实账号。

## 常见错误码

| 码 | 含义 |
| --- | --- |
| 691 | 账号或密码错误，或欠费 / 在线设备数超限（账号已在线） |
| 678 / 651 | 远程计算机无响应：网线、光猫桥接、运营商侧 |
| 633 | 拨出端口不可用（WAN Miniport 或网线问题） |
| 676 | 线路忙 |
| 629 | 远程端关闭连接：校园侧/运营商侧终止认证，等 1–2 分钟再试 |
| 720 | 该连接缺网络组件，删掉条目重建 |

## 安全说明

- 密码按明文放在 `config.ini`（这是刻意选的简单方案）：`config.ini` 和 `dial.log` 已写进 `.gitignore`，**永远不要提交或转发这两个文件**。
- 拨号时密码会作为命令行参数传给 `rasdial`，那几秒钟会出现在进程列表里。单用户机器风险很低；介意的话改用 DPAPI 加密存储 + `RasDial` API 拨号。
- 多人共用的电脑建议改用 Windows DPAPI（`ConvertFrom-SecureString`，当前用户范围）或凭据管理器。
- 校园网密码通常和统一身份认证是同一套 —— 那就不该明文放着。

## 如果你同时用 Clash

拨号成功后所有流量以系统路由为准。若 Clash 处于 TUN 模式，网卡和路由由 TUN 接管，拨号状态看起来正常但流量走 TUN；关掉 TUN 后需要确认 `ProxyEnable` 也一并复原。这部分不在本脚本职责内。

## 同类项目（都值得一看）

| 项目 | 特点 |
| --- | --- |
| [Luociqvq/hit-wlan-autologin](https://github.com/Luociqvq/hit-wlan-autologin) | 姊妹仓库：HIT-WLAN 无线一键登录（跳过浏览器门户），和本仓库共用同样的思路但互不依赖 |
| [SakuraChanNya/QuickPPPoE](https://github.com/SakuraChanNya/QuickPPPoE) | C# GUI + 托盘，直接调 `RasDial` API（密码不上命令行）、DPAPI 记住密码，最完整 |
| [MagicunlimitedWorld/hit-campus-pppoe-clash-fix](https://github.com/MagicunlimitedWorld/hit-campus-pppoe-clash-fix) | 哈工大校园网 PPPoE + Clash Verge 的 TUN / NRPT / split route 修复 |
| [hitlug/hit-network-resources](https://github.com/hitlug/hit-network-resources) | 哈工大网络资源汇总，含 PPPoE / 锐捷 / WLAN 开户缴费说明 |
| [huang051127/broadband-reconnect](https://github.com/huang051127/broadband-reconnect) | 弹窗 + 模拟点击方案，但任务计划触发器（登录后 / 睡眠恢复事件 507）总结得好 |
| [0xRadikal/pppoe-vlan-gpon-diagnostics](https://github.com/0xRadikal/pppoe-vlan-gpon-diagnostics) | 专治错误 651：PPPoE 发现报文 / VLAN / GPON 侧诊断 |

## 文件

```
dial.ps1              主脚本
dial.bat              控制台启动器（排错用，输出直接打印在窗口里）
config.example.ini    配置模板
config.ini            你的真实配置（不提交）
dial.log              运行日志（不提交）
```
