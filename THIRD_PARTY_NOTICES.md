# Third-party notices / 第三方声明

LGController includes code derived from the project below. Its license requires the copyright and permission notice to be kept with copies of the code.

LGController 包含源自下列项目的代码；按其许可证要求，在此保留原版权声明与许可声明。

## MonitorControl

- Project / 项目：https://github.com/MonitorControl/MonitorControl
- License / 许可证：MIT
- Source file notice / 源文件版权声明：`Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others`
- Used in / 使用位置：
  - `Sources/LGController/DDC.swift` — DDC/CI read and write over IOAVService, and matching AVService endpoints to displays; ported and simplified from MonitorControl's `Arm64DDC.swift`.
    DDC/CI 读写（IOAVService I²C）与 AVService 端点↔显示器匹配，移植并精简自 MonitorControl 的 `Arm64DDC.swift`。
  - `Sources/LGController/DDC.swift`（`IntelI2C`）— on Intel Macs, DDC/CI over the IOFramebuffer I²C bus and matching framebuffers to displays; ported and simplified from MonitorControl's `IntelDDC.swift`, which MonitorControl notes is adapted from @reitermarkus's IntelDDC.swift.
    Intel Mac 上经 IOFramebuffer I²C 总线的 DDC/CI 收发，以及帧缓冲↔显示器匹配，移植并精简自 MonitorControl 的 `IntelDDC.swift`（MonitorControl 注明其改编自 @reitermarkus 的 IntelDDC.swift）。
  - `Sources/LGController/PrivateAPI.swift` — declarations of the private IOAVService and CGSServiceForDisplayNumber functions used by that code.
    上述代码用到的 IOAVService、CGSServiceForDisplayNumber 私有函数声明。
  - `Sources/LGController/DisplayManager.swift` — detecting Apple-protocol displays through DisplayServices follows MonitorControl's approach.
    通过 DisplayServices 判定苹果协议显示器的规则，沿用 MonitorControl 的做法。

License text (verbatim from MonitorControl's `License.txt`) / 许可证原文：

```
MIT License

Copyright © 2017

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
