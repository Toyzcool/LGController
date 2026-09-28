# LGController

自研的 macOS 菜单栏工具：用键盘和滑杆控制 **LG 显示器 + 内建显示器** 的亮度与音量、切换声音输出源，并一键切换 LG 显示器的**输入源**。

由两个项目合并而来：亮度/音量控制来自 Monitoring（底层机制参考 [MonitorControl](https://github.com/MonitorControl/MonitorControl)，只保留核心功能），
输入源切换来自同作者的 [SourceShift / InputShifter](https://github.com/Toyzcool/InputShifter)。

**功能说明与使用手册**：[中文](docs/USER_GUIDE.zh-CN.md) · [English](docs/USER_GUIDE.en.md)

**系统要求**：macOS 12 或更高；Apple Silicon 或 Intel Mac（Intel 上的 DDC——LG 亮度、扬声器音量、输入源切换——为试验性支持）。

> 从 Monitoring 或 SourceShift 换过来：请先退出它们并在「系统设置 → 通用 → 登录项」里移除，
> 否则会和 LGController 同时响应媒体键与 `⌘⇧1~4`（重复调节 / 重复发送命令）。

## 功能

- **亮度按鼠标所在屏幕路由**：亮度键调鼠标当前屏（DisplayServices 或 DDC）
- **音量遵循 Mac 原生逻辑**：音量/静音键控制「声音实际输出的设备」= 系统默认输出设备。接了耳机/AirPods 且其为输出源时，无论鼠标在哪块屏都调它；仅当默认输出是显示器自带且不可由 CoreAudio 调节的音频（DP/HDMI）时，才回退 DDC 控制该屏扬声器
- **支持 Mac 键盘调节键**（F1/F2 亮度、F10-F12 音量静音），`⌥⇧+按键` = 1/64 精细步进
- **步长/刻度规则**：亮度与 CoreAudio 音量按 16 档网格（向上取严格更高的下一格线、向下取严格更低的上一格线），从任意值按数下必然精确归零/到顶；音量到 0 即真正静音（scalar 0 + 硬件 mute）。**LG(DDC) 扬声器音量按 1 个 DDC 原始单位步进**（满格 = 设备上报的 max，LG 通常为 100，即 100 档、每按 ±1）
- **无级平滑调节**：指数趋近引擎（~60Hz），DDC 写入实测仅 ~5ms，拖动滑杆和按住按键全程丝滑
- **系统同款 OSD 浮层**：目标屏右上角玻璃胶囊（图标+连续填充条），对齐 macOS 26 原生样式，自绘、不依赖私有 UI；菜单栏弹窗打开时滑杆实时联动键盘调节
- 菜单栏弹窗（NSPopover + SwiftUI，macOS 26/27 玻璃拟态风格）：每台显示器一张圆角卡片（亮度滑杆）；独立的「音量」卡片 = 当前输出源的音量滑杆（点扬声器图标静音）+ 输出源按钮（一点即切换系统声音输出；「播放声音效果的设备」不动）；「输入源」卡片；开机自启动开关、退出。音量卡片与音量键同一套规则，当前输出源调不了音量时如实显示不可调；接了 ≥2 台可 DDC 调音量的屏时，音量卡片没在控制的那几台在各自卡片里另有扬声器音量行。滑杆由 SwiftUI 布局，不再有 NSMenu 自定义视图的裁剪问题；键盘调节时实时联动
- 亮度与 DDC 屏音量记忆到本地、重启恢复；CoreAudio 音量由设备自身记忆（即时可靠读取，无需持久化）
- **输入源切换**（合并自 SourceShift）：`⌘⇧1~4` 全局快捷键或弹窗「输入源」卡片，一键把 LG 显示器切到 Type C / DP / HDMI1 / HDMI2；显示器正在显示别的设备时也能「盲按」切回 Mac。详见下文

## 输入源切换

| 快捷键 | 输入源 | LG 私有码（VCP `0xF4`） |
|---|---|---|
| `⌘⇧1` | Type C（USB-C / 雷雳） | `0xD1` |
| `⌘⇧2` | DP | `0xD0` |
| `⌘⇧3` | HDMI1 | `0x90` |
| `⌘⇧4` | HDMI2 | `0x91` |

- 快捷键用 Carbon `RegisterEventHotKey` 全局注册，**不需要辅助功能权限**，任何应用在前台都生效；显示器正显示别的设备时也能盲按（DDC 走线缆里的 I²C 信道，不要求 Mac 画面正被显示）。
- **目标显示器**：鼠标所在的可 DDC 外接屏 → 否则第一台可 DDC 外接屏。若显示器切走后已从系统显示器列表消失（常见），自动兜底：向所有 External DCP 端点盲发，都没有时再试系统默认 AVService（即 SourceShift 原本的路径）。
- 每条命令在该显示器自己的串行队列上发送，不会与亮度/音量读写抢 I²C 总线；发送前要求该屏总线已静默 ≥250ms（刚打开弹窗就点时会先等回读结束）。发送时序逐一照搬 SourceShift v1.0.2（两遍「等 10ms → 写」）。被显示器确认后在鼠标所在屏显示「已发送切换 → HDMI1」浮层（I²C 确认 ≠ 显示器执行了，以画面为准）；未被确认时先在同一台屏上重试一次，再为这台屏重新匹配 I²C 端点发一次（只认能确认属于它的端点，绝不写到别的显示器）；仍失败响提示音。同一台屏上连续点击时，旧请求的重试会被新请求取代，不会把选择改回去。每次发送都记录到 `~/Library/Logs/LGController/diag.log`。
- 组包与 SourceShift 实际发出的字节逐字节一致（自检里有对照用例），例如 Type C = `84 03 F4 00 D1 9C` @ 数据地址 `0x50`。

**限制（与 SourceShift 相同）**

- `0xF4` 是 LG 私有码，只在 LG 显示器上验证过；该寄存器**只写不可读**，无法回读确认是否切换成功，以显示器画面为准。LG 按型号/固件开放该命令：实测一台 LG HDR 4K（EDID `GSM 0x7707`）每次都确认收到命令、同通道的亮度命令也能执行，但输入源不切换（用摇杆手动切换正常）。
- **macOS 26 起**，显示器切到别的输入后系统可能**拆除整条显示链路**，I²C 端点随之消失——此时无法从 Mac 盲按拉回，切回后偶尔需重插线缆。这是系统行为变化。
- `⌘⇧3 / ⌘⇧4` 与系统截图快捷键相同，可能被覆盖；如需保留截图习惯，可在「系统设置 → 键盘 → 键盘快捷键 → 截屏」里给截图换键。
- 请**退出 SourceShift 并移除它的登录项**（系统设置 → 通用 → 登录项），否则两个 App 会同时响应同一组快捷键（结果无害，但会重复发送命令）。

## 控制通道（实测）

| 目标 | 通道 |
|---|---|
| LG UltraFine（DP 连接）亮度 | DDC/CI `VCP 0x10`（Apple Silicon：IOAVService I²C；Intel：IOFramebuffer I²C） |
| 音量/静音（任意屏按键） | CoreAudio 系统默认输出设备（耳机/AirPods/内建扬声器/USB 显示器音频）；到 0 时 `kAudioDevicePropertyMute` 真静音 |
| LG UltraFine 扬声器（作为输出源时 / 弹窗音量卡片） | DDC/CI `VCP 0x62`（DP 音频无法由 CoreAudio 调节，回退 DDC） |
| 内建屏亮度 | 私有 `DisplayServices` 框架 |
| LG 输入源切换 | DDC/CI LG 私有 `VCP 0xF4`，数据地址 `0x50`（只写） |
| 雷雳版 UltraFine / Studio Display（如未来更换） | 自动识别为苹果协议屏：亮度走 DisplayServices，音量随其 USB 音频成为默认输出设备时由 CoreAudio 调节 |

## 构建与安装

```bash
./build.sh                      # 构建、签名并安装到 /Applications/LGController.app（需要 Xcode CLT）
open /Applications/LGController.app
```

首次启动会弹「辅助功能」授权提示（媒体键拦截必需）：
**系统设置 → 隐私与安全性 → 辅助功能 → 打开 LGController**。
未授权时菜单栏滑杆照常可用，只是键盘快捷键不生效（每 3 秒自动重试，授权后立即生效）。

自检（不进 GUI，验证 DDC/DisplayServices 管线，亮度会闪动一档）：

```bash
.build/release/LGController --selftest
.build/release/LGController --osdtest    # 每个屏幕右上角演示 HUD 浮层样式
.build/release/LGController --uipreview  # 渲染菜单栏弹窗 UI 到 /tmp/menu_preview_{light,dark}.png
/Applications/LGController.app/Contents/MacOS/LGController --login-item on   # 开机自启动 on / off / status（须从 App 包内运行）
```

## 注意事项

- **ad-hoc 签名**：每次重新构建后签名摘要变化，需在「辅助功能」里重新勾选（先移除旧条目再添加）。运行一次 `./setup-codesign-identity.sh` 建自签名证书即可免去（build.sh 也会沿用旧项目的「Monitoring Self-Signed」证书）。
- 自检**会写真实硬件**（亮度闪动一档、音量走一遍状态机后还原）；运行前先退出 GUI 版，避免两个进程同时访问同一条 I²C 总线。
- 显示器插拔/睡眠唤醒会自动重建控制通道（1.5s 防抖）。
- 启动时以 DDC 回读的**硬件真实值**校准内部状态；若用 LG 物理按键改过亮度/音量，空闲 5 秒后会自动重新同步，按键第一下从真实值对齐回网格线。
- `⌥+亮度/音量键`（不带⇧）会放行给系统（保留原生打开设置面板的行为）。

## 代码结构

```
Sources/LGController/
├── main.swift            入口（--selftest 支持）
├── AppDelegate.swift     组装 + 重配置/睡眠守护
├── DisplayManager.swift  枚举、分类（苹果协议 vs DDC）、鼠标定位
├── Display.swift         显示器模型（AppleProtocolDisplay / DDCDisplay）
├── DDC.swift             DDC/CI 两种通道：Apple Silicon（IOAVService）/ Intel（IOFramebuffer I²C）+ 显示器匹配
├── SmoothRamp.swift      平滑调节引擎（指数趋近，慢通道自动降频）
├── MediaKeyTap.swift     CGEventTap 媒体键拦截
├── InputSource.swift     输入源切换：InputSource / InputSwitcher / ⌘⇧1~4 热键（合并自 SourceShift）
├── KeyRouter.swift       媒体键路由：亮度按鼠标所在屏，音量/静音交给 VolumeControl
├── VolumeControl.swift   音量模块：按「当前输出源」解析目标（CoreAudio / DDC），弹窗与按键共用；输出源切换
├── AudioController.swift CoreAudio 设备查询、音量/静音读写、输出设备枚举/切换与变化监听
├── AudioVolume.swift     CoreAudio 有状态音量（内部意图值步进，精确归零+真静音）
├── OSD.swift             自绘 HUD 浮层（macOS 26 系统样式）
├── PrivateAPI.swift      dlsym 桥接私有符号
├── LaunchAtLogin.swift   开机自启动：macOS 13+ 用 SMAppService，macOS 12 经「系统事件」管理登录项
├── DiagLog.swift         诊断日志 ~/Library/Logs/LGController/diag.log（输入源发送、DDC 回读）
├── StatusMenu.swift      菜单栏弹窗 UI（NSPopover 承载 SwiftUI，含视图模型 PopoverModel）
├── Preview.swift         `--uipreview` 离屏渲染弹窗 UI 到 /tmp（核对样式用）
└── SelfTest.swift        端到端自检
```

其他脚本：
- `makeicon.swift`：用 Apple Color Emoji 生成 App 图标。换图标：`swift makeicon.swift "🖥️" Resources/AppIcon.icns` 后重跑 `./build.sh`
- `setup-codesign-identity.sh`：一次性创建自签名证书，使重建后辅助功能授权不失效

## 许可

MIT 许可证，见 [LICENSE](LICENSE)。DDC 部分源自 [MonitorControl](https://github.com/MonitorControl/MonitorControl)（MIT），其版权与许可声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
