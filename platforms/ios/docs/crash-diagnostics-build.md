# iOS 自签闪退诊断版说明

## 2.1.0：新增 MusicFree 插件兼容（2026-11-18）

这一版在**不改动播放主链、锁屏 / 控制中心歌词、CarPlay**的前提下，增加了
MusicFree 插件支持。没有内置任何插件或音源，所有插件都由用户自己导入。

**隔离方式**：`LXUserAPIPreload.js` 会递归冻结 `globalThis` 并禁用
`eval` / `Function`，而 MusicFree 插件是 CommonJS 模块，两者不能共用沙箱。
因此新增独立的 `MusicFreePreload.js`，在独立 `JSContext` 里运行；原生侧的
网络代理、加密、定时器、Cookie jar 在两侧共用。

**沿用现有逻辑的做法**：插件方法的返回值被翻译成 LX 报文契约——
`getMediaSource` → `musicUrl` 响应 `{data:{url:...}}`，`getLyric` → `lyric`
响应 `{data:{lyric:...}}`。于是播放仍走 `resolveMusicURLAcrossSources` 的
逐音源尝试与失败回退，歌词仍走原来的 `resolveLyrics` → 锁屏 / 控制中心显示
链路。聚合搜索的 TaskGroup 增加了一个插件搜索分支，`IMusicItem` 被转换成
`Track`，原始 item 完整保存在 `sourceMetadata["mf.itemJSON"]`，播放时原样
交回插件，避免字段丢失。

**已提供的 JS 全局**：`require`（axios / cheerio / crypto-js / dayjs / he /
qs / big-integer / url / buffer / path）、`URL`、`URLSearchParams`、`Buffer`、
`atob` / `btoa`、`setTimeout` / `setInterval` 及 `env.getUserVariables()`。
其中 axios 接到原生 URLSession（带按域名 Cookie 持久化与 arraybuffer 支持），
cheerio 是覆盖常用 CSS 选择器的内置实现，crypto-js 由 CommonCrypto 支撑。

**实测覆盖率**：用 `musicfre插件` 目录的 69 个真实插件做加载测试，
65 个成功加载。失败的 4 个中，2 个依赖尚未实现的 `webdav` 模块，
2 个（酷我音乐Thomas / 酷狗Thomas）自身存在 `let t, z = z || ...`
的重复声明，在 Node 原生环境同样无法加载。搜索 / 播放的实际成功率还
取决于插件服务端是否可用。

**排错**：设置 → 诊断 →「检测 MusicFree 插件」可在不切换当前音源的前提下
读取每个插件声明的方法；插件搜索、播放、歌词的关键步骤都会写入诊断日志
（category 为 `plugin`），导出方式与崩溃日志完全相同。

**已知边界**：榜单、歌单详情、评论等插件方法未接入，这些功能仍由应用内置
目录接口提供；需要登录 Cookie、WebDAV、二进制流处理的插件可能需要额外适配。

## 2.0.3：真机日志已定位并修复根因（2026-11-18）

诊断版导出的 `iMusic-Diagnostics-20261118-162720.txt` 给出了确切崩溃栈：

```
[play]   resolveMusicURL 开始: Around the World (TV-Size) / exhigh
[source] 音源脚本加载完成
[FATAL]  NSException NSInvalidArgumentException:
         *** +[NSJSONSerialization dataWithJSONObject:options:error:]:
         Invalid top-level type in JSON write
  iMusic  LXUserAPIService.callJS(action:data:) + 320
  iMusic  LXUserAPIService.installHostFunctions(in:) (timeout 回调) + 132
[FATAL]  process terminated by signal SIGABRT(6)
```

**根因**：`LXUserAPIService.installHostFunctions` 里的 `__lx_native_call__set_timeout`
宿主函数在定时器到期后调用 `callJS(action: "__set_timeout__", data: id)`，`id`
是 Swift `Int`。旧实现直接把 `Int` 当作 JSON 顶层对象传给
`JSONSerialization.data(withJSONObject:)`，而 Foundation 只允许数组 / 字典作为
顶层对象。它抛的是 **Objective-C `NSException`，不是 Swift Error**，所以 `try?`
完全拦不住，异常一路冒泡到 `objc_exception_throw`，进程以 `SIGABRT` 结束。

时间线也吻合：音源脚本 08:27:13.763 加载完成，08:27:14.134 崩溃，371ms 后
正是脚本里第一个 `setTimeout` 到期。LX 音源的网络请求、重试、请求队列普遍
依赖 `setTimeout`，因此**播放、搜索、导入歌单等所有涉及音源的操作都会闪退**。
这与 iOS 27、自签证书、entitlements 都无关，是纯代码缺陷。

**修复**：新增 `Core/API/SafeJSONEncoding.swift`，所有 LX 桥接的 JSON 写入改走
`SafeJSON`：先递归归一化（拆嵌套 Optional，把 URL / Date / Data / 自定义类型
转成 JSON 安全表示），再用 `isValidJSONObject` 预检；标量顶层值改用
`.fragmentsAllowed` 输出 JSON fragment。JS 侧 `__lx_native__` 用
`JSON.parse(data)` 期待的正是 `123` 这样的数字字面量，协议完全不变。
同时收敛了 `LXCommentsService`、`LXSyncClient` 里同类无保护的序列化调用，
并去掉 `callJS` 中的 `encoded!` 强制解包。

修复版会打印前 3 条 `LX setTimeout 回调 #n: id=... delay=...ms` 日志，
用于确认此前必崩的路径现在能正常走完，且不会刷屏。

## 2.0 诊断版做了什么

用户环境：iOS 27.0.1，自签（个人证书 / 全能签 / Sideloadly 等）安装，
播放、导入歌单等操作都会闪退。

首轮源码审查的结论（保留作为排查记录）：

- 当前仓库里的 `LXCatalogService.zzcSign` 已经修掉了 CHANGELOG 0.5.0 记载的
  「iOS 27 启动闪退」（QQ 聚合搜索签名表含索引 40，而 SHA-1 十六进制串只有
  0...39，Swift 的 `String.Index` 会直接 trap）。旧 IPA 若仍带此缺陷，启动就会崩。
- `KumoneIOS.entitlements` 是空的，没有 App Group、Keychain Sharing、CarPlay
  等自签证书拿不到的 capability。
- 单例初始化、Keychain、UserDefaults、Codable 解码、歌单导入路径都没有 `try!` /
  `as!` / 强制解包。

首轮据此怀疑 IPA 不是从这份源码构建的（旧包），或重签过程中丢了资源
bundle / Info.plist 键。日志证明这些加固有效但都不是主因；它们仍然保留，
因为对自签环境有价值。诊断版做了三件事：

1. 重新从当前源码构建一份干净的未签名 IPA（含已修复的签名越界）。
2. 针对自签环境加固三条高风险路径：
   - `BGTaskScheduler.register` 前校验 `BGTaskSchedulerPermittedIdentifiers`
     和 `UIBackgroundModes(fetch)`；plist 键丢失时不再注册，避免 launch 时
     抛出无法捕获的 `NSException`。
   - 音源加载不再使用会强制解包的 `Bundle.module`，改为主 bundle +
     扫描内嵌 `.bundle`，并去掉 `installHostFunctions(in: js!)` 的强制解包。
   - 启动阶段不再在主线程执行用户导入的 LX 音源脚本，改为首次播放 / 测试时
     按需加载（避免脚本卡住主线程触发 watchdog 杀进程）。
3. 加入常驻诊断日志与导出能力，用于复现后定位。

## 构建

GitHub Actions `iOS diagnostics IPA (unsigned, self-sign ready)`
（`.github/workflows/ios-diagnostics.yml`）在 push 到 `main` 且改动了
`platforms/ios/**` 时自动构建，也可手动 `workflow_dispatch`。

- runner：`macos-26`（GitHub 托管），Xcode 26.6 / iOS 26.5 SDK。
- 部署目标降到 iOS 26.0：代码只使用 iOS 26 的 Liquid Glass API，没有 iOS 27
  专有符号；iOS 27.0.1 设备可以正常安装。
- 产物：`iMusic-iOS-diagnostics-<version>-<build>.ipa`，**未签名**，
  从 Actions 的 Artifacts 下载后用你惯用的工具重签安装。
- 版本号与 build 号都取自 `ios/Config/Shared.xcconfig`（2.0.3 / 203），
  构建时会校验写进 Info.plist 的值，避免装到新包却分不清版本。

上游的 `ios-release.yml` / `ios-smoke.yml` 依赖自建 `xcode-27` runner 和 iOS 27
模拟器，在本 fork 中改为仅手动触发，避免自动跑出无关失败。

## 日志是怎么工作的

`DiagnosticLogger` 在 `didFinishLaunchingWithOptions` 第一行启动，用 `write(2)`
**实时**写入：

```
Documents/iMusicDiagnostics/session.log
```

`UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` 已开启，所以即使
App 闪退到打不开设置页，也能用「文件」App 直接取：

> 文件 App → 我的 iPhone → iMusic → iMusicDiagnostics → session.log

捕获能力：

- 会话开始 / 前后台 / 内存警告 / 启动各阶段 / 音源加载 / 播放解析 / 歌单导入。
- `NSSetUncaughtExceptionHandler` 捕获 Objective-C 异常（含调用栈）。
- `SIGABRT / SIGILL / SIGSEGV / SIGFPE / SIGBUS / SIGTRAP / SIGPIPE` 信号，
  在 handler 里只调用 async-signal-safe 的 `write(2)`，然后恢复默认动作重新
  抛出，让 iOS 仍然生成系统崩溃报告。
- 下次启动检测「上次会话未正常结束」，并主动弹窗提示导出日志。
- 写盘前对 token / cookie / 账号标识等做脱敏；单条日志截断到 4000 字符，
  单个文件超过 2 MB 自动轮转，最多保留 3 个归档。

应用内入口：**设置 → 诊断 → 查看 / 导出诊断日志**，可分享 `.txt`、复制到
剪贴板、另存到「文件」App，或清空后重新复现。

## 复现后请提供

1. 导出的 `iMusic-Diagnostics-*.txt`（或 `session.log` 原文）。
2. 如果系统里有 `.ips`：
   设置 → 隐私与安全性 → 分析与改进 → 分析数据 → 找 `iMusic-*`。
3. 简单描述：是「点开就退」还是「点某个按钮后退」，以及最后操作的名称。

日志里 `[FATAL] [crash]` 之前最后一条 `[INFO]/[WARN]/[ERROR]` 就是崩溃前最后
执行到的位置；配合系统 `.ips` 的异常类型（`EXC_BAD_ACCESS` / `EXC_CRASH` /
`0x8badf00d` watchdog / `EXC_BAD_INSTRUCTION`）即可定位。

## 验证边界

本仓库在 Windows 上开发，无法运行 `xcodebuild` 或真机测试。Swift 代码的编译
与运行验证以 GitHub Actions 的实际结果为准，不在本地声称通过。

## 2.1.1：插件是否生效、卡住不播放怎么查

### 先看结论

真机日志（2026-11-18 18:45 段）显示两件事：

1. `MusicFreePreload.js` 在 JavaScriptCore 里**解析失败**，所以 2.1.0 的插件
   运行时从未真正生效。原因是 `item.$(pluginPlatform) = ...` 对函数调用结果
   赋值：V8 只在执行时报错（`node --check` 放行），严格模式下 JavaScriptCore
   解析阶段就抛 `SyntaxError: Left side of assignment is not a reference.`。
2. 一首歌在所有候选音源上依次尝试，单次请求超时 20 秒且无整体上限，
   18:45:49 开始解析到 18:47:49 才出结果，中间**没有一行日志**，这就是
   「切歌后不播放了」。

### 怎么确认插件生效

设置 → 诊断 → **检测 MusicFree 插件**。这一版会真的调用插件的 `search`
（关键词「晴天」），并对第一条结果尝试 `getMediaSource`，输出形如：

```
喜马拉雅_C：✅ 接口 getLyric/getMediaSource/search，加载 42 ms，搜索 12 条，播放地址 OK
歌词网：✅ 接口 getLyric/search，加载 31 ms，搜索 8 条
WebDAV：❌ 加载失败（插件脚本执行失败：unsupported module 'webdav'）
```

- `✅ … 搜索 N 条` = 插件能跑通网络与解析。
- `播放地址 OK` = 插件能返回可播放 URL，聚合搜索里点它就能出声。
- `❌` 后面即为插件自身缺依赖或语法错误，与宿主无关。

日志里对应的 `[plugin]` 记录：

- `MusicFree 插件脚本已求值，等待上报接口` → 脚本已执行，等待 `init`。
- `MusicFree 插件就绪: <名字> 接口=[search,getMusicUrl]` → 能力表已上报。
- `MusicFree 插件未上报接口` / `插件初始化失败：…` → 真正的失败原因。

### 卡住不播放现在的行为

- 整首寻源共享 **20 秒预算**，单次请求 3–12 秒（按剩余预算收紧）。
- 每个候选都会写一条 `[play]` 日志，包含音源、平台、耗时、失败原因。
- 成功时写 `音乐地址来自 音源=… 平台=… 音质=… 耗时=… ms 总耗时=… ms`。
- 全部失败 → 自动切下一首；**连续 3 首**失败才暂停并提示检查音源/网络。
