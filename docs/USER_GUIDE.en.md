# LGController — Features & User Guide

LGController is a macOS menu-bar app for controlling your displays and sound from the Mac keyboard's brightness and volume keys or from a popover. It sets the brightness of LG monitors (and other DDC/CI monitors) and of the built-in display, sets the volume of the current sound output device, switches the system sound output, and changes the input source of LG monitors with ⌘⇧1–⌘⇧4. It was created by merging two earlier apps, Monitoring (brightness and volume) and SourceShift (LG input switching), and replaces both.

中文版：[USER_GUIDE.zh-CN.md](USER_GUIDE.zh-CN.md) · Version 1.0.0 (build 1)

> The app's interface is in Simplified Chinese only. This guide quotes each on-screen label in Chinese and gives an English gloss after it, e.g. 「开机自启动」 (Launch at login).

---

## Part 1 — Features

### Overview

| What | Controlled with |
|---|---|
| Brightness of the built-in display and Apple displays (Studio Display, Thunderbolt UltraFine and similar) | Apple's private DisplayServices framework |
| Brightness of LG and other external monitors | DDC/CI, VCP `0x10` |
| Volume and mute of headphones, AirPods, built-in speakers, USB audio and similar | CoreAudio |
| Volume and mute of a monitor's own speakers (DP/HDMI audio) | DDC/CI, VCP `0x62` (volume) / `0x8D` (mute) |
| System sound output device | Output tiles in the popover (sets the CoreAudio default output) |
| Input source of LG monitors (Type C / DP / HDMI1 / HDMI2) | LG's private VCP `0xF4` (write-only) |

**Requirements at a glance**

- macOS 13.0 or later. The app lives in the menu bar only; it has no Dock icon and no main window.
- **An Apple Silicon Mac** for everything that uses DDC: LG brightness, LG speaker volume and input switching. DDC/CI is implemented only through IOAVService on Apple Silicon. On other Macs, non-Apple external displays get no DDC channel and their card shows 「亮度不可控」 (Brightness not controllable).
- There is no prebuilt download. You build the app from source with `./build.sh`, which needs the Xcode Command Line Tools (see Part 2, [section 2](#2-build--install)).
- Accessibility permission is needed only for the brightness, volume and mute keys. Everything else, including ⌘⇧1–4, works without it.

### Brightness

- **Keys.** Brightness Down / Brightness Up (F1 / F2 on Mac keyboards) adjust the **display under the mouse pointer**. The HUD on that display shows the new value.
- **Which display.**
  - When the pointer is on a mirrored display, the key goes to the display it mirrors. Mirrored displays and virtual displays never get their own card and are never controlled separately.
  - If the pointer isn't on any recognized display (for example it's on a virtual display) or the app can't tell, it uses the first display in its list. External displays come before the built-in one.
- **Channel.** The built-in display, and any display whose brightness DisplayServices can read (Studio Display, Thunderbolt UltraFine and similar), are controlled through DisplayServices. All other external displays use DDC/CI. For DDC displays the app uses the maximum the monitor reports, or 100 if it reports nothing.
- **Step size.** Brightness is divided into 16 steps. Each press moves to the next 1/16 step line: up goes to the next line strictly above the current value, down to the previous line strictly below it. A value that sits between lines (for example one read from the monitor) snaps to the neighbouring line first, so a few presses from any value always land exactly on 0% or 100%. Examples: 21% down → 3/16 (18.75%), 21% up → 4/16 (25%), 25% up → 31.25%, 3% down → 0%, 97% up → 100%.
- **Fine step.** Hold ⌥⇧ while pressing a brightness key to move 1/64 instead of 1/16.
- **Smooth changes.** Brightness from the keys or the sliders fades to the target at about 60 Hz (exponential approach) instead of jumping. On a slow DDC link the fade runs as fast as the monitor accepts writes.
- **Displays that can't be controlled.** If the display under the pointer has no working channel (no DDC channel was matched, or DisplayServices isn't available), the key is passed to macOS unchanged, and the display's card shows 「亮度不可控」 (Brightness not controllable).
- **Apple displays.** For built-in and Apple displays, the app re-reads the real brightness just before each key step and when the popover opens, unless the app itself changed it in the last 3 s. This picks up changes from auto-brightness or macOS's own controls.

### Volume & mute

Volume Up, Volume Down and Mute (F12, F11, F10) act on the **current system sound output** (the default output device), not on the display under the pointer. The app picks the target with these rules, in order:

1. If the current output has a volume CoreAudio can set (headphones, AirPods, built-in speakers, USB audio), the app sets it through CoreAudio.
2. If the output's volume can't be set by CoreAudio but it matches **exactly one** monitor whose volume can be set over DDC, the app sets that monitor's speakers over DDC. The match is by name: an exact match ignoring case and spaces first, otherwise one name containing the other. If no name matches, the output is DP/HDMI audio and only one monitor with DDC volume is connected, that monitor is assumed.
3. Otherwise, if the display under the pointer is a monitor with DDC volume, its speakers are set over DDC.
4. Otherwise, if the output is DP/HDMI display audio (the app just can't tell which monitor), volume can't be adjusted.
5. Otherwise the built-in speakers are used, if their volume can be set.
6. If none of these apply, volume can't be adjusted.

**Headphones, AirPods, built-in speakers, USB audio (CoreAudio)**

- Each press moves 1/16 (⌥⇧: 1/64) using the same step-line rule as brightness, starting from the app's own target value, so you always reach exactly 0% or 100%.
- Reaching 0 is a real mute: the volume is set to 0 and the device's hardware mute is turned on.
- Mute is a separate state that remembers the previous level. Any volume key, up or down, unmutes and steps from that remembered level, as on a standard Mac.
- The Mute key toggles mute. Unmuting from 0 restores the level from before the mute (at least 1/16).
- While muted, the HUD and the popover show 0.
- Changes made elsewhere (other apps, Control Center, the menu-bar volume slider) are picked up before the next step if they differ by more than 2%.
- The app doesn't save these levels, because the device itself remembers them.

**Monitor speakers (DDC)**

- Each press moves exactly 1 raw DDC unit. Full scale is the maximum the monitor reports; on LG that is 100, so each press is ±1%. ⌥⇧ has no effect here.
- Mute and volume 0 are the same thing: muting shows 0, and stepping down to 0 mutes.
- Volume Up while muted goes from 0 to 1 unit and unmutes; Volume Down while muted stays at 0 and muted. Pressing Mute again restores the volume from before the mute (at least 1 unit).
- Dragging the slider to 0 mutes.
- Rapid changes are merged, so only the latest value is written, with about 50 ms between DDC writes.

**Mute key.** Only the first key-down counts. Key repeats and key-up are swallowed (not passed to macOS). The HUD shows the resulting level, with a crossed-out speaker when muted.

**When volume can't be adjusted.** The key is still captured and nothing changes. The volume keys' HUD shows a crossed-out speaker in a circle with an empty bar and no text; the Mute key shows the filled version of the same icon. If sound is going to a monitor the app can't identify, it does **not** adjust the built-in speakers instead. But when the output can't be matched and the pointer is on a monitor with DDC volume, the keys change that monitor's speakers (rule 3), even if sound isn't playing there, for example with a multi-output device.

**Two identical monitors.** Two monitors with the same name (for example two 「LG HDR 4K」) can't be told apart from the audio device name. The app doesn't guess: the volume keys control the DDC monitor under the pointer. If the pointer is on the built-in or an Apple display, the keys show the can't-adjust HUD. The popover's Volume card tells you to use the display cards (see [Menu bar popover](#menu-bar-popover)).

**Feedback sound.** When you release a volume key, the app plays the standard macOS volume sound if the new volume is above 0 and not muted. It also plays after the Mute key unmutes. It doesn't play on key auto-repeat, for popover slider changes, or when volume can't be adjusted. It follows the macOS setting "Play feedback when volume is changed" (「更改音量时播放反馈」 on a Chinese system; preference key `com.apple.sound.beep.feedback`: 0 means no sound, unset means the sound plays). The sound is the system's own `volume.aiff` (from BezelServices); if macOS doesn't have that file, nothing plays.

### Sound output switching

The popover's 「音量」 (Volume) card has a grid of tiles below its slider, one per sound output device.

- **What's listed:** every device that can play sound, isn't hidden and can be the system default output, in CoreAudio's enumeration order (not necessarily the order in System Settings → Sound). Devices that report they can't be the default output are left out. This usually covers the helper virtual devices of meeting and screen-recording apps.
- **Current output:** highlighted in your accent colour.
- **Switching:** click a tile to make that device the system default output. Clicking the current output does nothing. Only the default output changes; the **"Play sound effects through" device is not changed**.
- **Duplicate names:** devices with the same name (for example the DP audio of two identical monitors) get 「 · 音频1」, 「 · 音频2」 (· Audio 1, · Audio 2) appended. This numbering is unrelated to the numbering macOS gives displays, so don't use it to work out which monitor is which.
- **Tooltips:** 「当前输出源：<name>」 (Current output: <name>) on the current tile, 「切换声音输出到 <name>」 (Switch sound output to <name>) on the others.
- **Icons:**

| Device | Icon (SF Symbol) |
|---|---|
| Bluetooth, name contains "AirPods" | `airpods` |
| Other Bluetooth | `headphones` |
| DisplayPort / HDMI (monitor audio) | `display` |
| USB / Thunderbolt | `hifispeaker` |
| AirPlay | `airplayaudio` |
| Built-in, name contains "headphone" or 「耳机」 (headphones) | `headphones` |
| Other built-in | `laptopcomputer` |
| Anything else | `speaker.wave.2` |

### Input source switching (LG)

| Shortcut | Input | LG code (VCP `0xF4`) |
|---|---|---|
| ⌘⇧1 | Type C (USB-C / Thunderbolt) | `0xD1` |
| ⌘⇧2 | DP | `0xD0` |
| ⌘⇧3 | HDMI1 | `0x90` |
| ⌘⇧4 | HDMI2 | `0x91` |

- **Global hotkeys.** ⌘⇧1–4 work whichever app is in front and **don't need Accessibility permission**. Use the number keys on the main row; the numeric keypad doesn't work. The shortcuts are fixed in the code and can't be changed in the app. The same four inputs are also tiles in the popover's 「输入源」 (Input source) card.
- **Always on.** The hotkeys are never paused. They keep working while the displays are asleep, right after wake, and while displays are being reconfigured, so you can switch back "blind" even while the monitor is showing another device.
- **Target monitor.** The command goes to the DDC external monitor under the pointer (for the popover tiles, the one the popover is on; see [section 6](#6-switching-the-monitors-input--what-to-expect-and-how-to-get-back)), otherwise to the first DDC external monitor in the list. For a directed send, the built-in display, Apple displays, mirrored displays and virtual displays are never chosen.
- **No monitor found.** If no DDC external monitor is listed (typically because the monitor disappeared after you switched it away), the command is sent blind to every external I²C endpoint the Mac still has, whichever monitor it belongs to. If there are none, it goes to the system's default AVService. Blind sends aren't retried.
- **Command format.** The command is written to DDC data address `0x50` (not the standard `0x51`), for example Type C = `84 03 F4 00 D1 9C`. Each command is written twice, about 10 ms apart; if the first write isn't acknowledged, the second isn't sent.
- **Waiting for a quiet link.** Before sending, the app waits until that monitor's DDC link has been quiet for at least 250 ms (for example, if you click right after opening the popover, the popover's read-backs finish first), so there may be a short delay.
- **Sent is not switched.** The register is write-only, so the monitor can't report which input is active. When the monitor acknowledges the command at the I²C level, the HUD shows 「已发送切换 → <input>」 (Switch sent → <input>), e.g. 「已发送切换 → HDMI1」. Check the screen itself to see whether it switched.
- **Retries.** If a directed send isn't acknowledged, the app retries once on the same monitor. It then retries once on a freshly matched I²C endpoint, but only one that can be confirmed to belong to the same monitor; it never writes to other monitors. If that also fails, you hear the alert sound and the HUD shows 「<input> 未送达显示器」 (<input> not delivered to display).
- **Rapid presses.** A newer request on the same monitor cancels the retries older requests haven't started yet (cancelled requests show no HUD and make no sound), so a late retry normally can't flip the input back. Writes already sent aren't undone; in rare cases (when the older request is in its "re-match endpoint" step) the older command can still arrive after the newer one and show its own HUD or alert. A blind send cancels the pending retries on every monitor.
- **Screenshot shortcuts.** ⌘⇧3 and ⌘⇧4 are also the macOS screenshot shortcuts. See [Troubleshooting](#9-troubleshooting).

### Menu bar popover

![LGController popover (light appearance)](images/popover-light.png)

> This picture was rendered offscreen by `--uipreview` from **sample data**, not captured on a real Mac: 「LG HDR 4K」 at 72% brightness, 「Built-in Retina Display」 at 55%; outputs 「MacBook Pro扬声器」 (MacBook Pro Speakers), 「外置耳机」 (External Headphones, current output, volume 45%) and 「LG HDR 4K」; input target 「LG HDR 4K」; Accessibility not granted; launch at login on. A dark version is at [images/popover-dark.png](images/popover-dark.png).

Click the sun icon (`sun.max`) in the menu bar to open the popover, which is 300 pt wide. Click the icon again, or anywhere outside the popover, to close it. Each time it opens, it re-reads the monitors' current values, the Accessibility and launch-at-login status, and the list of sound outputs. While it's open, its sliders follow changes you make with the keys and changes from outside the app (plugging in headphones, Control Center, the system volume slider).

From top to bottom:

1. **Header:** the `slider.horizontal.3` icon and 「LGController」.
2. **One card per display**, named as in macOS, external displays first.
   - A brightness slider with a sun icon, when brightness can be controlled.
   - A second row with the monitor's speaker volume, shown only when two or more monitors with DDC volume are connected, and only on the monitors the Volume card isn't already controlling. Clicking its speaker icon toggles mute. With only one monitor with DDC volume, there is no such row: its speakers can be adjusted only in the Volume card, and only while it is the current output.
   - A card with neither row shows 「亮度不可控」 (Brightness not controllable).
   - With no displays at all, 「未检测到显示器」 (No displays detected) is shown instead of the cards.
   - If macOS has no name for a display, the EDID product name is used, then 「内建显示器」 (Built-in display) or 「显示器 <id>」 (Display <id>).
3. **「音量」 (Volume) card.**
   - The header shows the current output on the right. 「 · DDC」 is appended when the volume goes over DDC to a monitor's speakers. 「无输出设备」 (No output device) appears when there is no output, or when the current output isn't among the output tiles.
   - If the output can be adjusted, there's a volume slider; click its speaker icon to toggle mute.
   - If not, the card shows 「请在上方显示器卡片中调节扬声器音量」 (Adjust the speaker volume in the display cards above) when the output is monitor audio shared by two or more monitors with the same name and a display card has a volume row. In every other case it shows 「该输出设备不支持调节音量」 (This output device doesn't support volume adjustment).
   - The card controls only the current output itself. Unlike the keys, it never falls back to the monitor under the pointer or to the built-in speakers, so it can't quietly adjust speakers that aren't playing. Only when there is no default output at all does it fall back to the built-in speakers (if their volume can be set).
   - Below the slider are the output tiles (see [Sound output switching](#sound-output-switching)).
4. **「输入源」 (Input source) card.**
   - The header shows the monitor that will receive the command, or 「未识别外接屏」 (No external display recognized) when no DDC external monitor is found. The tiles still work in that case, through the blind fallback.
   - Four tiles: Type C (⌘⇧1), DP (⌘⇧2), HDMI1 (⌘⇧3), HDMI2 (⌘⇧4). Tooltip: 「切换到 <input>（⌘⇧n）」 (Switch to <input> (⌘⇧n)), e.g. 「切换到 HDMI1（⌘⇧3）」.
   - No tile is ever shown as selected, because the monitor's current input can't be read.
5. A divider.
6. **Orange warning** 「启用键盘快捷键需授予辅助功能权限…」 (Keyboard shortcuts require Accessibility permission…), shown only while the permission is missing. Clicking it asks macOS for the permission and opens System Settings → Privacy & Security → Accessibility.
7. **「开机自启动」 (Launch at login)** switch (power icon).
8. **「退出 LGController」 (Quit LGController)** (`xmark.circle` icon) quits the app.

### On-screen display (HUD)

- LGController draws its own HUD rather than using macOS's: a 230 × 40 pt glass capsule with 14 pt rounded corners.
- It appears in the top-right corner of the screen, just below the menu bar: 16 pt from the right edge and 12 pt from the top.
- On the left is an SF Symbol icon. On the right is either a continuous fill bar (brightness, volume) or a text label (input source).
- It fades in over 0.12 s, stays for 1.5 s after the last change, then fades out over 0.35 s.
- It floats above everything, including full-screen apps, shows on every Space, and never takes mouse clicks.
- **Which screen:** brightness and volume HUDs appear on the display under the pointer, even when the sound is coming from another device; if the pointer isn't on a recognized display, on the first display in the list. Input-source HUDs also appear on the display under the pointer (same rule; on the main display if no displays are recognized at all), because the monitor being switched may be going blank.
- Popover sliders don't show a HUD.

| HUD | Icon (SF Symbol) | Content |
|---|---|---|
| Brightness | `sun.max.fill` | Fill bar |
| Volume | below 1/3: `speaker.wave.1.fill`; below 2/3: `speaker.wave.2.fill`; otherwise `speaker.wave.3.fill`; muted or 0: `speaker.slash.fill` | Fill bar |
| Volume can't be adjusted | volume keys: `speaker.slash.circle`; Mute key: `speaker.slash.circle.fill` | Empty bar |
| Input sent | the input's icon: Type C `cable.connector`, DP `display`, HDMI1/HDMI2 `tv` | 「已发送切换 → <input>」 |
| Input not delivered | `exclamationmark.triangle.fill` | 「<input> 未送达显示器」 |

### Background behavior

**Reading values from the monitor**

- At launch, and every time the display list is rebuilt, each DDC monitor's brightness, volume and mute are read from the monitor in the background, along with its maximum values. The app adopts them unless you changed that value in the last 2 s.
- Until the read finishes, or if it fails (some monitors don't answer DDC reads reliably), the app uses the last saved value, or 50% brightness and 25% volume if nothing has been saved.
- There is **no periodic polling**. All DDC values are read only when the display list is rebuilt (launch, wake, display change) and when you open the popover. Switching output in the popover, or a change of the system default output, re-reads only the volume and mute of the DDC monitor that becomes the output. These popover and output re-reads skip any value the app changed in the last 5 s, and adopt a value only if it differs by more than 2% (or the mute state differs).
- So after using the monitor's own buttons, a key press made without opening the popover first steps from the app's old value.
- Built-in and Apple displays: brightness is re-read automatically before each brightness key press and when the popover opens (see [Brightness](#brightness)).

**What is saved**

- Values are saved per display, keyed by the display's UUID, in the `com.toyzcool.LGController` preferences: brightness for each display (`brightness-<uuid>`), plus volume (`volume-<uuid>`), mute state (`muted-<uuid>`) and pre-mute volume (`premute-<uuid>`) for DDC monitors. There is also a first-launch flag, `LaunchAtLogin.firstLaunchHandled`.
- Saved values are **not** written to the monitor at launch. They only stand in until the read from the monitor succeeds.
- Built-in and Apple displays always start from their live brightness.
- CoreAudio volumes are not saved.

**Sleep, wake and display changes**

- When the Mac or its displays go to sleep, the app stops handling the brightness, volume and mute keys, and they go to macOS.
- After waking (the Mac or its displays), and after any display change (a display added, removed, enabled or disabled, a new main display, a resolution or mode change), key handling stays paused. The app waits until 1.5 s have passed with no further change (each new event restarts the wait), then re-lists displays, re-matches the DDC channels and resumes key handling immediately. The DDC values are re-read in the background; until that finishes, the saved values are used.
- ⌘⇧1–4 are never paused.

**Diagnostics log**

- Input-source commands and DDC reads are logged to `~/Library/Logs/LGController/diag.log`.
- When the file passes 1 MB it is renamed to `diag.log.1`, replacing the previous one, so the logs never take more than about 2 MB.
- See [Troubleshooting](#9-troubleshooting) for what to look for.

---

## Part 2 — User Guide

### 1. Requirements

- **Mac:** Apple Silicon. DDC control is implemented only for Apple Silicon; without it there is no LG brightness, LG speaker volume or input switching. `build.sh` builds for the architecture of the Mac you run it on.
- **macOS:** 13.0 or later.
- **Build tools:** Xcode Command Line Tools with Swift 5.7 or later (Command Line Tools 14.1 or newer). The full Xcode app isn't needed.
- **Source:** the GitHub repository `Toyzcool/LGController`.
- **Monitor:** an LG monitor for input switching, and it depends on the model and firmware (see [section 10](#10-known-limitations)). Brightness and speaker volume also work with other monitors that support DDC/CI.
- **Permission:** Accessibility, for the brightness, volume and mute keys only.

### 2. Build & install

There is no prebuilt app. Build it once, and again whenever you update the source.

1. Install the Command Line Tools if you don't have them:

   ```bash
   xcode-select --install
   ```

   Then check the Swift version (5.7 or later is needed):

   ```bash
   swift --version
   ```

2. Get the source:

   ```bash
   git clone https://github.com/Toyzcool/LGController.git
   ```

   ```bash
   cd LGController
   ```

   If cloning asks you to sign in or says the repository can't be found (it isn't public, or your account has no access), authenticate with GitHub first (for example run `gh auth login` and choose HTTPS, or set up a personal access token / Git credential helper) and make sure your account can access `Toyzcool/LGController`.

3. Build and install:

   ```bash
   ./build.sh
   ```

   The script:
   1. runs `swift build -c release`;
   2. assembles `build/LGController.app` (it generates the app icon from ☀️ if `Resources/AppIcon.icns` is missing);
   3. clears extended attributes and code-signs the app;
   4. quits any running LGController (it asks with `osascript` first, then uses `pkill`);
   5. replaces `/Applications/LGController.app` with the new build, signs it again and verifies it.

   A successful run prints 「签名校验通过」 (Signature verified), then 「✅ 已安装并签名: /Applications/LGController.app」 (Installed and signed) and a 「启动: open …」 (Launch: open …) hint. With ad-hoc signing a note about re-granting Accessibility follows. If 「签名校验通过」 is missing, verification failed. The script does **not** start the app.

4. Start the app:

   ```bash
   open /Applications/LGController.app
   ```

Notes:

- `build.sh` doesn't use `sudo`; it runs `rm -rf` and `cp` on `/Applications/LGController.app` directly, so your user account must be able to write to `/Applications` (usually an administrator account).
- The app is always installed to `/Applications` on purpose. The project folder may live in iCloud Drive, and running the app from there breaks the Accessibility permission: the switch in System Settings shows as on but has no effect.

**Updating:** in the repository folder, pull the new source:

```bash
git pull
```

Rebuild (it quits the running app for you):

```bash
./build.sh
```

Then start it again:

```bash
open /Applications/LGController.app
```

**Signing and the Accessibility permission**

By default the app is signed ad-hoc; `build.sh` prints 「ad-hoc（重建后需重新授权辅助功能）」 (ad-hoc, re-grant Accessibility after each rebuild). Accessibility permission is tied to the signature, and an ad-hoc signature changes with every build, so **after each rebuild** the media keys stop working until you grant permission again: remove the old entry from the Accessibility list and add it again, or run:

```bash
tccutil reset Accessibility com.toyzcool.LGController
```

Then grant the permission again as in [section 3](#3-first-launch).

**Optional: a self-signed certificate so rebuilds keep the Accessibility permission**

In the repository folder, run once:

```bash
./setup-codesign-identity.sh
```

This creates a self-signed code-signing certificate named 「LGController Self-Signed」 (valid for 3650 days) in your login keychain; if it already exists, the script says so and exits, so running it again is harmless. The key is imported so that any app can use it (`-A`), which is why `codesign` doesn't prompt you. `build.sh` then uses it automatically and prints 「自签名证书「LGController Self-Signed」（重建后无需重新授权）」 (self-signed certificate, no re-grant needed after rebuilds).

Then, one time only, clear the old ad-hoc permission:

```bash
tccutil reset Accessibility com.toyzcool.LGController
```

Rebuild and install with the new certificate:

```bash
./build.sh
```

Start the app:

```bash
open /Applications/LGController.app
```

Finally, open System Settings → Privacy & Security → Accessibility and turn on LGController. Later rebuilds keep the permission.

### 3. First launch

**Grant Accessibility permission (for the media keys)**

1. Start the app: `open /Applications/LGController.app`. A sun icon appears in the menu bar. There is no Dock icon.
2. macOS asks whether LGController may control your computer using accessibility features. Choose to open System Settings.
3. In System Settings → Privacy & Security → Accessibility, turn on **LGController**. If it isn't listed, click **+** and choose `/Applications/LGController.app`.
4. You don't need to restart the app. While permission is missing, it checks again every 3 s and takes over the keys as soon as permission is granted.
5. To check, put the pointer on your LG and press Brightness Up (F2). A HUD should appear in the top-right corner of that screen.

If you dismissed the prompt, open the popover and click the orange 「启用键盘快捷键需授予辅助功能权限…」 (Keyboard shortcuts require Accessibility permission…) warning. It asks again and opens the right settings pane. The popover checks the permission each time it opens, and the warning disappears once it's granted.

Without the permission, everything else still works: all popover sliders and tiles, output switching, and the input-source tiles and ⌘⇧1–4. Despite what the warning says, the ⌘⇧1–4 shortcuts don't need this permission. Only the brightness, volume and mute keys do (without it, macOS handles those keys as usual).

**Launch at login**

- On a fresh install, launch at login is turned on automatically at first launch. It isn't turned on if an earlier LGController already saved brightness values on this Mac (`brightness-*` entries in its preferences); that counts as an upgrade.
- After first launch the app never changes this setting on its own. You change it with the 「开机自启动」 (Launch at login) switch, with `--login-item on|off`, or in System Settings → General → Login Items.
- If macOS requires approval, turn on LGController in System Settings → General → Login Items.
- You can also check it from Terminal (it must be run from the executable inside the app bundle; replace `status` with `on` or `off` to turn it on or off, see [section 7](#7-command-line-options)):

  ```bash
  /Applications/LGController.app/Contents/MacOS/LGController --login-item status
  ```

### 4. Keyboard reference

| Key | Action | Notes |
|---|---|---|
| Brightness Up (F2) | Brightness of the display under the pointer +1/16 | Passed to macOS if that display can't be controlled |
| Brightness Down (F1) | Brightness of the display under the pointer −1/16 | Same |
| ⌥⇧ + Brightness Up / Down | Brightness ±1/64 | Fine step |
| Volume Up (F12) | Current output +1/16 (CoreAudio) or +1 unit (monitor speakers, DDC; full scale 100 on LG) | Unmutes: CoreAudio steps up from the pre-mute level; DDC goes from 0 to 1 unit |
| Volume Down (F11) | Current output −1/16, or −1 unit | Reaching 0 mutes. CoreAudio also unmutes and steps down from the pre-mute level; DDC stays muted |
| ⌥⇧ + Volume Up / Down | Volume ±1/64 | CoreAudio only; monitor speakers still move 1 unit |
| Mute (F10) | Toggle mute of the current output | Only the first press counts; key repeats are ignored. Unmuting restores the pre-mute level |
| ⇧ + any of the keys above | Same as without ⇧ | |
| ⌥ + brightness / volume key (without ⇧) | Passed to macOS | Opens Displays / Sound settings, as usual |
| ⌘ or ⌃ + any media key | Passed to macOS | |
| ⌘⇧1 | Switch LG input to Type C | No Accessibility needed; number row, not keypad |
| ⌘⇧2 | Switch LG input to DP | |
| ⌘⇧3 | Switch LG input to HDMI1 | Same as the macOS screenshot shortcut, see [section 9](#9-troubleshooting) |
| ⌘⇧4 | Switch LG input to HDMI2 | Same as the macOS screenshot shortcut, see [section 9](#9-troubleshooting) |

- The brightness, volume and mute keys need Accessibility permission. They go to macOS while the displays are asleep and for about 1.5 s after wake or a display change. ⌘⇧1–4 are never paused.
- When volume can't be adjusted, the volume and mute keys are still captured and the HUD shows a crossed-out speaker in a circle.

### 5. Using the popover

Click the sun icon in the menu bar; each time the popover opens it refreshes the monitors' values and the device list. Changes made in the popover take effect immediately, show no HUD and play no feedback sound.

**Brightness**

- Drag the slider in a display's card. The display fades to the new value.
- If a card shows 「亮度不可控」 (Brightness not controllable), the app has no working channel to that display. See [Troubleshooting](#9-troubleshooting).

**Volume**

- The 「音量」 (Volume) card always controls the device named in its header, which is the current output.
- Drag the slider to set the volume, or click the speaker icon to toggle mute. Dragging to 0 mutes.
- 「 · DDC」 after the name means the volume goes to a monitor's speakers.
- With only one monitor with DDC volume, its speakers can be adjusted here only while it is the current output. With two or more, the monitors the Volume card isn't controlling get their own speaker slider in their display card, with a speaker icon for mute, like the Volume card.

**Output tiles**

- Click a tile to send sound to that device. The highlighted tile is the current output.
- After you switch, the header and the slider follow the new output.
- The "Play sound effects through" device in System Settings → Sound isn't changed.

**Input tiles**

- Click Type C, DP, HDMI1 or HDMI2 to switch the monitor named in the card header. This does the same as ⌘⇧1–4.
- The monitor named is normally the DDC external monitor whose screen you opened the popover on, otherwise the first DDC external monitor. When the header shows 「未识别外接屏」 (No external display recognized), the command is sent blind to all external endpoints.
- If you click right after opening the popover, the command may wait briefly: the app waits until the monitor's DDC link has been quiet for at least 250 ms, so the popover's own read-backs finish first.

**Launch at login:** flip the switch.

**Quit:** click 「退出 LGController」 (Quit LGController).

### 6. Switching the monitor's input — what to expect and how to get back

**Switching away**

1. **Pick the target.** If there's only one external DDC monitor, the pointer position doesn't matter. Otherwise, before pressing a shortcut, put the pointer on the monitor you want to switch (the target is the DDC external monitor under the pointer, otherwise the first one in the list). With the popover tiles, the target is the monitor the popover is on (if it's a DDC external monitor), otherwise the first one; the name in the 「输入源」 (Input source) card header is what counts. With two LGs, use the shortcut to switch the one the popover isn't on.
2. **Send.** Press ⌘⇧1–4, or click a tile in the 「输入源」 (Input source) card. The app first waits until the monitor's DDC link has been quiet for at least 250 ms, so there may be a short delay.
3. **Watch the feedback** (on the screen under the pointer, or on the main display if no displays are recognized):
   - 「已发送切换 → <input>」 (Switch sent → <input>): the monitor acknowledged the command at the I²C level. This **doesn't mean it switched**; the monitor's screen shows whether it did.
   - Alert sound + 「<input> 未送达显示器」 (<input> not delivered to display): for a directed send, the command still wasn't delivered after the automatic retries; for a blind send (the card shows 「未识别外接屏」), there are no retries, and this appears when no endpoint acknowledged.
4. **After switching.** The monitor shows the other device. macOS may then remove the monitor from its display list (and from the popover); from macOS 26 on, it may also tear down the whole display connection, DDC endpoint included.

**Getting back**

- Press the shortcut for the input your Mac is connected to, even though the monitor isn't showing the Mac: ⌘⇧1 for USB-C / Thunderbolt, ⌘⇧2 for DisplayPort, ⌘⇧3 or ⌘⇧4 for HDMI1 or HDMI2. The hotkeys are never paused, so they keep working while the displays are asleep, right after wake and during display changes.
- If the monitor is gone from the Mac's display list and no other DDC monitor is listed, the app sends the command to every external I²C endpoint the Mac still has.
- **With two DDC monitors:** that fallback is used only when *no* DDC monitor is left in the list. If your other monitor is still listed, the command goes to the monitor under the pointer or to that other monitor, and **its** input switches instead, possibly to an input with no signal, so it goes blank. In that case don't use the shortcuts; switch the disappeared monitor back with its own joystick or buttons.
- If you hear the alert sound and see 「<input> 未送达显示器」 (<input> not delivered to display), the command wasn't acknowledged even after the retries. Usually this means the Mac no longer has a DDC connection to the monitor (for example because macOS 26 or later tore it down). Switch back with the monitor's joystick or buttons.
- After switching back, you occasionally have to unplug and re-plug the cable.

**Tips**

- If you press several shortcuts quickly, the last one normally counts: older requests stop retrying and won't flip the input back. Writes already sent aren't undone, so in rare cases an older command can still arrive late (see [Input source switching (LG)](#input-source-switching-lg)); if the screen isn't on the input you picked last, press it again.
- None of the input tiles is ever shown as selected. The app can't read the monitor's current input.

### 7. Command-line options

Run these in Terminal. Each option does its job and exits without starting the menu-bar app. If you pass more than one, only the first found in this order runs: `--login-item`, `--selftest`, `--osdtest`, `--uipreview`.

| Command | What it does | Notes |
|---|---|---|
| `/Applications/LGController.app/Contents/MacOS/LGController --login-item on` | Turns launch at login on | Same setting as the 「开机自启动」 (Launch at login) switch. Must be run from inside the app bundle. Exits 1 if it isn't on afterwards |
| `… --login-item off` | Turns launch at login off | |
| `… --login-item status` | Shows the current state | A missing or unknown argument also means `status` |
| `.build/release/LGController --selftest` | End-to-end self-test | **Writes to real hardware**; quit the app first. Details below |
| `.build/release/LGController --osdtest` | Shows the HUD demo on every screen in turn | Brightness 5/16, volume 50%, then muted, about 2.7 s per screen. Prints 「HUD 演示 → <screen name> [id=N]」 (HUD demo → <screen name>). Changes nothing and doesn't demo the input-source HUD |
| `.build/release/LGController --uipreview` | Renders the popover from sample data | Writes `/tmp/menu_preview_light.png` and `/tmp/menu_preview_dark.png` at 2× and prints 「已渲染 light: …」 (Rendered light: …) or 「渲染失败 (light)」 (Rendering failed) for each (likewise for dark) |

- Run the `.build/release/…` commands from the repository folder after `./build.sh` or `swift build -c release`.

**`--login-item` output:** 「开机自启动：<state>」 (Launch at login: <state>), where the state is one of:

- 已开启 (on)
- 未开启 (off)
- 待批准（系统设置 → 通用 → 登录项 里打开 LGController） (awaiting approval; turn on LGController in System Settings → General → Login Items)
- 找不到 App（须从 /Applications/LGController.app 内运行） (app not found; must be run from inside /Applications/LGController.app)
- 未知 (unknown)

On error it prints 「开机自启动 <action> 失败：<error>」 (Launch at login <action> failed: <error>) and exits with code 1.

**`--selftest`:**

- Checks the step math, display detection and DDC matching, DDC and DisplayServices brightness writes and read-backs, the DDC hardware mute and volume state machine, volume routing, CoreAudio volume reaching 0, the output device list, the input-source command bytes, ⌘⇧1–4 registration and dispatch, and input target selection, then exits.
- Expect visible and audible changes, restored afterwards where possible: each controllable display dims by one step and comes back (a visible flicker), the monitor's speaker volume and mute are exercised, and the current output's volume changes (audible if sound is playing). If the monitor doesn't answer volume reads (for example the LG HDR 4K) and LGController has no saved volume for it, its speakers are left at 1%.
- It never sends an input-switch command.
- Quit the menu-bar app first, so the two processes don't use the monitor's DDC link at the same time.
- It ends with 「=== 自检通过 ✅ ===」 (self-test passed, exit code 0) or 「=== 自检失败 N 项 ❌ ===」 (N checks failed, exit code 1).
- Run from `.build/release`, it keeps its working state in a separate preferences domain named `LGController` (it first copies each display's state over from the app's preferences).

### 8. Migrating from Monitoring / SourceShift

1. Quit Monitoring and/or SourceShift.
2. Remove them from System Settings → General → Login Items. Otherwise the old apps can take the media keys (or ⌘⇧1–4) before LGController does, so the keys may act with Monitoring's behaviour, or an input command may be sent twice (sending the same input twice is harmless).
3. Build and install LGController as described in [section 2](#2-build--install).
4. Grant Accessibility to **LGController** separately, as in [section 3](#3-first-launch). Permission given to Monitoring doesn't carry over. You can remove the old apps' entries from the same list.

What changes:

- LGController has its own bundle ID (`com.toyzcool.LGController`) and preferences. Monitoring's saved brightness and volume aren't imported; LGController reads the current values from the monitor instead (falling back to 50% brightness and 25% volume if the read fails).
- Launch at login is turned on at LGController's first launch, including for former Monitoring users (it only checks its own preferences).
- If you created 「Monitoring Self-Signed」 for Monitoring, `build.sh` reuses it (and prints 「自签名证书「Monitoring Self-Signed」（重建后无需重新授权）」), so you don't need to run `./setup-codesign-identity.sh`.
- The input shortcuts are the same as SourceShift's and send the same bytes with the same timing (for example Type C = `84 03 F4 00 D1 9C` at data address `0x50`). The last fallback when no external endpoint is found (the system's default AVService) is the only path SourceShift used.

### 9. Troubleshooting

**The build fails with `is using Swift tools version 5.7.0 but the installed version is …`**

- Cause: the Command Line Tools on this Mac are too old: Swift is below 5.7 (older than Command Line Tools 14.1). If they're already installed, `xcode-select --install` only says so and doesn't upgrade them.
- Fix: run `xcode-select -p` to see which tools are in use. If it prints `/Library/Developer/CommandLineTools`, delete them and reinstall; macOS installs the newest version for this Mac (you'll be asked for your password):

  ```bash
  sudo rm -rf /Library/Developer/CommandLineTools
  ```

  ```bash
  xcode-select --install
  ```

  Check the result with `swift --version`, then run `./build.sh`. If it prints `/Applications/Xcode.app/…`, update Xcode from the App Store instead. LGController itself needs macOS 13 or later to run.

**Media keys (brightness / volume / mute) do nothing, or macOS handles them instead**

| Symptom | Cause | Fix |
|---|---|---|
| macOS handles all media keys, and the popover shows the orange warning | Accessibility permission is missing | Click 「启用键盘快捷键需授予辅助功能权限…」 and grant it as in [section 3](#3-first-launch) |
| The Accessibility switch is on, but macOS still handles the media keys | The app was rebuilt with ad-hoc signing, so the permission no longer applies; or the app was run from the project folder in iCloud Drive instead of `/Applications` | Remove LGController from the Accessibility list and add it again, or run `tccutil reset Accessibility com.toyzcool.LGController`, relaunch `/Applications/LGController.app` and grant again. To stop this happening on every rebuild, set up the self-signed certificate ([section 2](#2-build--install)) |
| macOS handles the keys while the displays are asleep, or for a moment right after wake or plugging in a display | Key handling is paused while the displays are asleep, and for about 1.5 s after wake or a display change, until the app has reconnected to the monitors | Wait a moment and press again |
| Only one display's brightness keys don't work, and its card shows 「亮度不可控」 (Brightness not controllable) | The app matched no DDC channel for that display (for example on a Mac without Apple Silicon), or DisplayServices isn't available, so the brightness keys went to macOS | Make sure it's an Apple Silicon Mac; after plugging in or waking, wait for the rebuild to finish and try again; or move the pointer to a display that can be controlled |
| The app doesn't respond when a modifier is held | ⌘, ⌃ or ⌥ on its own is held; those combinations go to macOS unchanged | Use no modifier, ⇧, or ⌥⇧ |
| The volume HUD shows a crossed-out speaker in a circle | The current output's volume can't be adjusted | See the next entry, "The Volume card says …" |
| The keys behave differently from LGController (different steps or HUD), or LGController seems not to respond | An app you used before LGController (see [section 8](#8-migrating-from-monitoring--sourceshift)) or another media-key tool (such as MonitorControl) is still running and takes the keys first | Quit it and remove its login item, see [section 8](#8-migrating-from-monitoring--sourceshift) |

**The Volume card says 「该输出设备不支持调节音量」 or 「请在上方显示器卡片中调节扬声器音量」**

- 「该输出设备不支持调节音量」 (This output device doesn't support volume adjustment)
  - *Cause:* the current output has no volume CoreAudio can set, and it doesn't match a DDC monitor. Examples: a multi-output device, a USB audio interface without hardware volume, or monitor audio from a monitor (or Mac) without a DDC channel.
  - *Fix:* set the volume on the device itself, or pick another output tile.
- 「请在上方显示器卡片中调节扬声器音量」 (Adjust the speaker volume in the display cards above)
  - *Cause:* sound is going to monitor audio shared by two monitors with the same name, and the app won't guess which one.
  - *Fix:* use the speaker slider in the right display card. The volume keys control the DDC monitor under the pointer; with the pointer on the built-in or an Apple display they show the can't-adjust HUD.

**Input switch shows 「已发送切换 → …」 but nothing changes**

- *Cause:* the HUD only confirms that the monitor acknowledged the command at the I²C level, not that it acted on it. Common reasons:
  - LG enables this command per model and firmware. On an LG HDR 4K with EDID `GSM 0x7707`, for example, the command is acknowledged every time and brightness works on the same connection, but the input doesn't change.
  - `0xF4` is LG's private code and has only been verified on LG monitors; other brands usually don't support it.
  - The command went to a different monitor.
- *Fix:*
  - The model or firmware doesn't enable the command, or it isn't an LG: you can't enable it from the Mac; use the monitor's joystick or buttons.
  - It went to a different monitor: check the monitor named in the 「输入源」 (Input source) card header, or the `路线=` (route) part of the log line (below). Put the pointer on the right monitor before pressing the shortcut (see [section 6](#6-switching-the-monitors-input--what-to-expect-and-how-to-get-back)).

**Brightness or volume is out of sync after using the monitor's own buttons**

- *Cause:* the app doesn't poll the monitor in the background. It reads all DDC values only when the display list is rebuilt (launch, wake, display change) and when you open the popover, and the popover skips values the app changed in the last 5 s. Switching output re-reads only the volume and mute of the monitor that becomes the output. Some monitors also don't answer reads reliably; on an LG HDR 4K, for example, reading `0x62` volume and `0x8D` mute gets only an empty reply. In that case the app keeps using its saved value.
- *Fix:*
  - If you just adjusted it with LGController, wait 5 s, then open the popover once (click the menu-bar icon); the values update after a moment, any value that differs by more than 2% is adopted, and later key presses step from the real value.
  - If it's still wrong after opening the popover, the monitor isn't answering reads, and the log shows `回读(弹窗) 音量 … → 失败` (read-back (popover) volume … → failed). Drag the popover slider once (for brightness, the slider in the display card; for volume, the Volume card while that monitor is the current output, or with several DDC monitors the speaker slider in its display card): that sets the monitor to the slider's value and brings the two back in line.
  - Built-in and Apple displays are re-read automatically before every brightness key press, so this normally doesn't happen with them.

**⌘⇧3 / ⌘⇧4 take screenshots, or screenshots stopped working**

- *Cause:* ⌘⇧3 and ⌘⇧4 are also the macOS screenshot shortcuts, and either one can take them over. The app's shortcuts are fixed in the code and can't be changed. If a shortcut couldn't be registered, the app doesn't tell you (it's only written to the system log).
- *Fix:* in System Settings → Keyboard → Keyboard Shortcuts… → Screenshots, give the screenshot commands other keys or turn them off. The popover's HDMI1 / HDMI2 tiles always work.

**The monitor disappeared from the Mac after switching it away, and ⌘⇧n doesn't bring it back**

- *Cause:* from macOS 26 on, macOS may tear down the whole display connection when the monitor switches to another input, and the DDC connection disappears with it. Nothing can be sent to the monitor from the Mac any more; you'll hear the alert sound and see 「<input> 未送达显示器」 (<input> not delivered to display). With two DDC monitors, the command may also have gone to the other monitor (see [section 6](#6-switching-the-monitors-input--what-to-expect-and-how-to-get-back)).
- *Fix:* switch back to the Mac's input with the monitor's joystick or buttons. If the picture doesn't come back, unplug and re-plug the cable.

**Where is the diagnostic log and what should I look for?**

- The log is at `~/Library/Logs/LGController/diag.log`; the previous file is `diag.log.1`. Watch it live with:

  ```bash
  tail -f ~/Library/Logs/LGController/diag.log
  ```

- Each line is `HH:mm:ss.SSS [thread/queue] message`. It has a time but no date, so note the time when you reproduce a problem.
- It records input-source commands and DDC reads only. The 60 Hz brightness writes aren't logged; hotkey registration failures, media-key monitoring start-up and display reconfiguration go only to the system log (NSLog), not to this file.

| Message | Meaning |
|---|---|
| `输入源 请求 <input>（0x..） 路线=DDC屏「<name>」` | Request received; the command will go to monitor `<name>` |
| `… 路线=兜底` | No DDC external monitor in the list; using the fallback (all external endpoints) |
| `输入源 入队 → <name> code=0x..` | The command was queued on that monitor's DDC queue |
| `输入源 开始写 <name>（队列等待 …ms，总线已静默 …ms）` | Write started, with the queue wait and how long the link had been quiet |
| `IOReturn=[…] delivered=true` / `false` | Return value of each write pass; `0x00000000` for the first pass means the monitor acknowledged. Retries and the fallback show up as `输入源 重新匹配端点 IOReturn=[…]` and `输入源 兜底 端点N IOReturn=[…]` |
| `输入源 完成 <input>：已送达（I²C 确认）→ 显示 OSD` | Acknowledged; the "Switch sent" HUD was shown |
| `输入源 完成 <input>：未送达 → 提示音` | A directed send wasn't acknowledged after all retries, or no endpoint acknowledged a blind send; alert sound played |
| `输入源 <input> 已被更新的请求取代，不再重试` | Superseded by a newer request; no more retries |
| `输入源 重新匹配：找不到能确认属于该屏的端点，放弃` | No endpoint could be confirmed as this monitor's; gave up rather than write to another monitor |
| `输入源 兜底：External 端点 N 个` | Number of fallback targets: all external DDC endpoints; if there are none, the system's default AVService is used and this shows 1. 0 means there was nothing to send to (the connection was torn down) |
| `回读(启动校准) 亮度 → …/… 音量 → …/… 静音 → …` | Values read at launch and after every display-list rebuild (wake, display change); 「失败」 (failed) means the monitor didn't answer and saved values are used |
| `回读(弹窗) …` | Read when the popover opens; the volume/mute lines also appear after an output switch |

### 10. Known limitations

- **Apple Silicon only for DDC.** On other Macs there is no LG brightness, LG speaker volume or input switching; `build.sh` builds only for the Mac's own architecture.
- **Input switching:**
  - It uses LG's private register `0xF4`, which can only be written, not read. The monitor's screen is the only confirmation, and the tiles can't show the current input.
  - It has only been verified on LG monitors (the code notes the LG 27UP / UltraFine series), and LG enables it per model and firmware; the LG HDR 4K with EDID `GSM 0x7707` acknowledges the command but doesn't switch.
  - From macOS 26 on, macOS may drop a monitor entirely once it has switched away, so it can't be switched back from the Mac. Occasionally the cable has to be re-plugged. This is macOS behavior.
- **Fixed shortcuts.** ⌘⇧1–4 can't be changed, and ⌘⇧3 / ⌘⇧4 are the same as the macOS screenshot shortcuts. A registration failure isn't shown in the app.
- **Unreliable reads.** Some monitors don't answer DDC reads reliably (the LG HDR 4K doesn't answer volume or mute reads). The app then relies on its saved values, and changes made with the monitor's own buttons aren't picked up.
- **No background polling.** All DDC values are read only when the display list is rebuilt (launch, wake, display change) and when the popover opens; an output change re-reads only the new output monitor's volume and mute. On popover and output re-reads, differences within 2% are ignored.
- **Identical monitors.** Two monitors with the same name can't be told apart from the audio device name. The Volume card sends you to the display cards, and the keys use the DDC monitor under the pointer.
- **Fine step.** ⌥⇧ has no effect on monitor-speaker (DDC) volume.
- **Sound effects device.** Switching output doesn't change the "Play sound effects through" device.
- **Chinese interface only.**
- **No prebuilt app.** You must build from source with the Command Line Tools. With the default ad-hoc signing, every rebuild resets the Accessibility permission unless you set up the self-signed certificate.
- **Feedback sound.** It depends on the system's `volume.aiff` file; if macOS doesn't have that file, no sound plays.

### 11. Uninstall

1. **Turn off launch at login while the app is still installed.** The popover's 「开机自启动」 (Launch at login) switch only works while the app is running; the command-line option doesn't need the app to be running, but it must be run before you remove the app. Either switch it off in the popover, or run:

   ```bash
   /Applications/LGController.app/Contents/MacOS/LGController --login-item off
   ```

2. **Quit the app** with 「退出 LGController」 (Quit LGController) at the bottom of the popover.
3. **Move `/Applications/LGController.app` to the Trash** (drag it there in Finder).
4. *Optional:* remove the saved preferences:

   ```bash
   defaults delete com.toyzcool.LGController
   ```

   and the logs:

   ```bash
   rm -rf ~/Library/Logs/LGController
   ```

   If you reinstall later without these preferences, the next launch counts as a first launch and turns launch at login on again.

5. *Optional:* remove the Accessibility entry. Go to System Settings → Privacy & Security → Accessibility, select LGController and click **–**, or run:

   ```bash
   tccutil reset Accessibility com.toyzcool.LGController
   ```

6. *Optional, if you used them:*
   - If you ran `./setup-codesign-identity.sh`: delete the 「LGController Self-Signed」 certificate and its private key from the login keychain in Keychain Access.
   - If you ran `--selftest` from `.build/release`: delete the `LGController` preferences domain it left behind:

     ```bash
     defaults delete LGController
     ```

   - If you ran `--uipreview`: delete `/tmp/menu_preview_light.png` and `/tmp/menu_preview_dark.png`.
   - Delete the `build/` and `.build/` folders in the source folder.

---

## License

LGController is released under the MIT License; see [LICENSE](../LICENSE). Its DDC code is derived from MonitorControl (MIT); the copyright and permission notice are in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
