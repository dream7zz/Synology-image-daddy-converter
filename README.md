# Synology Image Daddy Converter

给 Synology Photos 补缩略图的 macOS 桌面工具。

当 Synology Photos 无法为某个视频生成预览时，照片墙会显示空白占位图，只能点开等它加载整段转码。
这个工具在**本地**解码这些文件，生成三档缩略图（xl / m / sm），再通过 Photos 自己的接口写回 NAS——照片墙立刻有封面，不需要低码率转码副本。

```
┌─────────────────────────────┐
│  Synology Image Daddy       │
│  ┌──────────┬─────────────┐ │
│  │ 文件夹树  │  缩略图网格  │ │
│  │ ☑ 2024   │  [图] [图]   │ │
│  │ ☑ 2025   │  [图] [图]   │ │
│  └──────────┴─────────────┘ │
└─────────────────────────────┘
```

---

## 它解决什么问题

Synology Photos 对视频缩略图的处理依赖 NAS 自身的转码能力。遇到下面这些情况，NAS 会一直停在 `converting` 状态，照片墙永远是空白：

- 摄像机把 MPEG Program Stream 录成了 `.mp4` 扩展名（海康、大华等监控录像）
- HEVC / 10-bit 素材，NAS 没有可用的转码能力（如未激活 Advanced Media Extensions）
- 索引写在文件末尾（non-faststart）的 MP4，NAS 读取超时
- 录制中断、体积被截断的残缺文件

本工具不依赖 NAS 转码：**读取原文件中极少的一部分，在 Mac 上解码出一帧，把三张 JPEG 写回去。**

## 主要特性

| 特性 | 说明 |
|---|---|
| 多账号 | 密码存 macOS Keychain，不落盘 |
| 目录树勾选 | 只处理勾选的目录；网格严格跟随勾选范围 |
| 两阶段扫描 | 先发现目录，再读取文件，进度可见 |
| 分阶段进度 | 下载 / 抽帧 / 上传 三段独立显示 |
| 队列窗口 | 独立窗口，按阶段筛选、分页、显示失败原因 |
| 状态一致 | 「就绪」= NAS 三档齐全 **或** 本工具已写入成功 |
| 无效数据 | 0 字节或非图片且 < 512 KB 的文件单独归类，永不排队 |
| 生成清单 | 导出缩略图三档 JPEG，可批量复制路径 |

## 处理策略

不同封装用不同的读取方式，目标都是"只读能解码出一帧的最小数据量"：

| 文件类型 | 读取范围 | 典型耗时 |
|---|---|---|
| 普通 MP4 / MOV（索引在头部） | 索引 + 首帧样本，约 10–13 MB | 1–3 秒 |
| MP4（索引在尾部） | 尾部 2 MB 找 `moov` + 首帧样本，约 5–13 MB | 2–6 秒 |
| MPEG-PS / TS（改名的 .mp4） | **256 KB 前缀**，失败才升到 2 / 8 / 24 MB | 2–7 秒 |
| 照片（含 RAW：CR2/CR3/NEF/DNG…） | 原图，交给 ImageIO | 0.1–2 秒 |
| 空文件 / 截断文件 | 不处理，归入「无效数据」或「阻塞」 | — |

**大视频从不整文件读取**：16 GB 的文件同样只需要几 MB。

## 系统要求

- macOS 13 或更高
- Swift 6.x（Command Line Tools 即可，无需 Xcode）
- ffmpeg（`brew install ffmpeg`）——用于非 MP4 容器和 RAW 之外的抽帧
- 目标 NAS：DSM 7.x + Synology Photos，账号需具备照片读取与写入权限

## 构建

```bash
cd SIADesktop
swift build -c release
./scripts/make-app.sh            # 生成 dist/Synology Image Daddy Converter.app
```

`make-app.sh` 会打包成标准 `.app`（含图标与 Info.plist），可直接拖进「应用程序」。

命令行工具 `siactl` 提供诊断子命令：

```bash
export SIA_HOST=your-nas.local:5001
export SIA_ACCOUNT=your-account

.build/release/siactl folders                 # 列出根目录
.build/release/siactl thumbcheck --id 12345   # 检查某条目的三档状态
.build/release/siactl avframe --id 12345      # 用 AVFoundation 抽帧
.build/release/siactl tailtest --id 12345     # 尾部索引方案自检
.build/release/siactl prefixtest --id 12345   # 前缀解码方案自检
```

> 所有命令都必须显式提供 `--host/--account` 或环境变量，程序内没有任何硬编码的服务器地址。

## 使用流程

1. **添加账号**：填 NAS 地址（`host:5001`）、账号、密码；密码存入 Keychain
2. **勾选目录**：左侧目录树按需勾选，网格只显示勾选范围内的内容
3. **扫描所选**：两阶段进行（发现目录 → 读取文件）
4. **开始**：只处理「缺失」的条目；已就绪的会被跳过
5. **看队列**：独立窗口展示每个文件的下载 / 抽帧 / 上传进度与失败原因

「开始」不会重新扫描——扫描只在你点「扫描所选」时发生。

## 状态模型

每个条目只有两个事实来源：

```
NAS 的扫描结果   +   本工具的写入记录（done 清单）
```

判定规则只有一条：

```
就绪 = NAS 三档齐全  ∪  本工具已成功写入
```

| 条件 | 状态 | 是否处理 |
|---|---|---|
| NAS 三档齐全 | 就绪 | 跳过 |
| 本工具已写入 | 就绪 | 跳过 |
| 0 字节，或非图片且 < 512 KB | 无效数据 | 跳过，单独归类 |
| 以上都不是 | 缺失 | 处理 |
| NAS 侧卡在 `converting` | 阻塞 | 需人工介入 |
| 其他错误 | 失败 | 显示原因 |

处理每个文件前会发一个小请求向 NAS 确认，因此即使本地缓存过期也会自动纠正。

## 安全与隐私

- **不修改原文件**：只读取，不移动、不重命名、不删除
- **只写缩略图**：每个条目写入 xl/m/sm 三张 JPEG（约 730 KB）
- **密码**：保存在 macOS Keychain（service 名可配置），代码与磁盘配置中都不含明文
- **无遥测**：不向任何第三方服务器发送数据，所有请求只发往你填写的 NAS

## 已知限制

- **NAS 侧阻塞**：若 NAS 数据库把某个条目标记为 `converting`，上传接口会拒绝写入（错误 117）。这通常发生在源文件本身残缺时，客户端无法绕过，需要管理员重建索引或补传完整文件。
- **重建索引需要管理员**：普通账号调用 `Index.reindex` 会返回 105（无权限）。
- **不支持删除**：删除操作未实现（界面按钮默认禁用）。
- **仅面向 DSM 7.x**：接口基于 Synology Photos 的 `SYNO.FotoTeam.*` 命名空间逆向所得，DSM 版本差异可能导致行为变化。

## 目录结构

```
Sources/
  SIACore/            核心逻辑（无 UI 依赖，可单独测试）
    Scanner.swift       目录树与条目扫描
    Engine.swift        任务编排：下载 → 抽帧 → 上传
    NASClient.swift     登录、Cookie、Token、Range 请求
    Fetcher.swift       分块读取与容器嗅探
    VideoFrame.swift    AVFoundation 在线抽帧
    MP4TailIndex.swift  尾部索引定位与稀疏重组
    Thumbnailer.swift   ffmpeg 抽帧与三档缩放
    ImageThumbnailer.swift  ImageIO（含 RAW）
    WriteGate.swift     上传白名单与确认流程
    SettingsStore.swift 配置持久化
  SIAApp/             SwiftUI 界面
  siactl/             命令行诊断工具
  siatest/            自检程序
scripts/make-app.sh   打包 .app
assets/               应用图标
```

## 免责声明

本项目通过逆向 Synology Photos 的 Web 接口实现，与 Synology 官方无关。
使用前请自行确认账号权限与数据备份；对因使用本工具造成的任何数据问题不承担责任。
