# dmfix — 让暗黑地牢 1.3.0 在 A14~A16 设备上出画面

## 问题是什么

1.3.0 的 iOS 版在启动时检查 `MTLGPUFamilyMetal4`（只有 A17 Pro 及更新支持）。
iPhone 12 Pro 这类设备不满足，程序走 "classic only" 分支：`g_classic = 1`，
`mtl_present_ext()` 第一行就 `return 0`，于是**每一帧都被丢弃**——游戏在跑、
声音正常、存档能写，但屏幕上什么都没有。

## 这个补丁做什么

一个注入式 dylib，只做两件事：

1. hook `mtl_ext_tex` —— 记下 图层纹理序号 → MTLTexture
2. hook `mtl_present_ext` —— 拿到纹理后，用**程序自带的** `present_pipeline()` /
   `present_encode()` 把它画到 `CAMetalLayer` 上（缩放、黑边、比例都由原代码处理）

不改游戏逻辑、不改着色器、不动 romfs。A17 Pro 及以上设备本来走 Metal 4 路径，
完全不受影响（那两条路上不会调用被 hook 的函数）。

## 构建（GitHub Actions，不需要 Mac）

1. 登录 GitHub，新建一个仓库（Public 最省事，Actions 不计费）。
2. 仓库页面 → **Add file → Upload files**，上传两个文件：
   - `dmfix.m`
   - `.github/workflows/build.yml`（文件名直接输入这个路径，GitHub 会自动建目录）
3. 打开仓库的 **Actions** 标签 → 左侧 `build dmfix` → 右侧 **Run workflow** → 绿色按钮。
4. 约 2~3 分钟跑完，进入这次运行，页面底部 **Artifacts** 下载 `dmfix-dylib.zip`，
   解压得到 `dmfix.dylib`。

## 注入（Windows）

需要 `dmfix.dylib` + 你手上那个 `Dungeon1.ipa`。

### 方式一：azule（推荐）

1. 下载 https://github.com/alexal1/azule/releases 里的 exe，Windows 需先装 iTunes。
2. 打开 azule，选择 IPA，登录你的 Apple ID。
3. 在 dylib 区域添加 `dmfix.dylib`。
4. 直接 Install（bundle id 不用改）。

### 方式二：Sideloadly

1. 打开 IPA，把 `dmfix.dylib` 拖进 Sideloadly 的 **Tweaks/dylib** 区域。
2. 填 Apple ID，Start。

> 用哪个 Apple ID 都行，但**必须和上次装这个游戏用的是同一个**，否则覆盖安装会失败。
> 若必须换 ID，先备份存档（爱思助手 → 应用 → 沙盒 → Documents）。

## 预期结果

- 启动后黑屏约 1~3 秒（第一帧要编译一次呈现管线），然后出现画面。
- 之后 60fps 正常，触屏、音频、存档都正常。

## 没出画面怎么查

dylib 会写日志到 App 沙盒的 `Documents/dmfix.log`（爱思助手可导出），
同时输出到系统日志（Windows 上用 iTools 的「实时日志」或 `idevicesyslog | grep dmfix`）。

几种典型结果：

| 日志 | 含义 | 处理 |
|---|---|---|
| `symbols: ...` 全是 0x0 | 符号表被这个版本 strip 了 | 告诉我，需要改走别的注入点 |
| `other prologue, skipped` | 你装的不是 1.3.0 这个构建 | 告诉我是哪个版本 |
| `vm_protect rw failed` | 系统不允许改代码段 | 用 Sideloadly 签名（会带 get-task-allow），azule 可能不带 |
| `hooks installed` 但没有 `first frame` | 呈现函数没被调用 | 说明画面走的是别的路径，需要补 hook |
| `first frame ...` 但屏幕仍黑 | 画上去了但没显示 | 层尺寸/图层问题，把日志发我 |

## 风险说明

- 注入的 dylib 只改主程序两个函数的入口 16 字节，失败会记录并**跳过**（不改坏文件）。
- 该方案依赖「自签应用可以修改自己的 __TEXT 段」这一前提。带 `get-task-allow`
  的签名（Sideloadly 默认）通常成立；若不成立，日志会明确写出来，不会静默失败。
- 这是绕过性补丁，不是官方修复。作者一旦在 1.3.1 里修了 `g_classic` 分支，
  直接换新版即可，不需要这个 dylib。
