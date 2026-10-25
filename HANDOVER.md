# 讲义生成 App · 交接文档

> 最后更新：2026-10-25 ｜ 当前版本 **v0.20** ｜ 状态：**v0.20 为当前基线；用户已认可 v0.20 改动并先去多测几遍，下一改动起升 v0.21**
>
> 📌 **接手先看**：§5.8（浏览器隐形）、§5.9（v0.14 结构）、§5.10（登录检测 / 诊断包）、
> §5.11（v0.16 的光标 / 状态框 / Finder）、§5.12（v0.17 新功能）、§5.13（v0.19–v0.20）、§7 待办（已按用户决定结算）。
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
  │   ├─ 1. Scripts.newChat        点「开启新对话」，清掉上一轮残留
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
