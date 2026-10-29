# 讲义生成 App · 交接文档

> 最后更新：2026-10-29 ｜ 当前版本 **v0.30** ｜ 状态：**已发布（GitHub Release v0.30）**
>
> 📌 **接手先看**：§5.8（浏览器隐形）、§5.9（v0.14 结构）、§5.10（登录检测 / 诊断包）、
> §5.11（v0.16 的光标 / 状态框 / Finder）、§5.12（v0.17 新功能）、§5.13（v0.19–v0.20）、§5.14（v0.21 GitHub 推送 + CI Release）、§5.15（v0.21 续三处）、§5.16（v0.22 发布三处 + 每次改动必升版必推 tag 规则）、§5.17（v0.23 液态玻璃 + 退出确认按钮改动）、§5.18（v0.24 标题栏隐藏 + 累计改动）、§5.19（v0.25 主页面 hover + 退出登录确认框 + 退出后永不出现倒计时）、§5.20（v0.26 退出按钮 hover 变深 + 内置网页大叉只隐藏 + 模式检测先绿灯后检测）、§5.21（v0.27 重大 bug 修复：退出按钮点不动）、§5.22（2026-10-27 回灌：3 秒判定 / 根地址新对话 / 删诊断 / 删页脚 / 登出按钮）、§5.23（v0.28 提示词重写 + 规则 md 用户自改）**、§5.24（v0.29 补过期项）、§5.25（⌘J 开新对话）、§5.26（v0.30 拖入 + 两框查重）**、§7 待办（已按用户决定结算）。
>
> ⚠️ **重要**：v0.20 之前，v0.19 源码改完后并未实际安装过（/Applications 仍是 v0.17，dist 是 v0.18），
> 所以 v0.20 直接作为基线，不再回头补 v0.19 的安装记录。安装以桌面一键脚本的核对日志为准，见 §2。

---

## 0. 一句话说清这是什么

一个 macOS 本地 App。用户选两个 docx（考卷 + 答案），App 把它们连同两个内置附件上传到 DeepSeek 网页版，让 AI 按既定规则生成一段 **Python 脚本**，App 再用**自带的 Python 运行时**执行这段脚本，产出讲义 docx。

全程不需要用户碰命令行，也不需要装任何东西。

**目标用户**：一位高三英语老师，用来批量把试卷转成备课讲义。

---

## 1. 当前状态

### ✅ 已跑通
- 上传 4 个文件到 DeepSeek（分片 base64 → `DataTransfer` → `input[type=file]`）
- 填提示词 + 发送
- 等 AI 写完，中途自动点「继续生成」（**真实 NSEvent 注入**，见 §5.2）
- 从页面抓取 Python 代码块
- 内置 Python 执行脚本，生成 docx
- **浏览器全程隐形**，只有登录时露一次，登录成功 5 秒后自动收起（v0.14）
- **代码抓全就直接执行**，不再弹预览确认（v0.14）
- **成品常驻卡片**，点「下载 Word 讲义」才弹保存面板（v0.14；v0.20 起产物不再搬到 Application Support，见 §5.13④）
- 实测产出过一份 36KB 的完整讲义，用户评价「很满意」
- v0.20：等待总上限 10 分钟、状态框每 5 秒统一播报、分段开始有提示（见 §5.5 / §5.13③）
- v0.20：页脚 ⋯ 菜单只剩「退出 DeepSeek 账号」，Word 卡只剩紫色渐变下载按钮（见 §5.13④）
- v0.20：新图标 v3——蓝青绿渐变底、无外圈黑边、上下沿统一 m 型、无页内页间横线（见 §5.13①）
- v0.21：GitHub CI 打包发布 Release，curl 一行下载（见 §5.14②）

### ⚠️ 已知不稳定点
- 自动判定「AI 写完了」仍可能偶尔误判（四层判定，见 §5.5；v0.20 已把“稳定就当写完”收紧，见 §5.13③）
- AI 是否遵守 `# ===LECTURE-END===` 标记，无 100% 保证
- 「继续生成」按钮的识别靠文本匹配，DeepSeek 改文案会失效

### ❌ 还没做（按用户 2026-10-25 决定结算，见 §7）
- 不再新增 UI 打磨：现有界面冻结，未实现的待办已删除
- 内置附件缺失时的降级处理（未实现，按决定删除，不再做）
- 执行失败后「只重跑脚本」不做了：`lastScript` 已在 v0.20 彻底删除，只能重跑整条流程

---

## 2. 构建与调试

### 构建
```bash
cd lecture-app
./build.sh              # 只构建到 dist/讲义生成.app
./build.sh --install    # 构建 + 覆盖安装到 /Applications + 启动
```

无 Xcode 工程，纯 `swiftc` 手工组装 bundle。产物约 77MB（其中 75MB 是 Python 运行时）。

桌面一键脚本（用户实际用的，v0.20 起的固定流程）：
```bash
bash ~/Desktop/讲义生成-重新编译安装.sh
```
顺序：先跑 `tools/make_icon_book.swift` 出 1024 图（预检失败就停，并把图拷到桌面 `讲义生成-新图标-1024.png` 供目视核对；
旧“讲”字图标如无备份先存到工程根 `AppIcon_old_讲.icns`）→ 强制退出旧 App（`pkill -f "MacOS/LectureGen"`，`build.sh --install` 里还会再 pkill 一次）
→ `./build.sh --install` → 安装副本补 `SetFile -a B` + `touch`（见 §5.13①）→ 打印版本/图标/二进制大小/icns 校验 + 跑 `--selftest`，
全部日志写桌面 `讲义生成-编译核对.txt`。**不要在云电脑上编译安装，这是用户 Mac 本地跑的活。**

### 两个命令行自检入口
```bash
# 验证包内资源、Python 路径、体积
"/Applications/讲义生成.app/Contents/MacOS/LectureGen" --selftest

# 完整跑一遍脚本执行链路（不碰网页）
"/Applications/讲义生成.app/Contents/MacOS/LectureGen" --runpython /tmp/test.py
```
`--runpython` 会打印 `exit / work / files / output / docx 字节数`，是排查「Python 跑不通」最快的入口。

### JS 语法校验（改过 `Scripts.swift` 后必做）
```bash
python3 - Sources/Scripts.swift <<'PY'
import re,sys
src=open(sys.argv[1]).read()
blocks=re.findall(r'#"""\r?\n(.*?)\r?\n[ \t]*"""#', src, re.S)
for i,b in enumerate(blocks):
    b=re.sub(r'\\#\([a-zA-Z]*\)','[]',b)
    open(f"/tmp/js_{i}.js","w").write(b)
PY
for f in /tmp/js_*.js; do node --check "$f"; done
```

### 运行时日志
状态栏显示最近 6 行 `progressLines`。失败时自动写诊断日志到 `~/Library/Application Support/讲义生成/日志/`（含页面截图，见 §5.12②）。
**v0.20 已删除「导出 DOM 快照」功能**，不要再让用户点它拿结构，改看自动诊断日志。见 §5.13④。

---

## 3. 目录结构

```
lecture-app/
├── build.sh                    # 构建脚本（编译 → 拷资源 → 拷 Python → 写 plist → 签名；--install 后补 SetFile -a B，见 §5.13①）
├── tools/make_icon_book.swift  # 图标底图生成（v3，见 §5.13①；旧“讲”字图标脚本 tools/make_icon.swift 未动）
├── Sources/
│   ├── LectureApp.swift        # @main + ContentView + ScriptPreviewSheet + OutputSheet
│   ├── AppState.swift          # 全局状态机（ObservableObject），双通道 JS 入口
│   ├── Pipeline.swift          # 主流程：上传 → 发送 → 等待 → 抓取
│   ├── Scripts.swift           # 注入网页的 JS（全部写成单个表达式；v0.20 删了快照用的 2 段）
│   ├── BrowserController.swift # WKWebView + 可挪到屏幕外的窗口 + 真实鼠标注入
│   ├── PythonRunner.swift      # 内置 Python 执行器
│   ├── ScriptExtractor.swift   # 从文本里提取/打分挑出 Python 代码块
│   └── SafariBridge.swift      # AppleScript 通道（备用，见 §5.3）
├── Resources/                  # 内置附件（固化进 App，防止误删）
│   ├── 讲义制作规则.md          # 11K，AI 的作业规则
│   ├── 标准模式讲义.docx        # 66K，版式模板
│   ├── AppIcon.icns
│   └── zh-Hans.lproj/InfoPlist.strings
└── Runtime/python/             # 75MB 的 CPython 3.12 + python-docx
```

代码总量约 2450 行。

---

## 4. 一次点击发生了什么

```
用户点「生成讲义」
  │
  ├─ Pipeline.runPipeline()  ← 后台线程，全程 beginActivity 防 App Nap
  │   │
  │   ├─ 1. 开新对话               根地址就跳过；会话页按 ⌘J；按不动才重载根地址（§5.25）
  │   ├─ 2. Scripts.probeComposer  探针：确认 textarea 和 input[type=file] 在
  │   ├─ 3. 分片灌字节              base64 每片 96000 字符 → window.__wbF
  │   ├─ 4. Scripts.commitFiles    atob → Uint8Array → DataTransfer → input.files
  │   ├─ 5. 轮询文件名             确认 4 个附件都渲染出来了（25 秒超时）
  │   │      └─ .md 被拒 → 改 .txt 重传，并同步替换提示词里的文件名
  │   ├─ 6. Scripts.fillText       native setter + input/change（React 受控组件必须）
  │   ├─ 7. Scripts.sendNow        倒序找发送按钮，退化到 Enter keydown
  │   └─ 8. waitForReply()         轮询直到判定写完（见 §5.5）
  │          └─ 需要时点「继续生成」→ 真实 NSEvent 注入
  │
  ├─ grabScript()  取所有 .md-code-block pre，回传后打分挑最像的一段
  │
  └─ 主线程：offerScript() → 弹脚本预览
       └─ 用户点「执行并生成 docx」
           ├─ PythonRunner.run()  临时目录里跑，猴补丁记录 save 路径
           └─ NSSavePanel 让用户选存哪（v0.20 起：卡片直接指向临时目录原件，下载成功后删临时文件并回未生成；
               下载失败/取消不删，还能再点一次。见 §5.13④）
```

---

## 5. 关键技术决策（改之前务必先读）

### 5.0 提示词铁律：先让它读内容，再给约束；人称一律「用户」（2026-10-29 定，三个 App 通用）

**用户定的最高级别铁律，优先级高于本文件其他所有「优化」建议。改提示词前先读这一节。**

- **顺序**：提示词前面**绝不出现任何能力声明、环境限制、工具限制**。像「图片你直接看得见，
  不需要任何 OCR 库，也不用讨论怎么识别图片」「当前环境只有 Python」这类话，写在前面等于
  「不许用 OCR 却逼你读图」，模型只能怀疑自己到底看没看见 —— 2026-10-29 试卷识别就是这么翻的车
  （AI 在思考流里反复自问「我看不到图片」，然后编了一整份草稿）。
  **正确做法：先让它自行判断、读懂附件内容，约束放到后面；能不提就干脆不提，只写在规则 md 里。**
- **人称**：规则 md 是附件、没有说话人，**一律用「用户」，一个「我」都不许有** ——
  「我的环境只有 Python」会被代入成 AI 自己的限制。提示词只有开场「我发你 N 个文件」用「我」，
  其余一律「用户」（「不要反问用户」「用户判断代码是否输出完整的标记」）。
- **环境写成客观事实**：「用户的环境只有 Python 3.12 和 python-docx」，不要写「当前环境」「我的环境」，
  也不要写成对模型的命令（原来那句「请不要 import pandas、matplotlib、openpyxl 之类」已按这条改掉）。

**判断依据**：用户自己写了几十轮提示词，从没出现过自我怀疑；一改成「先约束、后读内容」就必犯。

### 5.1 用 WKWebView，不用 Safari + AppleScript

最初版本走 Safari 的 `do JavaScript`，需要用户手动打开「允许来自 Apple 事件的 JavaScript」，对小白太难。

现在默认走内置 WKWebView：**不需要任何 TCC 授权**，且实测共享了 Safari 的登录态（cookie 在 App 容器里，`WKWebsiteDataStore.default()`）。

Safari 通道代码保留在 `SafariBridge.swift`，`AppState.engine` 可切换，但已不作为默认。

**静默运行**：`ParkableWindow` 覆盖 `constrainFrameRect`，允许窗口挂到 `NSScreen.main.frame.maxX + 400`（屏幕右侧外）。用户看不见，但 WebKit 仍在渲染和跑 JS。

### 5.2 「继续生成」必须用真实鼠标事件，JS 点击无效

这是整个项目最难的一个坎，**别试图改回 JS 点击**。

现象：元素是 `div[role=button]`、`pointer-events: auto`、坐标正确、只有一个候选、`dispatchEvent` 派发了完整指针序列 —— 但页面毫无反应。

结论：**DeepSeek 在检查 `event.isTrusted`**。`dispatchEvent` / `element.click()` 造出来的事件这个值恒为 `false`。

解法（`BrowserController.clickAtViewportPoint`）：
1. JS 返回按钮在视口里的中心坐标
2. 视口坐标 → NSView 坐标。**注意 `WKWebView.isFlipped == true`**，所以 `localY = y`，不要翻转
3. `webView.convert(local, to: nil)` 得窗口坐标（这里 convert 会自动处理翻转）
4. 构造 `leftMouseDown` / `leftMouseUp`，`window.sendEvent()`

**前提**：窗口必须在屏幕内且是 key window，否则 hitTest 找不到视图、事件被丢弃。所以点击前会 `bringOnscreen()` + `makeKeyAndOrderFront`。这会导致**点击瞬间浏览器跳到屏幕中央抢一次焦点**，这是物理限制，不是 bug。

### 5.3 内置 Python 运行时

- 来源：python-build-standalone `cpython-3.12.15+20261021-aarch64-apple-darwin-install_only`
- 依赖：`pip install --target ./lib/python3.12/site-packages python-docx`
  **不能用 venv**，绝对路径不可重定位
- 裁剪掉 pip / ensurepip / idlelib / pydoc_data / lib2to3 / tkinter / turtle.py /
  config-3.12-darwin / include / share / `__pycache__` → 92MB 降到 75MB
- 实测 `cp` 换路径后 `import docx, lxml.etree` 正常，`sys.prefix` 跟着变
- 二进制是 adhoc linker-signed，`codesign --force --sign -` 对整个 app 签名不破坏它

### 5.4 脚本执行怎么知道生成了什么

三个文件放在临时工作目录：
- `生成讲义.py` —— 用户脚本，**原样写入，不做任何注入**
- `_wb_prelude.py` —— 猴补丁
- `_wb_launch.py` —— `runpy.run_path(script, run_name="__main__")`

**为什么不往用户脚本里注入**：会破坏 `# -*- coding -*-` 必须在第 1/2 行的约定。

**怎么精确知道产物**：prelude 里猴补丁 `docx.document.Document.save`，每次保存把 abspath 追加到 `$WB_MANIFEST`；再加 `atexit` 扫描 cwd 兜底；最后按 `mtime >= startedAt - 2s` 过滤。

**防死锁**：stdout/stderr 都重定向到**文件**（不是 Pipe），执行完再读。

### 5.5 「AI 写完了」的四层判定

按优先级：

| 层 | 条件 | 位置 |
|---|---|---|
| 0 | `generating`（有「停止生成」按钮）→ 继续等 | `waitForReply` |
| 1 | `hasContinue`（有「继续生成」）→ 真实鼠标点它，**轮询 12 秒验证** | 同上 |
| 2 | **`hasEndMark` 连续 2 轮** → 判定写完（v0.20 起移到循环顶部，**无论 `generating` 都做**，5 秒一轮约 10 秒） | 同上 |
| 3 | `looksComplete && afterLines >= 3` | 同上 |
| 4 | `textLen` + `codeLen` 双双稳定 **12 轮（60 秒，5 秒一轮）且必须有 `looksComplete`**，否则继续等到总上限，**绝不执行截断脚本** | 同上 |

**v0.20 总规则**：等待总上限 **10 分钟**，10 分钟一到直接判失败（不再顺延；用户说这个规模 10 分钟最多）。
状态框播报统一为每 5 秒一句：`AI 正在思考…，代码目前 X 字，正在等它继续输出`，持续不断，字数涨没涨一看就知道。
分段提示：点「继续」成功后报 `第 X 段开始生成`（第 1 段是原生的，第 1 次点就是第 2 段开始），点完后 5 秒播报重新开始。
自动点「继续」的机制、12 秒验证、5 次点击上限在 v0.20 没动（一般最多 3 段、点两次，5 次只是兜底）。

**第 2 层是契约**：提示词里要求 AI 在代码最后一行写 `# ===LECTURE-END===`。
这是「让生产者声明」而不是「让消费者猜」，最可靠。抓取时会把这行剥掉。

**第 3 层是语义兜底**：`looksComplete` = 末尾有 `.save(...)`（括号必须闭合，
否则 `b.save(OUT_NA` 这种写了一半的也算）或者 `if __name__ == "__main__": main()`。
`afterLines >= 3` 的依据：AI 不可能在代码块没闭合时跳到下面写说明，
**代码块后出现 3 行以上说明 = 代码块一定闭合了**，这是结构性证据。

### 5.6 点击后必须验证，且要等够久

点完「继续」不能当成功。要重新读 `document.body.textContent.length`：
涨了才算生效，没涨记一次无效，**连续 2 次无效就抛错停下**（不再空转）。

**等待时间必须 ≥ 12 秒**。DeepSeek 点完「继续」要先「想」一会儿才出字，早期版本只等 3 秒，
把有效点击记成无效，两次就抛错退出 —— 这是「只点一次就停」的根因。

### 5.7 页面被判 hidden 时 DOM 会不会停止刷新？

**会节流，但 `textContent` 不受影响。**（2026-10-25 凌晨实测推翻旧结论，见 §5.8）

窗口挪到屏幕外时 `document.visibilityState` 变成 `hidden`，页面自己的 `setInterval`
被节流（200ms 的定时器实测 4 秒只跑 5 次）。**但 `textContent` 照常增长**，
外部 `evaluateJavaScript` 也照常返回正确结果。

早期版本曾因此误判「写完了」，真正的原因是当时用了 `innerText` —— 它依赖布局重排，
隐藏时失真。**必须用 `textContent`。**

> ⚠️ 旧文档写过「检测到 `vis == "hidden"` 就自动 `bringOnscreen()`」。
> 实测证明那是白弹的，**应该删掉**（见 §7 第 1 条）。

### 5.8 内置浏览器可以完全隐形（2026-10-25 实测，6 组实验）

用户要求：**除了登录，浏览器窗口任何时刻都不出现。**

**结论：用 `alphaValue = 0` + `ignoresMouseEvents = true`，不要用「挪到屏幕外」。**

| 方案 | 页面 vis | 定时器 | 外部读 DOM | 注入点击 | 用户可见 |
|---|---|---|---|---|---|
| 挪到屏幕外 | `hidden` | 被节流 | ✅ 正常 | ✅ | ❌ 但会漏到副屏 |
| **alpha=0** | `visible` | **满速** | ✅ | ✅ | ❌ 完全不可见 |
| alpha=0 + 穿透 | `visible` | 满速 | ✅ | ✅ | ❌ 完全不可见且点击穿透 |

`alpha=0` 时页面**仍然认为自己是 visible**，一丁点都不节流，是三者中最优的。

**⚠️ 不要试图省掉 `makeKeyAndOrderFront`。** 又试了三种「不抢焦点」的变体
（`orderBack`、`level=.floating`、覆写 `acceptsFirstMouse → true`），
结果都不可靠：点击要么延迟 2 秒，要么 3 次只中 1 次。**非 key 窗口注入事件不稳。**

而且这个担心本身多余 —— 自动化跑的时候用户正看着主窗口，app 本来就是前台，
`makeKey` 只是在自家两个窗口之间切换，不会把焦点抢到别的 app。

实验源码留在 `/tmp/vis_test/`（`main.swift` / `alpha.swift` / `passthru.swift` /
`keyless.swift` / `floating.swift` / `firstmouse.swift`），重启后可能被清掉，结论已记在此处。

### 5.9 v0.14 的新结构（界面 / 进度 / 成品）

**① 浏览器只有登录时会露出来。**
`BrowserController` 只剩两个对外方法：
- `hideCompletely()` —— `alphaValue = 0` + `ignoresMouseEvents = true` + `orderFrontRegardless()`
- `showForUser()` —— 恢复 alpha、取消穿透、居中、激活

`loadDeepSeek()` 末尾直接 `hideCompletely()`。`parkOffscreen` / `bringOnscreen` / `isOnscreen`
已删除，别再写回来。

**② 登录倒计时是 Swift 侧驱动的，不是页面里的定时器。**
`openDeepSeek()` → `showForUser()` + 注入提示条 → `refreshLogin()` 每 2 秒探一次 →
`reactToLoginState()` 发现 `loggedIn` 就 `startLoginCountdown()`（5 秒，无取消入口）→
`finishLogin()` 收起窗口并清掉提示条。
提示条由 `Scripts.loginBadge(text:)` 注入到页面顶部，每次调用幂等更新，SPA 重渲染删掉了会自动补回。

**③ 进度改成人话，技术日志不再上界面。**
`AppState.progress: ProgressInfo{title, detail, fraction, running, tone}`。
Pipeline 里所有 `statusLine = "..."` 都换成了 `say(...)`；原来的 `log(...)` 只写进
`progressLines` 内存数组，界面上看不到。
`fraction = 0` 表示进度未知（界面跑一条来回扫的光带），`0~1` 才是确定进度。

**④ 代码全了就直接跑，不再弹预览。**
`offerScript()` 里已经没有 `skipPreview` 分支，直接 `runScript(code)`。
`ScriptPreviewSheet` 整个删掉了。

**⑤ 成品走「常驻卡片」而不是自动弹保存框。**
`docx: DocxState` = `.idle / .building / .ready(URL) / .failed(String)`。
（v0.14 的做法：脚本跑完先把产物从临时目录复制到 `~/Library/Application Support/讲义生成/成品/`，
用户点「下载 Word 讲义」才弹 `NSSavePanel`。**v0.20 已改掉这一句**：不再搬到 Application Support，
卡片直接指向临时目录原件，下载成功后删临时文件并回未生成，下载失败/取消不删。见 §5.13④。）
失败时**不自动弹技术面板**，卡片上给一个「查看详情」按钮，避免吓到老师。

**⑥ 两个上传框整块可点。**
`ZStack { Button{选文件}{卡片} ; Button{X}{移除} }` —— 叉在 ZStack 上层，
所以不会被下面那个大按钮吃掉点击。

**⑦ 选文件的目录会记住。**
`UserDefaults` 三个键：`pickDir.exam` / `pickDir.answer` / `pickDir.shared`。
打开面板时按「本框 → 另一个框 → 共享 → 下载目录」的顺序找，所以选完考卷再选答案会落在同一目录。

**⑧ 激活元素的边框是旋转渐变。**
`RotatingGradientBorder` 用 `TimelineView(.animation(minimumInterval: 1/30, paused:))`
逐帧算角度。**不能用 `withAnimation` 推 `AngularGradient.angle`，它不是可动画属性。**

**⑨ 开发用演示开关。**
`--uidemo`（已选文件 + 生成中）/ `--uidemo2`（已选文件 + 已出成品）/
`--uidemo3`（失败态）启动时把界面填成对应状态，只为截图检查视觉，不碰网络。
见 `AppState.applyUIDemo(step:)`。

### 5.10 v0.15：登录检测的三个坑 + 失败诊断包

**① 启动瞬间不能判「未登录」。**
页面刚打开时 DOM 是空的：既没有 `textarea`，也没有 `input[type=password]`。
早期 `probeLogin` 在这种情况下直接返回 `.loggedOut`，于是 App 一启动就闪出
「登录 DeepSeek」按钮 —— 明明已经登录了。
现在 `Scripts.loginProbe` 多返回两个字段：

- `bodyLen` —— `document.body.textContent.length`，判断页面渲染了没有
- `hasLoginButton` —— 页面上有没有文案为「登录 / 立即登录 / Log in」的按钮

判定顺序改成：
```
有输入框 且 无密码框      → loggedIn
有密码框 或 有登录按钮    → loggedOut
上面都不满足 且 bodyLen<80 → noPage   （还没渲染完，继续等）
其余                      → unknown   （有内容但认不出，继续等）
```

**② `loginSettled` 控制按钮什么时候出现。**
`AppState.loginSettled` 初始 `false`，只有探针返回「问清楚了」的状态才置 `true`
（`isDefinite(_:)`）。`false` 期间界面显示「正在检测登录状态…」+ 小转圈，**不显示登录按钮**。
另外 `startPolling()` 里挂了 **20 秒兜底**：页面一直加载不出来也会把按钮放出来，
不然用户没有出口。

**③ 登录流程自检（真的会弹窗口）。**
`--logintest` 启动 → 6 秒后强制 `login = .loggedOut` 并调 `openDeepSeek()` →
真实探针在 2 秒内发现已登录 → 倒计时 → 强制隐藏。每秒打一行：

```
[t= 0s] 倒计时=0  alpha=1.0  窗口在屏=1  点击穿透=0  登录态=loggedOut  提示条=(无提示条)
[t= 1s] 倒计时=0  alpha=1.0  窗口在屏=1  点击穿透=0  登录态=loggedOut  提示条=正在等待登录…  登录成功后本窗口会自动收起
[t= 2s] 倒计时=5  alpha=1.0  窗口在屏=1  点击穿透=0  登录态=loggedIn   提示条=✓ 登录成功，5 秒后自动收起本窗口
[t= 6s] 倒计时=1  alpha=1.0  窗口在屏=1  点击穿透=0  登录态=loggedIn   提示条=✓ 登录成功，1 秒后自动收起本窗口
[t= 7s] 倒计时=0  alpha=0.0  窗口在屏=1  点击穿透=1  登录态=loggedIn   提示条=(无提示条)
```
v0.15 实测全部符合预期。**改登录相关代码后跑这个，比肉眼点快得多。**

**④ 失败诊断包。**
`AppState.exportDiagnostics()` 往桌面写一个
`讲义生成-失败诊断-<时间戳>.txt`，内容是：失败原因、界面最后提示、Python 输出、
**AI 生成的脚本原文**、完整流程记录、页面地址、App 版本、系统版本。
入口有两个：Word 卡片失败时的「导出失败代码」按钮，和详情面板里的「导出诊断文件到桌面」。
老师只需要把这个 txt 发给开发者，不用理解任何报错。

**⑤ 中止现在真的能停。**
`PythonRunner.cancelCurrent()` 掐掉正在跑的 Python 进程（SIGTERM，2 秒后 SIGKILL），
`runPipeline` / `waitFor` / 上传循环里都加了 `checkStop()` 检查点。
早期只有 `waitForReply` 的轮询里检查 `stopRequested`，上传阶段和 Python 执行阶段点中止是没反应的。

### 5.11 v0.16：光标 / 状态框 / Finder

**① 手型光标用 `onContinuousHover` + `NSCursor.set()`。**
`HandCursor`（`LectureApp.swift`）挂在所有可点元素上：两个上传框、右上角的叉、
登录按钮、生成/中止按钮、Word 卡片里的三个按钮、页脚 ⋯ 菜单。
**状态展示区（进度卡、Word 卡本身）不加。**

不用 `push()/pop()`：那对必须严格配对，视图在悬停过程中被移除（上传框选中后整块重绘）
就会漏 `pop`，光标永久卡成手型。`set()` 无栈，退出时再设回箭头即可。

> ⚠️ **怎么验证光标真的变了**：`screencapture -C` 抓出来的**永远是箭头**，
> 别用它判断。正确做法是在 `onContinuousHover` 里打日志对比
> `NSCursor.current == NSCursor.pointingHand`，实测返回 `true`。
> 另外窗口必须是 key 窗口，非活动窗口本来就不会显示手型。

**② 状态框（ProgressCard）空闲时讲「还差哪一步」。**
`AppState.idleStatus` 按「考卷 / 答案 / 登录」组合给文案，配一条进度条：

| 状态 | 标题 | 进度 |
|---|---|---|
| 都没传 | 等待上传文档 | 0 |
| 只传考卷 | 考卷已就绪 | 0.34 |
| 只传答案 | 答案已就绪 | 0.34 |
| 都传了，未登录 | 文档已就绪 | 0.72 |
| 都传了，已登录 | 准备就绪 | 1.0（绿点） |

什么时候用哪套文案由 `showingIdle = !isRunning && progress.tone == .idle` 决定：
- 空闲 / tone == .idle → 用 `idleStatus`
- tone == .ok → 用流程文案（"讲义生成好了 ✓"）
- tone == .error → 用流程文案（失败信息）
- isRunning → 用流程文案

`accept()` / `clearFile()` **不再写状态框文案**。早期那里写的是
"已选择 xxx.docx"，只反映最后一次操作，看起来像另一个文件丢了。
选完新文件如果上次是成功态，会把 `progress` 重置回 `.idle`，状态框回到"还差哪一步"。

**③ Finder 只开一个窗口。**
`AppState.revealInFinder(_:)` 用 `NSWorkspace.selectFile(_:inFileViewerRootedAtPath:)`，
不用 `activateFileViewerSelecting` —— 后者会先激活 Finder 再开窗，Finder 没有已开窗口时
会先弹一个"桌面"窗口，用户看到的就是「保存完讲义，桌面也被打开了」。
另外 `exportSnapshot()` 不再自动 reveal（开发期功能，正常流程里不该多开窗口）。

**④ 新增演示开关**：`--uidemo4` 只传考卷 / `--uidemo5` 只传答案 / `--uidemo6` 都传但未登录。

### 5.12 v0.17–v0.18：登出重登 / 诊断包改版 / 深度思考+智能搜索自动激活

**① 登出后重新登录流程修复。**
`logoutDeepSeek()` 清 `WKWebsiteDataStore` 整站数据（cookie + localStorage + IndexedDB），
不能只删 cookie。清完自动弹出登录窗口，登录成功后正常倒计时收起。

**② 诊断包改成 Markdown + 截图。**
- 自动日志：`saveDiagnosticLog()` 在 `docx.didSet` 检测到 `.failed` 时触发，
  静默写到 `~/Library/Application Support/讲义生成/日志/失败-<stamp>.md`，
  附带 `页面截图.png`（`WKWebView.takeSnapshot`），只留最近 30 份。
- 手动导出：`exportDiagnostics()` 在桌面生成文件夹 `讲义生成-失败诊断-<stamp>/`，
  内含 `诊断报告.md` + `页面截图.png`。

**③ 生成后清空上传框防重复。**
`submitAndClearUploads()` 在 `runPipeline` 里提交后立即执行，
失败/中止时 `restoreHeldFiles()` 自动放回，成功则保持清空。

**④ 深度思考 + 智能搜索自动激活（v0.18 已补强，待真实页面验收）。**
用户要求：登录成功后自动检测并激活 DeepSeek 输入区下方的「深度思考」和「智能搜索」按钮，
这两个状态在对话间会传递，只要开一次就行。

实现位置：
- `Scripts.probeComposer` 增加 `deepThink` / `smartSearch` / `deepThinkRect` / `smartSearchRect`
- `AppState.ensureDeepSeekModes()`：登录成功后调用，探测 → 点击未激活的按钮 → 更新 `@Published` 状态
- `AppState.idleStatus`：已登录态的标题显示「准备就绪（深度思考、智能搜索 已激活）」

**v0.18 修复内容**：
- `refreshLogin()` 对任意已登录态触发检查；只有两项都经复检为开启，才把 `modesChecked` 置为真。
- JS 改为优先读取 `aria` / `data-*` / class 状态，颜色只作兜底，并返回是否找到开关。
- JSON 坐标按 `[String: Any]` / `NSNumber` 解析；旧的 `[String: Double]` 转型会导致找得到按钮却拿不到坐标。
- 真实 `NSEvent` 点击被切回主线程，随后等待 0.9 秒并重新探测；未渲染、未找到或点击未生效都会在下一次 2 秒登录探针时重试。

**仍需验收**：用已登录账号启动 App，确认状态卡显示“深度思考、智能搜索 已激活”，并在首次未开启时确认页面两项开关实际被打开。可用 `log stream --predicate 'process == "LectureGen"'` 查看 `[DEBUG]` 记录。

### 5.13 v0.19–v0.20：图标/安装、待办结算、截断误判修复、菜单与 Word 卡精简

**① 图标与安装（v0.19 源码改完未装，v0.20 直接当基线）。**
- 早期问题：图标文件本身没丢（`Resources/AppIcon.icns` 与各处副本 MD5 一致、结构完整），只是 `build.sh` 只对 dist 包做了 `SetFile -a B`，
  `cp -R` 到 /Applications 后 Finder bundle 标志可能丢失，Finder 里显示通用图标、Dock 里正常。解法：`build.sh --install` 后对安装副本再做一次 `SetFile -a B` + `touch`。
- 安装必须强制退出旧 App：桌面脚本先 `pkill -f "MacOS/LectureGen"`，`build.sh --install` 里还会再 pkill 一次。
- 图标演进（`tools/make_icon_book.swift`，旧“讲”字图标脚本未动，旧图标备份在工程根 `AppIcon_old_讲.icns`）：
  v1 白底黑线翻开书 → v2 蓝青绿渐变底、书底加厚约 60px、书顶压扁 m 型微拱、书不填白只描黑线（渐变透出来）
  → v3（用户 2026-10-25 晚间认可）：去掉圆角方形外圈黑边；下沿（厚度一边）也做成 m 型，起伏和上沿统一，上下沿保持约 60px 均匀厚度；
  删掉页内拱形文字线和书底页间横线，只留外轮廓和书脊。渐变色系：上蓝 → 中青 → 下绿。

**② 待办结算（用户 2026-10-25 亲口定的三条，见 §7）。**
- 2.1 已实现的就不改了（代码和界面都不动）。
- 2.2 “失败后只重跑脚本”彻底删除：`AppState.lastScript` 及其赋值、诊断里的“## AI 生成的脚本（原文）”一并删掉（`AppState.swift` −461 字节）。
  副作用要知道：**此后失败诊断里不再有 AI 脚本原文**，只剩失败原因、界面提示、Python 输出、流程日志、页面截图。`runScript` 本身没删，它是主流程的执行入口，不是重跑钩子。
- 2.3 仍未实现的全部删除，不新增实现，现有界面冻结：尤其深色模式；还包括长文件名 hover 全名、`autoSend` 4 秒倒计时可配置、
  登录窗口手动关闭兜底、`generating` 改用 SVG path 检测、界面内编辑提示词、导出页面结构快照。

**③ 2026-10-25 截断误判根因与新判定（v0.20 的核心修复）。**
- 诊断：`~/Library/Application Support/讲义生成/日志/失败-20261025-151931.md`（当时已跑 v0.19），文件是 `周末6 试卷.doc` + `周末6 参考答案.docx`，deepThink 与 smartSearch 均已开。
- 旧逻辑“内容稳定 10 秒（5 轮 × 2 秒）就按完成处理”在深度思考的思考间隙里误触发，抓了 1 个代码块、16216 字，执行到第 368 行 `SyntaxError: unterminated string literal`（代码断在 `("` 处）。
  这不是等超时：用户同时在 Chrome 里看同一轮，页面后来一直在输出，最终一次写完且带 `# ===LECTURE-END===`，只是滚动条没自动跟随。
  页面停止控件当时是纯图标，`generating` 的文本信号本来就不可靠。
- 新逻辑（`Pipeline.waitForReply` + `Scripts.replyState`）：语义字段（`hasEndMark` / `looksComplete` / `afterLines`）只要有 `pre` 就算，不再只在“没在生成且没继续”时算；
  按钮匹配加读 `title` 属性；量长度前先把 `.ds-virtual-list` 滚到底，让虚拟列表把最新代码渲染进 DOM；结束标记判定移到循环顶部、无论 `generating` 都做；
  稳定兜底改成 60 秒且必须有收尾标志，否则宁可等到 10 分钟上限报“没等到完整回答”，也不执行截断脚本；无代码块的空闲判失败从 75 秒放到 180 秒。
  旧的“已经 X 秒没有新内容”提示已删，统一成 §5.5 的 5 秒播报。

**④ 菜单与 Word 卡精简（v0.20 晚间，用户要求的小优化）。**
- 页脚 ⋯ 菜单只剩「退出 DeepSeek 账号…」；`exportBundled`（导出内置附件）、`exportSnapshot`（导出页面结构快照）及 `Scripts` 里快照用的 JS 一并删除。
  内置规则/模板文件本身没删，生成提示词还要读它们。
- Word 卡删掉「打开」按钮，只剩紫色渐变「下载 Word 讲义」按钮。
- 产物不再搬到 `Application Support/讲义生成/成品`：`storeProduced` 直接返回 Python 临时目录里的原件，卡片指向的就是临时文件。
  下载成功后才删：先删文件本身，再删同批临时工作目录（只删系统临时目录下以 `讲义生成-run-` 开头的文件夹，防止误删），然后卡片回到未生成状态。
  下载失败或取消保存面板时不删，还能再点一次下载。

**⑤ 版本规则（用户 2026-10-25 晚间定）。**
- v0.20 是当前基线，写好 handover 后，接下来任何改动都升 v0.21，不再在 v0.20 上叠加。
- 下一改动时先把 `build.sh` 的版本升到 0.21，再改代码、再跑桌面脚本、再更新本文。

### 5.14 v0.21：GitHub 推送完成 + CI Release 分发

**① v0.20 推到 GitHub（2026-10-25 晚间，之前说好记在 v0.21 里）。**
- 仓库：公开库 xitihangto/jiangyi-app，默认分支 main；Muse 的 GitHub App 自动建库失败（403 Resource not accessible by integration），用户在网页上手动建库，建库时只带一个 Initial 提交（仅 LICENSE）。
- 本地 main 根提交 d885a00 与远端 Initial 无共同历史，直接推会被拒；用户选了合并路线，本地合并成 f73e8f1（“合并 GitHub 初始 LICENSE 提交”），LICENSE 留着，标签 v0.20 仍指 d885a00，2026-10-25 20:00 推 main + 推标签成功，远端核对过根目录（LICENSE、HANDOVER 40654 字节、build.sh 3176 字节、Sources/Resources/Runtime/docs/tools）。
- 连接器快照推送装不下完整仓库（1095 文件、含二进制与符号链接、Runtime 约 75MB，超 16MiB UTF-8 上限，且不带历史与标签），所以完整推送只能走 Mac 端 git；Muse 此前的 GitHub 授权不等于 Mac git 凭证，钥匙串凭证是用户在 Mac 上用 token + osxkeychain 另行存的，token 不发给 Muse。

**② CI Release（v0.21 新增，文件 `.github/workflows/release.yml`）。**
- 触发：只推标签 `v*` 时跑，不推 main 就不跑；打标签 `v0.21` 并推送后，GitHub macOS runner 上自动跑。
- 流程：checkout → `./build.sh`（只构建到 dist，不用 --install，runner 上不需要装到 /Applications）→ 用 PlistBuddy 核对包内版本与标签一致（标签去 v 后要等于 CFBundleShortVersionString，否则停下）→ `ditto -c -k --keepParent` 把 `dist/讲义生成.app` 打成 `LectureGen-<标签>.zip` → softprops/action-gh-release 发布同名 Release 并上传该 zip，Release 说明用 GitHub 自动生成的 notes。
- 权限：workflow 里 `permissions: contents: write`，用来建 Release；不需要额外 token，runner 自带的 GITHUB_TOKEN 够用。
- 分发命令（公开库，对方终端粘贴一行就能下，不用登录、不用 token，curl 不打隔离属性所以 Gatekeeper 不触发）：
  ```bash
  curl -L --fail -o ~/Downloads/LectureGen-v0.21.zip https://github.com/xitihangto/jiangyi-app/releases/download/v0.21/LectureGen-v0.21.zip
  ```
  地址最后一段必须跟 CI 上传的文件名一字不差；标签和产物名都用 `github.ref_name` 拼，换标签就换地址，不用改 workflow。
- 失败时 Release 不会生成：先看仓库 Actions 那一栏的日志，修好再重新打标签/重跑；同一标签重复建 Release 前要先删掉已有的同名 Release，否则发布那步会冲突。
- 注意：CI 产物是临时签名的 App（build.sh 里 `codesign --sign -`），靠 curl 不打隔离属性绕过 Gatekeeper，不是 Developer ID 签名 + 公证；如果苹果以后收紧这条路，要重新测。

### 5.15 v0.21 续：上传叉光晕、关闭退出确认、无代码阶段提示（2026-10-25 晚间，用户要求）

**① 上传框大叉的红色光晕改小。**
- 两个上传框（考卷、答案）共用同一个 `UploadCard`，改一处就同时改了两个，不用分开改。
- 改动（`LectureApp.swift` 的叉按钮阴影）：正常态阴影半径 6 → 3、不透明度 0.45 → 0.3、y 偏移 2 → 1；悬停态半径 9 → 4、不透明度 0.6 → 0.4、y 偏移 3 → 2。按钮本身还是 22pt、叉还是 9pt 粗体，只改光晕，不改按钮大小和位置。

**② 左上角关闭按钮（系统红灯）改为退出 App，窗口绝对中心弹窗确认。**
- 以前：红灯只关窗口，App 还留在后台；现在：`ExitConfirmWindowDelegate.windowShouldClose` 拦住关闭（返回 false），发 `lectureAppConfirmExit` 通知，`ContentView` 收到后在 620×720 窗口正中弹确认框（`exitConfirmOverlay`，半透明遮罩铺满窗口、卡片居中，不是系统 sheet），只有“退出”和“取消”两个按钮。
- 点“退出”：`NSApplication.shared.terminate(nil)`，App 完全关闭；点“取消”：弹窗消失，窗口原样保留。回车默认走“退出”，Esc 走“取消”。
- 代理挂接有两层：`WindowCloseAccessor`（background 的 NSView 拿到 window 就设代理，update 时再设一次）+ `ContentView.onAppear` 里对已存在窗口再设一次，防止时序上没赶上。代理只实现 `windowShouldClose`，其它窗口行为不受影响；Cmd+Q 走系统退出，不经过这条路。
- 注意：这是在改系统红灯的行为，验收时要专门点一次红灯：先点“取消”确认窗口还在、生成不受影响，再点红灯点“退出”确认 App 真退了（不要只测一种）。

**③ 生成后无代码阶段不再报“代码目前 0 字”。**
- 以前：`Pipeline.waitForReply` 每 5 秒统一报“AI 正在思考…，代码目前 X 字”，生成刚开始约 30 秒内智能体还在思考怎么写、还没有代码框时，也会一直报 0 字，看着着急。
- 现在：同一处播报先判 `blocks > 0 && codeLen > 0`（`blocks` 就是 `.md-code-block pre` 的个数，`codeLen` 是这些 pre 的 textContent 总长，见 `Scripts.replyState`）；两个条件都满足才恢复原来的代码字数播报，否则报“DeepSeek 正在认真思考 / 代码即将呈现”（标题 + 副标题两行）。
- 只改这一处统一播报，分段提示（“第 X 段开始生成”）和自动点“继续”的逻辑都没动；无代码块 180 秒判失败、10 分钟总上限的规则也没动。

### 5.16 v0.22：§5.15 三处改动正式发布 + 每次改动必升版必推 tag 规则（2026-10-26，用户定）

**① 为什么是 v0.22 而不是 v0.21。**
- §5.15 三处改动（上传叉光晕改小、红灯退出确认、无代码阶段提示）是 2026-10-25 23:04 在本地改的，当时以为下一版是 v0.21，handover 里也先记成 v0.21 续。
- 但远端 main 的头其实已经是 2026-10-25 20:08 的原版 v0.21 提交（1f0c365，仅 build.sh 升 0.21/21 + workflow + HANDOVER §5.14，无 Sources 改动），v0.21 标签和 Release 也已经发出，用户 curl 下来的 v0.21 里根本没有 §5.15，红灯仍是只关窗口不退 App（这正是 2026-10-26 00:25 透明窗口问题的成因之一）。
- 所以三处改动不能再用 v0.21 这个号：v0.22 把 build.sh 升到 0.22/22，本文头信息改到 v0.22，三处改动随 v0.22 提交、打标签、推送，CI 重新跑出 `LectureGen-v0.22.zip`。单看版本号分不出原版 v0.21 和三处改动版，必须看标签和 Release 产物。
- §5.15 三处改动的本地编译其实已经通过：2026-10-25 23:09 桌面脚本 `讲义生成-重新编译安装.sh` 的日志（`讲义生成-编译核对.txt`）显示编译成功、装到 /Applications、版本 0.21、构建号 21、`--selftest` 通过，只有一个无害警告（`Pipeline.swift:227` 的 `deadline` 变量未再赋值）。v0.22 只改版本号，不改 Swift 代码，CI 编译应与本地一致；CI 另有 PlistBuddy 核对（包内版本必须等于标签去 v 后的 0.22）。

**② 新版规则（用户 2026-10-26 00:33 亲口定，长期有效，不用再问）。**
- 以后每次修改，版本号一定要变：改代码前先把 `build.sh` 的 `CFBundleShortVersionString` / `CFBundleVersion` 升到下一版，再改代码、再更新本文。
- 每次改动都要把所有改动和 tag 推送到 GitHub，让 CI 自行产生 Release 产物，不用再问用户要不要推、要不要打 tag。
- 本规则取代 §5.13⑤ 的旧说法（“下一改动升 v0.21”已用完）；v0.22 起，改动、升版、提交、打 tag、推送、CI 出 Release 是一条固定流程。
- 注意：同一标签绝不删除重建；如果标签已存在，就升下一个版本号再推。

**③ v0.22 分发命令（等 CI 跑完、Release 出现后才能下到，之前会 404）。**
  ```bash
  curl -L --fail -o ~/Downloads/LectureGen-v0.22.zip https://github.com/xitihangto/jiangyi-app/releases/download/v0.22/LectureGen-v0.22.zip
  ```
  装新版前先彻底退出旧 App 再跑安装命令，否则 `open` 可能直接激活还在跑的旧进程，看到的仍是旧行为。

### 5.17 v0.23：液态玻璃（按钮与圆角框）+ 退出确认按钮改动（2026-10-26）

**① 试用过程（先本地、后上 gh，铁律的唯一例外已结束）。**
- 用户 2026-10-26 02:11 特别交代：Liquid Glass 先别推 gh，先本地跑看效果再说。先只做了上传卡试用，再扩到全窗玻璃（主窗口透明 + 全窗 clear 玻璃底）。
- 用户 2026-10-26 02:21 反馈：全窗玻璃炫酷但不实用，背景复杂就看不清。定下最终方案：主背景不要玻璃，恢复原实色背景和窗口不透明；所有按钮和圆角矩形框（含状态框）做玻璃，有质感又不失实用性。
- 用户 2026-10-26 02:25 看退出确认框截图后要求：两个小按钮改大一点、左右对调（退出在左）、按钮本身也做玻璃效果，改好就可以上 gh。至此试用结束，按铁律升版到 v0.23、推 tag、CI 出 Release。

**② 玻璃范围（`LectureApp.swift`，macOS 26+ 生效，旧系统自动回退）。**
- 玻璃：上传卡、进度/状态卡、Word 卡、退出确认卡（`.regular` 玻璃）；生成、下载、导出诊断、查看详情按钮（带 tint 的玻璃，生成蓝/中止红、下载蓝、导出粉、查看灰）；登录药丸、可下载药丸（玻璃胶囊）。
- 不玻璃：主背景（实色 + 蓝紫晕）、标题文字、进度条指示、页脚菜单、浏览器窗口、输出 sheet。
- 公开 API 没有“折射率”可调参数，边缘扭曲来自形状圆角、clear/regular 变体和窗口透明度；全窗玻璃版曾因背景复杂影响可读性被用户否掉，不要再把主背景改回玻璃。
- 实现：`trialGlassCard` / `trialGlassTinted` / `trialGlassCapsule` 三个 helper（26+ 走 `.glassEffect`，旧系统走原填充 + 阴影），`dialogGlassButtonStyle`（26+ 走 `.glass` / `.glassProminent`，旧系统走 `.bordered` / `.borderedProminent`）。

**③ 退出确认按钮（用户截图反馈后改）。**
- 顺序对调：原来取消在左、退出在右，现在退出在左、取消在右；键盘不变：回车仍是退出（`.defaultAction`）、Esc 仍是取消（`.cancelAction`）。
- 改大：字号 15（退出 semibold、取消 medium），文字左右各 22pt、上下各 7pt 内边距，按钮间距 12 → 14。
- 玻璃：退出用 `.glassProminent` + 红色 tint，取消用 `.glass`；旧系统回退到原来的 bordered / borderedProminent。
- 卡片本身已是玻璃，按钮玻璃后不要再叠一层渐变背景。

**④ v0.23 分发命令（等 CI 跑完、Release 出现后才能下到，之前会 404）。**
  ```bash
  curl -L --fail -o ~/Downloads/LectureGen-v0.23.zip https://github.com/xitihangto/jiangyi-app/releases/download/v0.23/LectureGen-v0.23.zip
  ```
  装新版前先彻底退出旧 App 再跑安装命令，否则 `open` 可能直接激活还在跑的旧进程，看到的仍是旧行为。

### 5.18 v0.24：标题栏文字隐藏 + 累计改动（2026-10-26）

**① 标题栏文字隐藏（用户截图反馈）。**
- 截图里主窗口最上方红绿灯右边有“讲义生成”几个字，和界面内大标题重复。改法：`WindowCloseAccessor` 里给主窗口设 `window.titleVisibility = .hidden`，只隐藏标题栏文字，红绿灯、标题栏本身、窗口布局都不变。
- 注意：不是把 `WindowGroup("讲义生成")` 的标题删掉，窗口本身的标题还在，Dock 菜单里的窗口名还在；只改标题栏的显示。`onAppear` 里给所有窗口挂代理的那段没加这句，避免把 DeepSeek 登录窗口的标题也藏掉。

**② 累计改动（v0.23 发布后、v0.24 之前本地累计，未单独发版）。**
- 登录状态两行合并为一行：原来登录行是两行 VStack，启动时只有登录状态，检测出已登录、深度思考联网搜索激活后第二行突然出现，窗口高度跟着变大。现改为单行 HStack（中间用 · 分隔，第二部分只在同一行横向出现），整行高度固定 30，启动到登录完成窗口高度不变。
- 退出确认按钮 hover 修复：上一版给退出/取消加的自定义 hover（onHover + 放大 1.05 + 提亮 0.08 + 手型光标）是多余残留，系统玻璃按钮之上再叠一层，玻璃材质重算时取消按钮闪黑闪白，圆角边缘 1-2 像素处手/箭头来回跳。已全撤掉，两个按钮统一用同一个系统玻璃样式（退出只多红 tint + 白字），hover 自然完全一样。
- 退出确认按钮改到约 90%：字号 15 → 13.5，内边距 22×7 → 20×6，间距 14 → 13；位置不变（退出在左、取消在右），回车仍退出、Esc 仍取消。
- 以上累计改动连同标题栏隐藏一起随 v0.24 提交、打标签、推送，v0.23 标签已存在，不能再用 v0.23 这个号。

**③ v0.24 分发命令（等 CI 跑完、Release 出现后才能下到，之前会 404；用户自己 curl，助手暂不核对 CI 产物）。**
  ```bash
  curl -L --fail -o ~/Downloads/LectureGen-v0.24.zip https://github.com/xitihangto/jiangyi-app/releases/download/v0.24/LectureGen-v0.24.zip
  ```
  装新版前先彻底退出旧 App 再跑安装命令，否则 `open` 可能直接激活还在跑的旧进程，看到的仍是旧行为。

### 5.19 v0.25：主页面 hover + 退出登录确认框玻璃化 + 退出后永不出现倒计时（2026-10-26）

**① 主页面 hover（状态框除外）。**
- 上传卡（整卡可点，生成进行中不响应）、Word 卡（仅已生成或失败时响应）、生成按钮、登录 DeepSeek 药丸、重新检查文字、Word 卡内下载/导出诊断/查看详情三个按钮、页脚 … 菜单，全部加 hover；状态框即 ProgressCard 不加，标题文字不是框/按钮不加。
- 做法一律只在玻璃上叠一层浅色提亮，不叠放大、不提亮、不加 brightness、不改玻璃本身，避免重蹈退出/取消按钮闪黑闪白；后用户反馈颜色变化太大，改轻：卡片蓝提亮 0.08 → 0.04、按钮白提亮 0.12 → 0.06、页脚 … 菜单 hover 由变蓝改为变主色。

**② 退出 DeepSeek 确认框玻璃化。**
- 原来 NSAlert 系统弹窗（屏幕居中、非玻璃）删掉，改成和退出 App 确认框一样的自定义 overlay：铺满 620×720 主界面、卡片正中、整框玻璃、按钮系统玻璃（hover 靠系统本身）。文案原样保留，退出并重新登录在左、取消在右，回车主操作、Esc 取消，生成进行中时退出按钮禁用。
- 后用户看截图反馈太宽：卡片定宽 360（内容宽 312，小字一行约 24 字、整段 41 字正好两行），按钮由横排改竖排、等宽满幅对齐、间距 10，主操作 tint 红 → 蓝；退出 App 那个确认框不动。

**③ 登录行提示 + 呼吸灯。**
- 未登录且已检测到时，在登录按钮左边显示“请登录后使用本软件”红字（品牌红、中粗 12 号）+ 蓝粗纯文字“→”（不是带边框的图标），指向登录按钮；已登录、还在检测时不显示。
- 登录按钮加呼吸灯：外部蓝光阴影在透明度 0.10～0.28、半径 4～8 之间 1.6 秒来回（用户要求外部光晕减弱后改成这个数），内部玻璃和悬停蓝 0.10 不变；登录后按钮消失，呼吸也停。

**④ 退出后永不出现倒计时（这是本版最关键的修复）。**
- 原问题：退出后登录行会先闪一下“x 秒后自动收起”再出登录按钮，时间比较短。根源是退出后重新初始化探针：`openDeepSeek()` 把 `browserShownForLogin` 设成 true 后，第一下探针还看到旧页面 DOM，误判成已登录，`reactToLoginState()` 就启动了 5 秒倒计时；下一轮探针看到新登录页才取消，所以只闪一两秒。
- 修复分两步：先是登录行倒计时文字只在已登录时显示、倒计时走完时若已退出不再收起登录窗口；后按用户点头的方案改成根本不启动：`logoutDeepSeek()` 先把倒计时拦住，直到探针明确说已退出才放行；平时也只有连续两次都说已登录才启动倒计时，偶然一次误判不启动；被拦住时如果连续三次都说已登录，就当成真正登录放行，自动登录也不会被一直拦住。
- 登录成功后 5 秒倒计时收窗口本身未动；刚打开 App 时 `browserShownForLogin` 本来就是 false，启动检测已登录也不会启动倒计时。
- 以上累计改动连同本节一起随 v0.25 提交、打标签、推送，v0.24 标签已存在，不能再用 v0.24 这个号。

**⑤ v0.25 分发命令（等 CI 跑完、Release 出现后才能下到，之前会 404）。**
  ```bash
  curl -L --fail -o ~/Downloads/LectureGen-v0.25.zip https://github.com/xitihangto/jiangyi-app/releases/download/v0.25/LectureGen-v0.25.zip
  ```
  装新版前先彻底退出旧 App 再跑安装命令，否则 `open` 可能直接激活还在跑的旧进程，看到的仍是旧行为。

### 5.20 v0.26：退出按钮 hover 变深 + 内置网页大叉只隐藏 + 模式检测先绿灯后检测（2026-10-26）

**发布规则变化（2026-10-26 上午，用户改口）。**
- 原来 2026-10-26 00:33 / 01:31 定的“每次改动必升版必推 tag”铁律暂时删除，改为：先本地重新编译、替换应用程序（关闭正在运行的实例）、先试用，累计到一定程度，等用户明确说“上线 gh”之类的命令，才推送 gh、更新 CI Release。本版就是按这条新规则攒到用户 10:45 说“满意，push 上线”才推的，v0.25 之后的所有本地改动都在这一版里。

**① 退出确认框退出按钮变灰的真相 + hover 变深。**
- 用户上午报退出按钮有时变灰，查到是主窗口失去焦点时带颜色按钮变灰，是 macOS 系统行为，用户表示不介意，不用自定义样式去绕它。
- 中间试过一次自定义路子（普通按钮 + 自定义 tint 玻璃 + 白 hover），用户否决：它和取消的系统玻璃是两个世界的产物。已全删，改回方案 1：主按钮保持系统玻璃 prominent 加红、加蓝，取消保持系统玻璃，只在主按钮上叠一层黑 0.06 hover 变深，和取消的系统 hover 逻辑统一（hover 变深、按下不弹起变浅是系统自带状态，只改 hover、不动按下）。

**② 退出后登录按钮闪烁的根治（取代 v0.25 的连续探针 / 拦截逻辑）。**
- 原问题：退出后登录按钮瞬间出现、消失约 1 秒、再出现。根源是退出时清数据回调里立刻把状态写成已退出，下一轮探针还看到旧页面误判已登录，又把按钮藏起来。
- 新做法：退出时登录行打回“正在检测”，探针第一次明确说已退出之前，登录按钮和提示字都不出现，期间误判已登录直接忽略，不翻绿点、不启动倒计时；确认后按钮只出现一次。连续探针计数、倒计时拦截逻辑已删。
- 登录行永远不显示倒计时数字：登录成功后 5 秒收窗口的倒计时只在内置网页徽标里，主界面不显示；真正登录时一次探针说已登录就启动倒计时收窗口。

**③ 模式检测先绿灯、后检测，5 秒内不出重试。**
- 原问题：第一轮探针亮绿灯的同时就跑模式检测，页面开关还没准备好就失败，文案变“正在重试”、旁边冒蓝字“重新检查”，下一轮探针又自动重试，看着很急。
- 新做法：第一轮探针只亮绿灯、不跑模式检测，下一轮探针已登录稳定了才开始检测；绿灯亮起后 5 秒内即使没激活也只在后台自动重试，不出重试字样、不出按钮，5 秒后仍未激活，“重新检查”按钮和重试文案才出现。

**④ 内置网页大叉只隐藏，不弹主界面退出框。**
- 原问题：点内置网页大叉会弹主界面退出确认框。根源是主界面出现时的兜底循环给“所有窗口”都挂了退出确认代理，内置网页窗口也被挂上了。
- 新做法：内置网页窗口自己的代理是 BrowserController，大叉只做强制隐藏（透明 + 鼠标穿透，窗口不关、不释放），主界面兜底循环跳过内置网页窗口；主界面大叉还是退出确认框，主界面点“登录 DeepSeek”走现成重新显现。隐藏后探针、模式检测、倒计时都继续，登录成功倒计时走完再隐藏一次是空操作。
- 以上累计改动连同本节一起随 v0.26 提交、打标签、推送，v0.25 标签已存在，不能再用 v0.25 这个号。

**⑤ v0.26 分发命令（等 CI 跑完、Release 出现后才能下到，之前会 404）。**
  ```bash
  curl -L --fail -o ~/Downloads/LectureGen-v0.26.zip https://github.com/xitihangto/jiangyi-app/releases/download/v0.26/LectureGen-v0.26.zip
  ```
  装新版前先彻底退出旧 App 再跑安装命令，否则 `open` 可能直接激活还在跑的旧进程，看到的仍是旧行为。

### 5.21 v0.27：重大 bug 修复——退出按钮 hover 叠层挡点击（2026-10-26）

**问题（用户 2026-10-26 11:36 报，定性重大 bug）。**
- 两个退出按钮（退出 App 的红按钮、退出 DeepSeek 的蓝按钮）用鼠标点下去都没反应，取消按钮能点。
- 根源：v0.26 给主按钮加的 hover 叠层写在按钮样式外面，叠层盖在系统玻璃按钮上面；SwiftUI 里这个叠层即使填充透明、看不见，形状还在，一样会接住鼠标，点根本到不了按钮。取消按钮没有叠层所以能点；主界面生成、Word 卡按钮的叠层在 label 里面，是按钮内容的一部分，所以不挡。
- 修法：两个主按钮的叠层内容上加 `allowsHitTesting(false)`，让点击穿过去落到按钮上。注意不能加在整个按钮上，否则按钮自己也被禁点了。hover 还是靠按钮自己的 `onHover`，变深效果还在，按下状态没动。
- 教训（用户原话，长期规则）：按钮的功能优先级比外观重要太多，以后任何视觉叠层、hover 效果都绝不能挡住按钮点击，改外观后必须先验证点击功能再谈效果。
- 以上改动连同本节一起随 v0.27 提交、打标签、推送，v0.26 标签已存在，不能再用 v0.26 这个号。

**⑤ v0.27 分发命令（等 CI 跑完、Release 出现后才能下到，之前会 404；用户表示 CI 产物和本地产物功能一样、哈希不同而已，不必在意、不必等）。**
  ```bash
  curl -L --fail -o ~/Downloads/LectureGen-v0.27.zip https://github.com/xitihangto/jiangyi-app/releases/download/v0.27/LectureGen-v0.27.zip
  ```
  装新版前先彻底退出旧 App 再跑安装命令，否则 `open` 可能直接激活还在跑的旧进程，看到的仍是旧行为。

---

### 5.22 从「高三英语作文批改」回灌的一批改动（2026-10-27，本地改，未升版未推送）

那个 App 是从本工程 1:1 克隆出去的，之后独立迭代了 v0.15–v0.21，攒出一批**与业务无关**的
通用改进。用户 2026-10-27 决定「挑实用的搬回来」，本节记录搬了什么、为什么，以及**不许回退**。

**① 新对话：不再点按钮，直接重载根地址**
- 旧做法：`Scripts.newChat` 找「开启新对话」按钮点一下，失败才兜底重载 —— 还带 30 行兜底代码。
- 事实：这套在作文版上跑了 v0.12–v0.20 九个版本，**那个按钮一次都没点中过**（每轮日志都是
  `NOT_FOUND`），等于每轮白花两三次 JS 往返。
- 现在：`Scripts.newChat` 整个删掉（`Scripts.swift` 里留了注释说明），`pipeline` 一开始就
  `browser.markReloading()` + `loadDeepSeek(force: true)`。根地址后面不带会话 id，重载出来
  必然是空白对话，不依赖任何 DOM 选择器。
- 配套：`BrowserController` 新增 `markReloading()`。**必须**先同步把 `isPageLoaded` 打回 false
  再派发主线程加载 —— 否则轮询读到的是上一轮的 true，日志里会出现「用时 0.0 秒」，等于没等。
- Safari 引擎没法从 App 里刷新，改成 `SafariBridge.openDeepSeek()` + 固定等 3 秒。
- **别再把这个选择器加回来**，加第四版也不会中，网页改版一次就废一次。

**② 重载后不盲等，等输入框真的出现**
`didFinish` 只说明文档到了，SPA 还没渲染完。旧代码固定 `sleep(1.5)`；现在轮询
`Scripts.probeComposer`，探到 `"textarea":true` 才往下走，最多 10 秒，日志打实际耗时。

**③ 结束判定：稳定 60 秒 → 稳定 3 秒**
- 旧：`stableRounds >= 12`（5 秒一轮 × 12 = 60 秒）。
- 新：`stableRounds >= 1` 且必须有收尾标志（约 3 秒），循环间隔同步从 5 秒缩到 3 秒
  （不缩的话「一轮没长」实际是 5 秒，「3 秒」就不成立）。
- 理由（用户原话）：「结束标志从未失手，60 秒纯属白等，0 秒都行，保险起见 3 秒」。
- **两条底线不动**：① 没有收尾标志时一秒都不提前，攒满 60 秒（20 轮）只提示一句然后继续等；
  ② 总上限 10 分钟不变。抢早了最坏结果是 Python 报 SyntaxError、这一轮失败，
  **不会静默产出一份错的 docx**。
- 连带：`hasEndMark` 连续 2 轮从 10 秒变 6 秒，状态框播报从 5 秒变 3 秒。

**④ 总上限收到一个常量，顺手删掉死参数**
`waitForReply(timeout: TimeInterval = 240)` 那个参数**从来没被读过**（函数体写死 600），
改成 `private static let replyDeadline: TimeInterval = 600`，签名去掉参数。
改时长只改这一处，别再往签名上加。

**⑤ 失败态不再改外观，日志只走「详情」**
- 旧：失败时主按钮换成「导出诊断报告」+「查看详情」两个，`showOutputPanel` 弹 `OutputSheet`。
- 现在：Word 卡**永远只有一个**「下载 Word 讲义」按钮，没生成好就是 `disabled`；失败只改那一行
  说明文字。`docx` 的 `didSet` 往 `progressLines` 补一行 `✗ 生成失败：…`（失败出口六七个，
  挂 didSet 才不会漏），日志统一进「详情」。
- 连带删除约 150 行：`AppState` 的 `timeStamp` / `diagnosticMarkdown` / `saveDiagnosticLog` /
  `pruneLogs` / `exportDiagnostics` / `lastFailure`，`BrowserController.snapshotPNG`，
  以及 `OutputSheet` 整个视图。
- 新增 `LogPanel`（标题行「详情」按钮打开，压暗上半屏、底部给 Word 卡留出不遮不挡的带子，
  面板绝不盖住自己的开关）。`AppState` 配套 `showLog` / `openLog` / `closeLog` / `toggleLog`。
- **别再把这套诊断加回来**：截图要等主线程、写文件要挑目录、还要定期清理，换来的只是一份
  没人看的 md，而「详情」里日志本来就有。

**⑥ 页脚整条删除 + 登出改成独立按钮**
- 删掉 `footer`：左边「绿点 + 运行环境已就绪」从来没红过（运行时是打进包里的，缺了根本打不开），
  右边「⋯」菜单里只有一项「退出 DeepSeek 账号…」。用户 2026-10-27 定：**不保留告警**，
  所以 `pythonReady` 现在界面上没有引用（属性还在 `AppState` 里）。
- 登出入口换成标题行末尾的胶囊按钮「登出 DeepSeek」：双绿灯（已登录 + 模式已激活）之后
  **0.5 秒淡入**，生成中禁点。`AppState` 新增 `logoutReady` + `syncLogoutGate()` +
  `scheduleLogoutFallback()` + `logoutAllowed` + 三个常量（0.5 / 8 / 0.5 秒）。
  - `syncLogoutGate()` **幂等**，挂两处：每轮登录探针末尾、模式检测结束。
  - **8 秒兜底必须有**：已登录但模式一直检测不出来时，到点也把按钮放出来 ——
    「⋯」已经删了，没有这个兜底用户就没有任何登出入口。
  - `logoutDeepSeek()` 里要顺手 `logoutReady = false` 并取消两个 WorkItem。
- 确认框文案跟着改：「退出 DeepSeek 账号？」→「登出 DeepSeek 账号？」，
  主按钮「退出并重新登录」→「登出并重新登录」。正文不动。

**⑦ Word 卡「可下载」去掉药丸底**
只留纯绿字。带边框看着像个能点的按钮（用户 2026-10-27 原话）。

**⑧ `build.sh` 补 `-disable-sandbox`**
非交互 / 自动化环境里，swift 驱动会用 `sandbox-exec` 包一层去起宏插件服务，被拒后报
`SwiftUIMacros ... produced malformed response`，`@State` 展不开，还会连带刷出一堆假的
「cannot assign to property: 'self' is immutable」。加 `-disable-sandbox` 关掉包裹即可，
老工具链不认这个参数时自动不加。**这个坑会让人误以为是代码写错了，实际一行代码都没错。**

**⑨ 输入框被文件名污染 —— 补 `fillPrompt()`（用户 2026-10-27 追问才发现漏了）**
- 事实：我们传附件**不走 ⌘V、不走剪贴板**，是 `feed()` 分片 base64 → `commitFiles` 拼 File →
  `DataTransfer` → 派发给 `input[type=file]` 的 change。剪贴板里是什么都无关。
- **但 DeepSeek 前端收到附件后，会自己把文件名当文字写进 textarea**。这就是网页版 ⌘V 之后
  提示词框里出现「IMG_3435.jpeg 未标题-1.png」的原因 —— 不是我们写的。
- 旧代码只有一句 `fillText(prompt)`：等附件 chip 出现 → 用 native setter 覆盖 textarea →
  等 4 秒 → 点发送。**没有任何回读校验**，网页要是在那 4 秒里又补一次文件名，就带着发出去了。
- 现在（照作文版 §6.9 的做法）：
  1. `Scripts.clearText` 先清空，等 0.35 秒让 React 状态落定；
  2. `Scripts.fillText` 填入；
  3. `Scripts.readText` 回读，与提示词比对（只忽略首尾空白），不一致就清空重来，**最多 2 次**；
  4. 自动发送前的 4 秒倒计时结束后，**再回读一次**，不一致再重填一遍；
  5. 两次都对不上不硬失败 —— 记一行 `⚠️ 提示词回读仍不一致，按当前内容发送`，照发。
- 顺序不能反：**先等附件就位 → 再清 → 再填**。清早了网页还会补回来。
- 正常路径日志里会出现「提示词已填入并回读一致（N 字）」，这是判断有没有带进去的**唯一凭据**；
  没看到这行、只看到 ⚠️ 那行，就说明这一轮提示词里混进了别的东西。

> 版本号**没动**，仍是 0.27（用户 2026-10-27 定的新口径：本地反复迭代不升版，
> 等明确说「推上去」那天再统一升一次、打 tag）。

---

### 5.23 v0.28：提示词重写 + 用户自改规则 md（2026-10-27，已发布）

**① 提示词整段换成用户自己写的新版**（`Sources/Pipeline.swift:12` 的 `static let promptText`）。

改动要点（用户给的原文，逐字照抄，只按段落加了空行）：

- 开头从「执行《讲义制作规则.md》…」变成**先列附件清单**：「我传给你了 4 个文件，分别是
  《标准模式讲义.docx》、《讲义制作规则.md》、【考卷】、和【答案】」，并说明【考卷】【答案】
  命名可能不规范、需要自行判断。
- 「其他规则不变」删掉（每轮都是重载根地址的新对话，没有「其他规则」可继承）。
- `doc.save('文件名.docx')` 放宽成「用 save() 把成品存成 .docx，文件名用中文」。
- 结束标记、收尾说明两段原样保留（`# ===LECTURE-END===`、≥3 行说明），这两段是判定链的
  第 2、3 层，不能动。

> ⚠️ **已知措辞问题（用户知情，暂不改）**：新提示词最后一句写的是「能看出是哪篇**作文**」，
> 这是从作文版复制过来的残留，讲义这边本该是「哪份讲义」。用户 2026-10-27 说「改为如下内容」，
> 所以照抄未动。要改只改这一个词，不影响任何逻辑。

**② 规则 md 由用户自己改**（`Resources/讲义制作规则.md`，+4 / −39）。

工程侧**不追踪 md 的细节**（它是给网页 AI 看的成品规格，不是工程文档）。这次是用户自己编辑
保存的，构建时由 `build.sh` 的 `cp -R Resources/.` 原样带进包内，没有任何代码改动。
核对方式：`md5 -q Resources/讲义制作规则.md "/Applications/讲义生成.app/Contents/Resources/讲义制作规则.md"`
两条一致即说明包内是新的。

**③ 版本与发布**

- `build.sh` 的 `CFBundleShortVersionString` 0.27 → **0.28**，`CFBundleVersion` 27 → **28**
  （CI 会强校验包内版本 == tag 去掉 `v`，所以 tag 只能是 `v0.28`）。
- 本轮提交同时带上 §5.22 那批回灌改动（3 秒判定、根地址新对话、删诊断、删页脚、登出按钮、
  提示词回读校验），它们此前只在本地，没推过。

---

### 5.24 v0.29：补过期项（2026-10-27，用户让 Muse 直接补）

**背景。** v0.28 发布后，Muse 2026-10-27 读 HANDOVER + 代码核对，发现两处过期项：

1. `README.md` 仍写着 v0.27，而且内容还停在 v0.28 之前：播报写的是 5 秒（v0.28 已改成 3 秒）、登出写的是页脚菜单（v0.28 已改成标题行胶囊按钮）、失败写的是自动留诊断 md/截图（v0.28 已删，改成失败只改一行字、日志走标题行「详情」）。
2. `LectureApp.swift` 里 Word 卡 hover 叠层的注释还写着“下载/导出/详情按钮”，导出/详情按钮在 v0.28 已删，只剩下载按钮 + 标题行「详情」按钮。

**改动（只补过期项，不改功能逻辑）。**

- `README.md`：版本改到 v0.29；播报改成 3 秒；登出改成标题行胶囊按钮；失败改成只改一行字、日志走「详情」；浏览器一节补一句“每次生成都重载根地址，保证空白新对话”；版本一节的“每次改动都会升版”改成新口径“日常改动先本地试用、明确说上线时才统一升一次版”。
- `LectureApp.swift`：Word 卡注释改成“下载按钮和标题行「详情」按钮”，叠层本身的 `allowsHitTesting(false)` 不动。
- `build.sh`：0.28/28 → **0.29/29**，tag 只能是 `v0.29`（CI 强校验包内版本 == tag 去掉 `v`）。

**⑤ v0.29 分发命令（等 CI 跑完、Release 出现后才能下到，之前会 404；用户表示 CI 产物和本地产物功能一样、哈希不同而已，不必在意、不必等）。**
  ```bash
  curl -L --fail -o ~/Downloads/LectureGen-v0.29.zip https://github.com/xitihangto/jiangyi-app/releases/download/v0.29/LectureGen-v0.29.zip
  ```
  装新版前先彻底退出旧 App 再跑安装命令，否则 `open` 可能直接激活还在跑的旧进程，看到的仍是旧行为。

---

### 5.25 开新对话改用 ⌘J（2026-10-28，随 v0.30 一起发布）

**背景。** 作文版先做的：DeepSeek 网页版有 `⌘ J` 开新对话的快捷键，用真实 NSEvent 注入就能触发，
比每轮重载根地址快 2~4 秒。讲义这边顺带同步。

**改了什么。**

- `BrowserController` 新增 `sendCommandKey(_:keyCode:modifiers:)`：`NSEvent.keyEvent` + `window.sendEvent`。
  带 Command 的 keyDown 在 AppKit 里走 `performKeyEquivalent`，WKWebView 覆写了它并转给页面
  （网页里 ⌘A/⌘C 能用就是这条路）。实测页面收到 `key=j, code=KeyJ, keyCode=74, metaKey=true, isTrusted=true`。
- `BrowserController` 新增 `newChatByShortcut()` + 嵌套枚举 `NewChatOutcome`，外加 `currentURLSync`
  （`webView.url` 只能在主线程取）。
- `Pipeline` 第 0 步改成三档（**只动 `engine == .webview` 分支**）。

| 页面状态 | 动作 | 日志 |
| --- | --- | --- |
| 停在根地址 | 什么都不做 | `页面已在根地址，本来就是新对话，跳过重置` |
| 停在 `/a/chat/s/<id>` | 按 ⌘J | `⌘J 开新对话：0.4 秒` |
| 没加载完 / 按了没反应 | 重载根地址 | `⌘J 没换掉会话，回退重载根地址` |

**两个必须记住的点。**

1. **第一档不能省**。App 第一次打开、刚登录、上一轮没发出去，页面都停在根地址 ——
   本来就是空对话，按 ⌘J 或重载都是脱裤子放屁。用户 2026-10-28 专门指出来的。
2. **在根地址上按 ⌘J 看不出效果**（本来就是空对话、URL 不带 id、输入框本来就空）。
   作文版第一轮验证就是在这里判了「❌ 没反应」，差点把这条路毙掉。
   正确姿势：先发一句话让地址栏变成 `/a/chat/s/<id>`，再按，看 URL 是否变回根地址。

`isPageLoaded == false` 直接判 `.failed`，防止空 URL 被误当成「根地址」。
`.shortcut` 成功后 `sleep 1.2` 秒 —— 地址栏变了不代表 DOM 已经换完，SPA 切会话是异步渲染的。

**Safari 模式不动**：跨进程注入不了键盘事件，仍然走 `SafariBridge.openDeepSeek()` 重开根地址。

---

### 5.26 v0.30：上传框支持拖入 + 两框之间查重（2026-10-29）

用户 2026-10-29 的要求原话：**「增加拖入功能，不需要粘贴功能，单个框只支持单文件……
我怕两个文件框会不小心上传一样的试卷（把答案当试卷或反之亦然），所以两框之间要有查重功能，
但是别生搬硬套，注意冒泡位置等问题，doc 文件都很小，性能优化问题可以不管，文案也顺便修改（俩框都改）」**。

所以这一版**不是**从「试卷识别 / 作文批改」照搬 —— 那两个 App 是「一个框放多个文件」，
讲义是「一个框放一个文件」，多文件那套（批量建卡片、整批合并、汇总提示）一律没要。

#### 5.26.1 拖入

`UploadCard` 的卡片上挂 `.onDrop(of: [.fileURL], isTargeted: $dropTargeted)`：

```swift
.onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
    guard !state.isRunning, !providers.isEmpty else { return false }
    AppState.resolveFileURLs(from: providers) { urls in
        state.acceptDropped(urls, for: slot)
    }
    return true
}
```

- `AppState.resolveFileURLs` 用 `DispatchGroup` 收齐所有 `NSItemProvider`（保持拖进来的顺序），
  全回来才回调 —— 拖 3 个只弹一条提示，不是三条。
- `acceptDropped`：**只取第一个**，多出来的忽略，并提示「一个框只放一个文件，只用了 xxx.docx」。
- 拖到框上方时 `dropTargeted` 为真：底色叠一层 `brandBlue 0.07`、边框变成加粗的蓝线（1.6pt）。
  有文件时本来就靠 `RotatingGradientBorder`，拖入时那条蓝线压在它上面，两者不冲突。
- **没有做粘贴**。用户明确说不需要，`AppState` 里也没有 `pasteFromClipboard`，
  别看到另两个 App 有就顺手加。

#### 5.26.2 两框查重（`AppState.sameFile`）

**这是这一版的重点，也是最容易做错的地方**：判重必须跨框，不是框内。

判在 `accept(_:for:)` 里 —— 点框选文件和拖入共用这一个入口，所以两种放法都拦得住。

```swift
if let other = (slot == .exam ? answerURL : examURL), Self.sameFile(url, other) {
    showToast(slot == .exam
              ? "这份和「上传答案」里的是同一个文件，检查一下是不是放反了"
              : "这份和「上传考卷」里的是同一个文件，检查一下是不是放反了",
              on: slot)
    return false
}
```

`sameFile` 两级判定：

1. **先比路径**（`standardizedFileURL`）—— 同一个文件被选进两个框，这是最常见的情况，一次字符串比较就够；
2. **再比内容**（`fingerprint(ofFileAt:)`）—— 复制一份、改个名字再放进来，路径不同但内容一样，也能拦住。

指纹是「字节数 + 头 128KB + 尾 128KB 的 SHA-256」，只读头尾不读全文。
讲义的 doc/docx 只有几十 KB，本来整份读也不慢 —— 这么写只是不让「把整个文件读进内存」变成习惯。
读不出内容时一律当作**不同**，宁可可放过去，也不要误杀。

**同一次操作里还要挡类型**：`accept` 里先查 `allowedExtensions`（doc/docx）。
`NSOpenPanel` 有 `allowedContentTypes` 挡着，但拖放绕得过 —— 不自己挡就会拖进来一个 pdf。

#### 5.26.3 冒泡位置（用户特别交代）

`AppState` 新增 `toast` / `toastSlot` / `showToast(_:on:)`，**每个提示都必须带 slot**。

- `UploadCard` 用 `.overlay(alignment: .bottom)` 把它贴在自己**下沿内侧**（`padding(.bottom, 6)`），
  并且只在 `state.toastSlot == slot` 时显示 —— 所以提示一定落在被操作的那个框上，
  不会跑到窗口顶部，也不会串到另一个框。
- **为什么不居中**：这张卡只有约 95pt 高，居中的胶囊会把「上传考卷」标题盖掉。
  贴底部只盖住最后一行（「＊必选…」或「xx KB · …」），标题和文件名都还看得见。
- 红色胶囊（`brandRed 0.93`）+ 白字，2.7 秒自动消失，点一下也能提前收（`dismissToast`）。

#### 5.26.4 文案（两个框共用，改一处就都变）

| 位置 | 改前 | 改后 |
| --- | --- | --- |
| 空框第二行 | ＊必选，点框里任何地方选择文件 | ＊必选，点框选择，或把文件拖进来 |
| 有文件第二行 | `N KB · 点框里任何地方可以换一个` | `N KB · 点框更换，或拖入新文件` |

两个框的 `subtitle`（「支持 .doc / .docx，含题目与原文」/「含参考答案 / 解析 / 范文」）没动。

#### 5.26.5 自检

```bash
dist/讲义生成.app/Contents/MacOS/LectureGen --dupetest
```

验证四件事：①同内容不同名的指纹一致；②不同内容指纹不同；
③考卷框放过的文件再往答案框放**必须被拒**，提示含「放反」，且 `toastSlot` 是答案框、答案框仍然是空的；
④类型不在白名单的（.pdf）被拒。当前输出全绿。

#### 5.26.6 已知局限（用户已确认不用管）

查重只能抓「**同一份文件放进两个框**」。如果两份**内容不同**的文件被放反
（答案拖进考卷框、考卷拖进答案框），程序没法知道。
用户 2026-10-29 明确说：**放反没关系，提示词里已经让 DeepSeek 自行判断了，不用加逻辑**。

---

### 5.27 继续按钮逻辑对齐试卷识别（2026-10-29）

试卷识别 app 把「点继续」这条链路磨了三轮，用户要求把结论整套搬回来。

> ⚠️ **§5.6「点击后必须验证，且要等够久」里的 12 秒判据已作废**，以本节为准。
> 别再照着 §5.6 改回去 —— 那套判据会把有效点击误判成无效，补点一次就把生成掐死。

本工程原来的版本比试卷识别 app 旧两轮：**没有 4 秒保护期、没有按钮消失判据、
`locateContinue` 无条件滚动且没有命中测试、点击也不补 `mouseMoved`**。

#### 5.27.1 点击前必须补一次 `mouseMoved`（`BrowserController.clickAtViewportPoint`）

用户实测：同一个坐标连点 5 次，**第 1、3 次无效**，第 2、4、5 次有效 ——
每次「继续」按钮出现后的第一次点击都被吞掉。两个原因叠在一起：

1. `makeKeyAndOrderFront` 之后立刻 `sendEvent`，窗口还没真正成为 key，
   第一次点击被系统拿去激活窗口，事件落不到 webview；
2. 从没发过 `mouseMoved`，页面没有这个坐标的 hover 状态，
   React 的 `onMouseEnter` 不触发、WebKit 的 tracking area 也没建立。

修法：先发一次 `.mouseMoved`，`Thread.sleep(0.12)`，再 down/up（时间戳顺延到 `now+0.12` / `now+0.18`）。
**顺序很关键**：`mouseMoved` 必须在 `makeKeyAndOrderFront` 之后发，否则窗口还没起来，事件照样丢。

#### 5.27.2 判据从「12 秒涨字」改成「0.6 秒按钮消失」

原来的写法是点完盯着字数涨，`for attempt in 0..<6` 每 2 秒看一眼，12 秒不涨就记一次无效。
问题：AI 点完「继续」要先重新想十几秒才出字，**有效点击会被误判成无效**，
两次就抛「AI 停下来之后没有继续写」；更糟的是补点一次会把刚恢复的生成掐死。

用户实测：手点下去按钮**瞬间消失**，绝不会变成「停止」。所以改成：

- 点完连查 3 次、每次间隔 0.2 秒，看按钮是否消失（共 0.6 秒）
- 消失了 → 认定点击被接受，再给 24 秒等出字，期间**绝不重复点击**
- 没消失 → 才算被吞，立刻补一次

#### 5.27.3 `probeContinue(nearY:)` 只认「刚点的那个位置」

新加的 `Scripts.probeContinue(nearY:)` 用来判断按钮还在不在，**不滚动、不点击、无副作用**。

⚠️ 它必须只认 `nearY`（点击时的视口 y）**±40px** 那个位置上的按钮，不能写成
「页面上有任意一个继续按钮就算」—— `locateContinue` 是按 `top` 降序取**最靠下**（最新）
的那个去点，两套判据必须对齐。历史消息里如果还留着旧的「继续生成」按钮（DOM 没清掉），
按「任意一个」判就会永远认为「按钮还在」→ 误判成「点击被吞」→ 攒够 2 次直接抛错。

`nearY` 从 `REAL_MOUSE(x,y)` 的返回值里解析（`clickedY(from:)`）；
拿不到（走 JS 兜底点击）时传 nil，退化成「任意位置存在即算」。

#### 5.27.4 24 秒死等改成「6 秒后开始盯按钮」

点完确认消失后，原来是一个 `for attempt in 0..<12` 干等 24 秒。
但 AI 有时只写两三百字又截断，按钮几秒内就重新出现，这 24 秒纯白等。
现在 6 秒后顺带探测按钮，一冒出来就 `break` 交回外层循环再催。

#### 5.27.5 4 秒保护期（本工程原来完全没有）

**文字还在长 = 其实正在生成**，但「继续生成」按钮可能仍挂在 DOM 上
（停止按钮是纯图标，`generating` 认不出来）。这时点下去会落到同一位置的「停止」上，
把刚恢复的生成掐死。日志证据（试卷识别 app）：点完继续 1.6 秒后又点了一次 →
之后 24 秒一个字没涨 → 失败。

所以：`Date().timeIntervalSince(lastChangeAt) < 4.0` 时绝不点，老实等它写完。

#### 5.27.6 `offsetParent === null` 判不出 `position: fixed`

`position: fixed` 元素的 `offsetParent` **同样是 null**，会被当成「不存在」。
本工程有 4 处用了这个判据（`sendNow` / `probeComposer` / `clickContinue` / `locateContinue`），
全部换成 `getComputedStyle` 的 `display` + `getBoundingClientRect()` 实际宽高。

最要命的是 `probeComposer`：漏掉「停止」按钮 → `generating` 恒 false →
以为没在生成、提前点继续 → **把生成掐死**。

**以后在这个工程里判按钮可见性，一律别用 `offsetParent`。**

#### 5.27.7 `locateContinue` 另外三项

- 文字改从 `.ds-button__content` 取（用户 DevTools 实测，按钮是
  `<div role="button" class="ds-button …"><span class="ds-button__content">继续生成</span></div>`）
- 只有按钮**不在视口内**才滚，且用 `behavior:'auto'`；要滚就返回 `SCROLLING`，
  让 Swift 等滚动停下再取一次坐标。
  原来无条件 `scrollIntoView({behavior:'instant'})`，而 `'instant'` 不是标准值，
  WebKit 会退回平滑滚动 —— 下一行立刻取的 rect 还是旧坐标，点下去就落到别处。
- 点之前做 `elementFromPoint` 命中测试，命中元素不是按钮本身或子孙就返回 `NOT_HIT`，绝不下手

`clickContinueButton` 相应改成 4 次重试循环，处理 `SCROLLING` / `NOT_HIT`，失败返回 `LOCATE_UNSTABLE`。

#### 验证

- 三个 App（试卷识别 / 讲义生成 / 作文批改）的 `locateContinue` + `probeContinue`
  共 12 段 JS 全部过 `node --check`（nil 与非 nil 两种插值都验）
- `swiftc -typecheck` 通过，`./build.sh --install` 通过，单实例启动
- **真实网页端的表现还没跑过**：这套逻辑是从试卷识别 app 的实测结论搬来的，
  本工程的按钮 DOM 是否完全一致（`.ds-button__content` 是否存在）**尚未验证**

---

### 5.28 ⏳ 上传框目录互相同步（2026-10-29，**临时记录，待推送**）

> 用户第 16 轮要求：先编译、记待办，等他说推的时候一起推；**推送后本节改成正式记录并删掉 §7 的待办**。

**需求**：两个上传框（考卷 / 答案）的「上次打开面板的目录」必须互相同步 ——
在框 1 里选定了目录和文件，框 2 下次打开面板要直接落在同一个目录；
关掉 App 重开还记得；直到用户又选了别的目录，再重新同步一次。

**原来的问题**：`AppState.rememberDirectory` 只写本框的键（`pickDir.exam` / `pickDir.answer`）
和老的共享键 `pickDir.shared`，**不写另一个框的键**。而 `startDirectory` 是
「本框优先 → 另一个框 → 共享 → 下载目录」——只要另一个框自己记过目录，本框就永远继承不到新的。

**改法**（`Sources/AppState.swift`）：

```swift
private func rememberDirectory(_ url: URL, slot: Slot) {
    let dir = url.deletingLastPathComponent().path
    let ud = UserDefaults.standard
    ud.set(dir, forKey: AppState.dirKey(slot))
    ud.set(dir, forKey: AppState.dirKey(slot == .exam ? .answer : .exam))  // ← 新增：另一个框立刻继承
    ud.set(dir, forKey: "pickDir.shared")
}
```

两个键从此恒等，「本框优先」退化成纯容错（某个目录被删/挪走时还能退到别处）。
`startDirectory` 逻辑没动。

另外把 `chooseFile` 的回调改成**先记目录、再收文件**（原来讲义是 `accept` 内部记、
作文是 `acceptBatch` 之后记）：哪怕文件因为类型不对被拒，「用户导航到了哪个目录」
这个事实也该记住并同步。

#### 顺带补的：`build.sh` 签名前加 `xattr -cr`

查作文版的时候发现 `codesign` 那行是 `... 2>/dev/null || echo "  (签名跳过)"`，
**`xattr -cr` 试卷识别版有，讲义和作文都是从那套骨架克隆/回灌时漏掉的**（本工程只是碰巧没复现）。
一旦签名被跳过，bundle 只剩 linker-signed、`Identifier` 退化成可执行文件名 `LectureGen`，
而 `UserDefaults` 和 WKWebView 的 cookie 都按 Identifier 分域 —— 目录记忆和登录态一起丢。
本工程也补上，并去掉 `2>/dev/null` 让失败可见。详见 §8 坑表最后一行。

**版本**：未升版（按 §10 约定，日常改动沿用当前版本号，用户说发布才升）。
本地已 `./build.sh --install`，**未推 GitHub**。

---

## 6. DeepSeek 网页真实结构（实测，别猜）

来源：`~/Desktop/讲义生成-DOM快照-*.json`（用户导出的真实快照）

### 代码块
```html
<div class="md-code-block md-code-block-light">
  <div class="md-code-block-banner-wrap">
    <div class="md-code-block-banner md-code-block-banner-lite">
      <span class="d813de27">python</span>
      <div role="button" class="ds-button ...">复制</div>
      <div role="button" class="ds-button ...">下载</div>
    </div>
  </div>
  <pre><span><span class="token comment"># -*- coding: utf-8 -*-</span></span> ...</pre>
</div>
```

**关键：`<pre>` 里面没有 `<code>`**，内容全是 `<span class="token">`。
所以 `querySelectorAll('pre code')` **恒为 0** —— 这是早期 blocks 一直数不到的根因。
正确选择器：`.md-code-block pre`。

### 按钮
全是 `div[role=button].ds-button`，**不是 `<button>`**。

- 代码块头部：复制、下载（class `code-info-button-text`）
- 消息操作栏：朗读（`aria-label="朗读"`）、点赞、点踩、分享
- 截断时底部：「继续生成」（`ds-button--outlinedNeutral`）

### 其它
- 输入框：`textarea._27c9245`，placeholder `给 DeepSeek 发送消息 `，`name=search`
- 正文容器：`.ds-markdown`
- 消息列表：`.ds-virtual-list`（**虚拟滚动**，长对话早期消息可能不在 DOM）
- **没有** `loading` / `typing` / `generating` 之类状态标记；`blink` / `cursor` 只在 CSS 里
- 整个对话**只有一个 `<pre>`**，分段生成的内容会合并进同一个代码块

### textContent 提取质量（已验证）
把 `<pre>` 去标签后：234 个换行全部保留，`from docx import Document`、`doc.save(...)` 都在。
**不存在换行丢失问题**，取出来是干净可执行的 Python。

---

## 7. 待办清单（2026-10-25 已按用户决定结算，v0.20 起不再新增待办）

> 用户亲口定的三条：2.1 已实现的就不改了（代码和界面都不动）；2.2 “失败后只重跑脚本”彻底删除；
> 2.3 仍未实现的全部删除（尤其深色模式），只保留现有界面。**下面“已删除”里的项不要再捡回来做，除非用户重新下令。**
>
> 唯一的例外是「⏳ 待推送」一节：用户让先改先编译、攒着等命令一起推时，临时记在那里，**推完即删**。

### ✅ 已完成：内置浏览器彻底隐形（v0.14）

> 用户要求：「内置浏览器除了登录用，其他时候能不能完全不显示，不弹出？」
> 六组实验定方案，v0.14 已实现。原理见 §5.8，实现见 §5.9①②。
> **验收还差一步**：从头跑一次完整流程，确认全程只看到主窗口、点击仍生效。

### ✅ 已实现（不动，只剩观察/验收，不改代码）
- [x] **深度思考+智能搜索自动激活已实现（待真实登录页面验收）**
  - 已修复坐标 JSON 解析、主线程可信点击、点击后的复检与未就绪重试。
  - 相关代码：`AppState.ensureDeepSeekModes()` / `Scripts.probeComposer` / `AppState.idleStatus`
  - 验收方法见 §5.12④。
- [x] 多个 docx 产出时的命名：`xxx-2.docx` 已实现
- [x] 诊断包里有页面截图（`WKSnapshotConfiguration`，自动日志 + 手动导出都有）
- [x] 多种登录文案识别、标题卡不再转渐变边框、Finder `selectFile` 定位
  - 其中“保存完讲义后额外弹桌面窗口”是否已被 `selectFile` 修掉，仍需用户下次跑流程时观察确认（只观察，不改代码）

### ❌ 已删除（用户决定，不再做；v0.20 起代码里也不留钩子）
- ~~失败后「只重跑脚本」~~：`lastScript` 已删，诊断里的 AI 脚本原文也随之删掉，见 §5.13②
- ~~深色模式实测~~、~~长文件名 hover 显示全名~~、~~`autoSend` 4 秒倒计时可配置~~
- ~~登录窗口手动关闭时 `browserShownForLogin` 的兜底~~、~~`generating` 改用 SVG path 特征检测~~
- ~~提示词可在界面上编辑~~、~~内置附件丢失时的更具体提示~~
- ~~导出页面结构快照~~：v0.20 已从菜单、代码、JS 里全部删除，见 §5.13④

### ⏳ 待推送（用户 2026-10-29 第 16 轮：先编译、先记着，等他说推再一起推）

- [ ] **上传框目录互相同步**（改动见 §5.28，已编译安装，未推 GitHub）
  - 推送时要做：①升 `CFBundleShortVersionString` ②`git push origin main` + `git push origin vX.Y`
    ③把 §5.28 标题里的「⏳ 临时记录，待推送」去掉、改成正式记录 ④删掉本条待办

### 仍需验收（只观察，不改代码）
- 真实登录页面验收深度思考+智能搜索自动激活（见 §5.12④）
- 下次跑完整流程时观察：全程只见主窗口、点击仍生效、保存后 Finder 只开一个窗口
- v0.20 安装核对：桌面脚本的 `讲义生成-编译核对.txt`（版本 0.20、图标、新图标 PNG 目视、`--selftest`）

---

## 8. 踩过的坑（别重犯）

| 坑 | 症状 | 原因 / 解法 |
|---|---|---|
| `pre > code` | 代码块数恒为 0，流程干等 | DeepSeek 的 `<pre>` 里没有 `<code>`，用 `.md-code-block pre` |
| JS 点击无效 | 点了没反应 | 页面检查 `isTrusted`，必须用 NSEvent 注入 |
| 只等 3 秒验证 | 「点了一次就停」 | DeepSeek 要想一会儿才出字，改 12 秒 |
| `innerText` 量长度 | 页面隐藏时误判写完 | 换 `textContent` |
| `guard let self` 重复 | 编译报 Optional 类型错 | 外层已解包后，内层直接用 `self` |
| 三元表达式类型 | `.foregroundStyle(a ? .secondary : .red)` 编译不过 | 写 `Color.secondary : Color.red` |
| App Nap | 屏外窗口流式输出卡住 | `beginActivity([.userInitiated, .idleSystemSleepDisabled])` |
| `JSONSerialization` | 传裸 String 崩溃 | 加 `.fragmentsAllowed` |
| 文件面板英文 | 系统面板显示英文 | 加 `zh-Hans.lproj` + `CFBundleDevelopmentRegion` + `CFBundleLocalizations`，**并删掉 en.lproj** |
| 以为「页面隐藏 → DOM 不刷新」 | 误判写完、白弹浏览器 | **这是错的**。`textContent` 一直正常，真凶是 `innerText`。见 §5.7 |
| 想省掉 `makeKeyAndOrderFront` | 点击延迟 2 秒 / 3 次只中 1 次 | 非 key 窗口注入 NSEvent 不稳，必须 makeKey。见 §5.8 |
| 用「挪到屏幕外」藏窗口 | 双屏时会漏到副屏 | 改 `alphaValue = 0` + `ignoresMouseEvents`。见 §5.8 |
| `withAnimation` 推渐变角度 | 边框不转 | `AngularGradient.angle` 不可动画，用 `TimelineView` 逐帧算。见 §5.9⑧ |
| 叉按钮放进大按钮里 | 点叉变成了选文件 | 用 `ZStack` 把叉叠在上层，别嵌套 Button |
| `makeKey` 后不还 key | 主窗口标题栏一直灰 | 记住 `previousKey`，注入完再 `makeKeyAndOrderFront` 回去 |
| 自动弹保存面板 | 打断用户、且临时文件可能已被清 | 产物先复制到 App Support，界面给常驻卡片。见 §5.9⑤。**v0.20 已改：不再搬到 App Support，卡片直接指向临时文件，下载成功后删除，见 §5.13④** |
| 稳定 10 秒就当写完 | 抓到截断脚本，Python 报 SyntaxError | 2026-10-25 实测：16216 字、第 368 行断在 `("` 处。改成稳定 60 秒且必须有收尾标志，否则等到 10 分钟上限，绝不执行截断脚本。见 §5.13③ |
| 诊断里找不到 AI 脚本原文 | 以为诊断丢了内容 | 不是丢了：v0.20 删 `lastScript` 时把诊断里的脚本原文一并删了，只剩失败原因、提示、Python 输出、流程日志、截图。见 §5.13② |
| 启动时判「未登录」 | 明明登录了却闪出登录按钮 | 页面 DOM 还没渲染，`textarea`/密码框都是 null。加 `bodyLen` + `hasLoginButton`。见 §5.10① |
| 上传阶段点中止没反应 | 中止按钮像坏了 | 只在 `waitForReply` 里查了 `stopRequested`，补 `checkStop()` + 杀 Python 进程。见 §5.10⑤ |
| 登出后重新登录窗口自动收起 | 来不及登录窗口就没了 | `logoutDeepSeek()` 要停掉旧 timer + 重置 `browserShownForLogin`。见 §5.12① |
| 登出后状态框还显示"已登录" | 状态没刷新 | `logoutDeepSeek()` 要清 `progress = ProgressInfo()`。见 §5.12① |
| Finder 里 App 图标不显示 | 只有 Dock 有图标 | build.sh 要加 `SetFile -a B` 标记 bundle。见 §5.12① |
| **`codesign` 静默跳过，bundle id 悄悄变了**（试卷识别版早有；讲义和作文克隆时漏了，2026-10-29 补上） | 构建日志只有一句「(签名跳过)」，看起来正常；`codesign -dv` 显示 `flags=0x20002(adhoc,linker-signed)`、`Info.plist=not bound`、`Identifier=LectureGen` 而不是 `com.workbuddy.lecturegen` | 增量构建时 `SetFile -a B` 写进去的 FinderInfo 让 codesign 报 `resource fork, Finder information, or similar detritus not allowed`，被 `2>/dev/null` 吞掉就只剩一句「跳过」。**后果很隐蔽**：`UserDefaults` 和 WKWebView 的 cookie 都按 Identifier 分域 → 偏好全丢、DeepSeek 登录态丢失。修法：签名前 `xattr -cr "$APP"`（本工程 build.sh 已补），**且不要 `2>/dev/null`**。查体：`codesign -dv` 的 `Identifier` 必须等于 `Info.plist` 的 `CFBundleIdentifier` |

---

## 9. 环境依赖

- macOS 13+（实测 macOS 27 / 26A434，arm64）
- Xcode Command Line Tools（`swiftc`）
- 无需 Xcode 工程，无需 CocoaPods / SPM
- 网络：能访问 `chat.deepseek.com`
- 用户需在 DeepSeek 网页版登录一次（登录态会存在 App 容器里）

---

## 10. 一句话给接手的人

**这个项目的全部难度都在「怎么可靠地知道 AI 写完了」，其他都是常规活。**

遇到判定问题，先看 `Pipeline.waitForReply` 的四层判定和 `Scripts.replyState` 的字段，
再看失败诊断日志里的页面截图和流程日志 —— **不要凭印象猜 DeepSeek 的 DOM**，那已经浪费过好几轮了。
（v0.20 已删除「导出 DOM 快照」，不要再指望它拿结构。）
