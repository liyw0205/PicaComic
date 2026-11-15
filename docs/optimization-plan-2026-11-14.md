# PicaComic 当前项目优化方案

日期：2026-11-15。历史发布基线：`bc485265`，当前正式发布版本：`4.2.48+4248`（tag `v4.2.48`）；版本提交 `8dbcb268` 已通过 master CI `43707094309`，tag workflow `43711132707` 已通过 Flutter/native curl/Android 门禁并发布 4 个 APK 与 `SHA256SUMS`。annotated tag `v4.2.47` 仍固定指向 `82793767`，保留为未发布历史；tag 不移动、不重写。上一轮已发布 A5、A7 和 A15；`v4.2.40` 已交付 A1、A2、A11 和 A16。本轮已补齐 A1 启动恢复授权边界、A2 导入结果契约、A6 上传同步祖先校验、A10 凭据安全边界、A11 下载删除幂等、A12 活动指标标签规范化、A13 图片收藏重复删除幂等、A14 自定义源落盘前体积门禁和更新路径归一化、A16 LoadingDialog 关闭竞态、A17 隔离导出指标、A18 迁移目标完整性校验和 A19 来源限流器重配置。`v4.2.41` 的 tag workflow 因导入测试 fixture 的 UTF-8 字节长度问题失败，已由 `d12a8339` 修正；该 tag 保留为失败历史，不移动或重写。`v4.2.39` 的首次 tag workflow 暴露了恢复重试 fixture 的 journal 覆盖问题，已在 `88133da3` 修正；`v4.2.42`、`v4.2.43` release workflow 均已通过；`v4.2.44` workflow `43646783070` 因来源限流器测试时序失败而保留为失败历史，测试修复提交为 `594e72c7`；`v4.2.45` workflow `43647311291` 和 `v4.2.46` workflow `43652289981` 均已通过并发布 APK；后续 Flutter/Android 行为回归以 tag workflow 为最终发布门禁。

## 1. 结论与评估边界

当前工作区已经落地旧数据迁移、启动阶段恢复、备份恢复事务、导入同步边界、缩略图解码、缓存/下载目录维护、PDF 导出、来源网络策略和 Flutter/依赖版本基线；下一轮应先在标准 Flutter/CI、设备和真实 WebDAV 环境完成专项回归，再推进图片内存和启动性能测量。现有框架可以继续使用，按实际问题拆分职责即可。

本方案面向维护者，重点核查启动与设置、迁移、备份恢复、WebDAV、阅读器、收藏历史、原生网络及 CI。依据当前源码、已有测试和本轮命令结果编写；未发现覆盖这些流程的独立产品 Spec，验收场景由当前实现反推。下文明确区分源码可确认的行为、尚需复现的风险和需要测量的性能收益。

本方案同时记录当前工作区已落地的能力、尚未完成的验收和后续优化，不把静态分析结果当作设备或远端服务验证。原有 [优化方案](optimization-plan-2026-11-13.md) 和 [历史审计](repository-audit-2026-11-13.md) 保留为历史材料，后续实施以本方案的基线为准。

### 已有能力与剩余工作

| 方向 | 当前代码已有实现 | 仍需处理 |
| --- | --- | --- |
| Cookie/账号迁移 | 完整枚举、作用域保留、回读验证、指纹/marker、备份后清理 | 专项测试已通过；仍需旧版覆盖升级和真实设备数据保留 |
| 设置持久化 | 串行写队列、临时文件替换、备份回读、schema 校验、搜索模式统一落盘；搜索历史、日志和通知/后台服务写入口已可等待 | 导入等待与错误传播，继续审计剩余页面生命周期入口 |
| WebDAV | 本机上传/下载串行化、不可变 revision、父版本图、SHA-256 回读、CAS 指针、冲突分支保留；上传前校验本地 heads 仍在远端 revision 图中；导入期间同步抑制与统计已接入 | 真实 WebDAV 的双客户端并发、ETag/无 ETag、旧客户端共存验收 |
| 数据恢复 | 独立临时目录、替换记录、异常回滚分支、启动恢复入口、快照/故障注入覆盖 | 标准 runner 的独立进程恢复、实际设备和被篡改 `allowedRoots` 的验收 |
| 阅读器 | 预加载代次、失败清标记、图片任务 owner、活动窗口/并发上限 | 全量测试、真实网络失败/取消和退出后任务归零 |
| 图片与下载 | 原始字节 LRU、坏图失效、缩略图解码、内存压力清理；下载记录删除幂等，图片收藏删除不为不存在行发布同步；`StreamImageProvider` 已把取消绑定到底层 source stream | 总内存预算、原生并发和固定设备性能基线；真实网络取消和退出后任务归零 |
| 工程验证 | Flutter 3.44.0、lockfile、analyzer baseline、本地 CI action、native curl 回归 | APK metadata、各 ABI/native curl/签名验收 |
| 状态与 I/O 生命周期 | StateController token/disposer、监听器清理、规则/漫画源异步原子写入、通知/下载/分享及收藏/历史 mutator 的 Future 边界收口；收藏导入清理失败保留源文件 | Flutter widget 回归、Windows 替换语义、进程终止和低速存储验收 |
| 缓存与下载目录维护 | 异步分批清理、容量统计、SHA-256 校验、staging 目录和可恢复迁移 journal；清理/迁移指标已接入 | 固定设备的性能、空间不足和跨平台中断恢复验收 |

以上“已有实现”表示源码中存在相应逻辑，不等同于设备、故障注入或远端服务验证。当前工作区含新增迁移、启动、数据库、阅读器和缩略图专项测试；测试文件数量不代表测试覆盖率，必须以本轮实际执行结果为准。

## 2. 优先级与投入

P1 为下一轮优先完成，P2 为数据流程稳定后推进，P3 为随业务修改逐步处理。优先级代表实施顺序。估算按一名熟悉 Flutter 的开发者计算，包含针对性回归，不包含服务等待、完整跨平台验收和历史数据收集；相关任务共享准备工作，不宜直接相加作为工期承诺。

| 编号 | 优化方向 | 优先级 | 预期收益 | 工作量 | 风险 |
| --- | --- | --- | --- | --- | --- |
| A1 | 备份快照与恢复完成性 | 已补齐缺失 backup 保护、回滚进度标记和启动/进程内 trusted root 边界，待独立进程验收 | 中断和恢复失败后数据仍一致 | 4-6 人日 | 高 |
| A2 | 异步落盘与导入同步边界 | 已补齐设置/数据写入等待、同步请求计数、导入抑制和显式导入结果契约，待真实同步验收 | 避免假成功、反向上传和局部状态外传 | 2-3 人日 | 中高 |
| A3 | 阅读器失败重试与任务释放 | 已落地，专项回归通过 | 修正失败预加载标记，减少无效工作 | 1-2 人日 | 中 |
| A4 | 旧数据迁移收尾 | 已落地，专项回归通过，待设备验收 | 保留旧账号与 Cookie 原有语义 | 1-2 人日 | 中 |
| A5 | 收藏/历史的数据正确性与查询 | 查询边界已落地，性能测量待完成 | 避免漏收藏和部分迁移，改善大数据查询 | 3-5 人日 | 中 |
| A6 | WebDAV 多设备版本协议 | 已实现，待真实 WebDAV 双客户端验收 | 避免同名覆盖和静默冲突 | 3-5 人日 | 高 |
| A7 | 图片内存与原生网络资源 | 缩略图、任务指标和 Android PSS 采样已落地，待设备测量 | 控制大图和并发任务的内存峰值 | 3-5 人日 | 中高 |
| A8 | 设置校验与可恢复启动 | 已落地，专项回归通过，待设备测量 | 降低坏配置影响，缩短首屏等待 | 2-4 人日 | 中 |
| A9 | 测试基线与可复现构建 | 基线已落地，native curl 已回归，待产物验收 | 让修复可回归、产物能力可核对 | 2-3 人日 | 低中 |
| A10 | 凭据安全迁移 | 已实现；持久化配置不再绕过 `SecretStore`，安全存储失败不会创建匿名 transport，待设备验收 | 避免安全存储失败时意外匿名同步 | 2-3 人日 | 高 |
| A11 | 下载任务存储与删除 | 已实现 JSON 快照恢复和删除幂等，待大规模设备验收 | 避免损坏快照和重复删除放大副作用 | 2-3 人日 | 中 |
| A12 | 日志与运行指标 | 已实现活动标签规范化和指标上限，待生命周期/脱敏验收 | 提升诊断可用性，避免敏感或无界标签 | 1-2 人日 | 中 |
| A13 | 图片收藏大列表 | 已实现 keyset 分页、搜索计数和删除幂等，待设备性能验收 | 降低大列表查询与重复同步成本 | 2-4 人日 | 中 |
| A14 | 漫画源契约与隔离 | 已实现契约校验和自定义源落盘前体积门禁，待来源 fixture 矩阵 | 限制坏源影响，避免超大源污染持久化 | 2-4 人日 | 中高 |
| A15 | StateController 生命周期与通知成本 | 已实现实例级清理、tag/id 重绑和 Widget 回归，待标准 runner 验收 | 避免监听器泄漏和无效通知 | 1-2 人日 | 中 |
| A16 | UI 异步 I/O 与原子文件写入 | 已收口主页剪贴板、更新检查、启动同步和设置写入，待跨平台故障验收 | 降低首帧阻塞和半写文件风险 | 2-3 人日 | 中 |
| A17 | PDF/分享流水线 | 已实现，隔离导出成功/取消/失败指标已回传主 isolate，`v4.2.46` 标准 Flutter runner 已通过 | 大文件导出不阻塞 UI，取消不破坏旧文件 | 2-4 人日 | 中 |
| A18 | 缓存与下载目录维护 | 已落地；提交 journal 恢复要求目标文件集合与 journal 精确一致，待设备和中断验收 | 降低维护阻塞，迁移可恢复 | 2-3 人日 | 中 |
| A19 | 来源网络策略 | 已实现并修复并发预算重配置时的排队请求保留，补充超时 fixture，`v4.2.46` 标准 Flutter runner 已通过，待设备网络验收 | 统一取消、限流、退避、熔断和错误分类 | 2-4 人日 | 中高 |

## 3. 具体方案

### A1. 补齐备份和恢复的完整生命周期

**当前状态：** 已加入独立工作目录、数据库/设置快照、恢复 journal、外部根校验、路径重叠和符号链接拒绝、提交失败回滚及启动恢复入口；恢复事务和故障注入测试已覆盖主要替换阶段。标准 Flutter runner、独立进程重启和真实设备数据仍需验收。

**依据与触发条件：**

- `lib/tools/io_tools.dart:311` 直接把正在使用的收藏、历史、Cookie 数据库加入归档，没有显式的一致性快照边界。后台写入期间的归档是否可完整恢复，需要验证。
- `lib/tools/io_tools.dart:425` 写入替换记录，`:433` 定义回滚；全仓引用显示回滚只由本次 `importData()` 调用，`lib/init.dart:36` 的启动流程没有扫描、重放未完成恢复的步骤。恢复中杀进程后，已有记录不会自动执行。
- `lib/tools/io_tools.dart:719` 开始合并收藏，`:721` 开始合并历史；回滚记录备份的是 `local_favorite_temp.db`、`history_temp.db` 等输入文件，没有覆盖实际被合并写入的 `local_favorite.db`、`history.db`。前一步成功、后一步失败时，不能只靠恢复临时文件撤销前面的数据库修改。
- 回滚失败后仍会进入临时目录清理，见 `lib/tools/io_tools.dart:688`、`:758`；记录位于临时目录内，可能失去后续恢复所需的记录。
- `lib/tools/io_tools.dart:541` 在应用层预检之前直接解压备份。EH 归档已有路径和符号链接检查，见 `lib/network/eh_network/archive_utils.dart:32`、`:44`，用户数据恢复入口尚未复用；不能据此断言底层 ZIP 插件存在可利用的目录穿越。

**实施：**

1. 导出使用 SQLite 一致性快照，先确认当前 `sqlite3` 绑定可用的 backup 能力；不能使用时短暂串行化写入并取得稳定副本。每次导出使用独立工作目录和输出文件，避免手动导出与 WebDAV 共用 `userdata.picadata`。
2. 新备份增加独立格式版本、文件清单、大小和 SHA-256。格式版本与当前 `settings[46]` 的同步修订分开，保持旧归档读取兼容。
3. 解压前检查路径、符号链接、文件数和总展开大小；解压后校验必需文件、JSON 字段及数据库 `quick_check`/表结构。通过后才停止使用当前数据并进入替换。
4. 将收藏、历史的合并先作用于工作副本，校验后再提交；恢复日志覆盖实际数据库、设置和目录的修改。跨文件操作使用明确阶段与备份，不假设多个文件能一次原子替换。
5. 日志放在稳定的数据目录，记录准备、替换、提交和清理阶段，原子更新并刷新写入。在 `App.init()` 后、读取设置和打开业务数据库前恢复未完成操作；只有确认提交成功或回滚完成才清理备份和日志。
6. 手动导入、导出、清空与自动同步共享数据维护入口。内部调用复用已持有的操作上下文，避免 WebDAV 恢复时重复获取同一把锁。

**验收：**在每个替换点、两次数据库合并之间、设置落盘和提交标记前后注入异常或终止子进程。重新启动后业务数据为完整旧状态或已验证的新状态；失败不会删除唯一的恢复证据。坏 JSON、坏数据库、缺文件、解压超限和空间不足不能先破坏现有数据。

**回退：**导出格式扩展与恢复执行分别提交；保留旧格式读取和恢复前快照。存在未完成恢复记录时，先完成恢复，再回退应用版本。

### A2. 让“导入完成”真正包含落盘成功

**当前状态：** 导入入口已改为可等待 Future，设置/数据库写入会传播错误；`DataMaintenance` 为导入提供串行上下文和同步抑制，收藏、历史和图片收藏导入不再逐条触发 WebDAV 上传，并提供请求计数。标准 runner 和双客户端远端 revision 仍需验收。

**依据与影响：**

- `lib/base.dart:387` 的 `readDataFromJson()` 返回 `bool`，在 `:410` 调用异步 `writeData(false)` 后立即返回；`waitForSettingsWrites()` 返回的是吞掉错误后的队列尾部，见 `:267`、`:276`。等待队列排空不能证明本次导入的所有持久化步骤成功，也不能等待尚未入队的后续写入。
- `lib/tools/io_tools.dart:719` 导入收藏会调用 `createFolder()`、`addComic()`，二者通过 `saveData()` 上传；历史导入的 `addHistory()` 也会上传。来源为 `lib/foundation/local_favorites.dart:400`、`:658`、`:716` 和 `lib/foundation/history.dart:208`、`:294`、`:328`。
- 因此，`writeData(false)` 已修复设置层面的同步透传，`DataMaintenance` 现已抑制收藏、历史和图片收藏在导入过程中的逐条上传并记录请求数；是否形成跨设备重复同步仍需双客户端复现，最终发布 revision 仍需远端验收。

**实施：**

1. 将导入应用设置的入口改为可等待的结果，逐项等待 SharedPreferences、设置文件和数据库提交；传播该次操作的异常。队列为后续任务吞错续接与调用方接收失败分开处理。
2. 为导入/迁移引入操作来源或批量上下文，业务数据层在该上下文内不逐条请求 WebDAV 上传。成功后根据用户的“恢复”或“同步合并”语义，决定不上传或只上传一次。
3. 将导入中的 `void async` 写操作变为可等待的批量操作，覆盖 `addComic()` 及其封面任务。数据库合并与可延迟的封面下载分开验收。
4. 本轮已将 `Appdata.writeFirstUse()`、`Appdata.writeHistory()`、`saveLog()`、通知发送/取消、后台任务注册/取消和图片分享改为 `Future<void>`；网络搜索链路等待写入，UI 回调显式 fire-and-forget。收藏导入在数据库提交后删除源文件失败时记录 warning 并保留源文件，避免 cleanup-only error 阻断启动。后续继续审计剩余页面生命周期入口，并让同步结果区分成功、无更新、版本跳过和失败。当前旧版本导入返回 `false` 会被统一重试逻辑当作失败，应明确处理。

**验收：**模拟设置文件写失败，导入返回失败且保留恢复快照；导入 1,000 条收藏/历史时，静默恢复的远端写次数为 0，需发布合并结果时为 1。自动同步跳过旧版本时文件和设置均不变化，也不重复下载同一份归档。

**回退：**维持用户入口和旧归档兼容；异步接口调整时一次更新全部调用点，不保留两套行为不一致的导入接口。

### A3. 修正预加载失败回调，再接入阅读任务生命周期

**当前状态：** 已加入 `ReaderImageController` 与 `ImageTaskScope`，预加载使用代次校验、固定活动窗口、并发上限和 owner 定向取消；失败回调会释放标记。阅读器专项及与预加载测试组合共 8 项已在统一 Flutter runner 通过；仍需用真实网络验证失败、取消、切章和退出交错。

**历史触发原因（已处理）：**旧实现先设置已请求标记，再依赖 `precacheImage(...).catchError(...)` 清除失败标记；Flutter 3.44.0 的失败路径通过 `onError` 传出，导致旧标记可能保留。当前实现已改为 controller 的失败回调和代次校验。

框架依据为 Flutter 3.44.0 的 [precacheImage 实现](https://github.com/flutter/flutter/blob/559ffa3f75/packages/flutter/lib/src/widgets/image.dart#L121)，尤其是失败回调中的正常完成逻辑。本轮已对照 framework revision 为 `559ffa3f75` 的本机 SDK；这是源码和 SDK 行为对照结论，尚未运行 Widget 复现。

**实施：**

1. 使用 `precacheImage` 的 `onError` 清除标记，保留 `preloadGeneration` 校验，避免旧章节错误回调修改新章节状态。
2. 给阅读器任务明确的 owner，预加载限制活动窗口和并发数；切章、跳页和退出时释放过期任务。复用 `ImageManager.withTaskOwner()` 和 `cancelTasksForOwner()`，不要另建全局任务系统。
3. 清理退出逻辑：当前 `lib/pages/reader/comic_reading_page.dart:251` 在后台没有下载时全局清任务，有下载时不清阅读任务。改为只释放当前阅读器所属任务。
4. 单页、双页、连续滚动分别核对图片索引和预加载起点，先固定窗口，测量后再决定是否按网络和阅读方向调整。

**验收：**同一位置触发 20 次不会重复加入活动队列；图片第一次失败、第二次成功时可以再次预加载；旧章节延迟失败不修改新章节；阅读器退出后对应任务归零，后台下载保持运行。分别统计调度次数与真实 HTTP 次数。

**回退：**失败回调修复单独提交；调度和 owner 接入另行提交，保留固定窗口作为基线。

### A4. 补齐旧账号和 Cookie 迁移边界

**当前状态：** `lib/tools/legacy_data_migration.dart` 已实现 Cookie v4 目录、`.index`/`.domains`、非根路径、host-only/domain、path、secure、httpOnly、expires/max-age 的读取；源指纹、完成 marker、回读验证和 `.legacy-v1-backup` 保留已接入。账号迁移改为目标写入和验证、marker/备份完成后才删除旧 SharedPreferences key。剩余工作是专项测试最终回归、升级覆盖和设备数据保留验收。

**历史触发原因（已处理）：**

- `lib/init.dart:303`、`:311`、`:317` 的 JM/EH/HT 账号迁移先删除旧账号入口，再等待目标 `saveData()`；与哔咔 `:300` 先保存再删除的顺序不同。目标保存失败时，下一次启动可能无法按原条件继续迁移。
- Cookie 迁移通过根路径 `loadForRequest()` 收集数据，见 `lib/init.dart:154`、`:164`、`:224`。该方式是否保留非根路径 Cookie，需要专门样本验证，回读采样集合不能证明已读取全部旧数据。
- `lib/init.dart:155`、`:225` 将没有 domain 的 Cookie 补为点域，而 `lib/network/cookie_jar.dart:31` 的约定是裸主机表示 host-only。迁移需保留原来的作用域，不能只验证目标库与被改写后的对象一致。

**实施：**统一为写入、验证、记录迁移版本后再清理旧入口；保留可重试备份。Cookie 迁移按旧存储结构完整枚举并保留 host-only、domain、path、secure、httpOnly、expires；损坏元数据或无法确认完整性时保留源目录并报告失败。

**验收：**仅旧 Cookie 目录、根/非根路径、host-only/点域、损坏索引、目标只读及重复启动均有固定样本；失败保留旧数据，重跑不扩大作用域、不漏记录。使用虚构账号和 Cookie。

**回退：**新迁移先保留源备份，不与同版本的立即清理绑定。

### A5. 先保证收藏/历史正确，再优化大数据查询

**当前状态：** 收藏/历史主键、参数绑定、事务迁移、稳定排序分页和搜索限制已落地；本轮统一历史关键词的 trim/lowercase 语义，并补充空白关键词分页回归。既有数据库正确性与 1,000/10,000/50,000 行性能专项共 20 项通过记录保留；真实设备主线程占用和更大数据集仍需测量。

**P1 正确性依据：**

- 收藏表主键为 `(target, type)`，但 `lib/foundation/local_favorites.dart:689` 的 `addComic()` 只按 `target` 查重。相同 target、不同来源类型的样本会被当作已存在；`comicExists()` 在 `:662` 则同时检查两个字段，规则不一致。
- `addComic()` 的查询、`lib/foundation/history.dart:358` 的删除等仍直接拼接值；带单引号的自定义 target 可导致 SQL 解析问题。文件夹名作为表名需要单独的标识符校验/转义，不能用值占位符处理。
- `lib/foundation/local_favorites.dart:344` 的建临时表、删旧表和回填未放在显式事务内；现已改为事务迁移，并在导入提交后单独清理源文件。清理失败只记录 warning、保留源文件，仍需设备权限和重复启动验收。

**实施：**统一主键判断，所有值使用参数绑定；迁移加事务、回读验证和版本标记，失败保留原件。收藏与历史恢复沿用 A1 的工作副本，不让局部迁移绕过整体恢复边界。

**P2 性能依据：**`HistoryManager.addHistory()` 每次调用 `updateCache()` 全表读取，见 `lib/foundation/history.dart:329`、`:370`；`HistoryPage` 初始化就加载全部记录，见 `lib/pages/history_page.dart:21`；收藏搜索按文件夹逐表查询且没有 SQL `LIMIT`，见 `lib/foundation/local_favorites.dart:918`。这是可确认的工作量增长路径，实际卡顿程度尚未测量。

**实施：**缓存按增删增量更新；历史按稳定排序分页，搜索下推并限制结果；先用 SQLite 查询计划和数据集确认索引收益。保留现有“每收藏夹一张表”结构完成这些改动，是否合并表或使用 FTS 由后续测量决定。

**验收：**相同 target 不同 type 均可收藏；单引号、中文及合法特殊字符可正确增删。任一步迁移失败后原表和原文件仍完整；用 1,000/10,000/50,000 条记录比较查询 p50/p95 和主线程占用，第一页读取不再扫描并构造全量对象。

**回退：**正确性修复和性能优化分开；索引、分页分别可回退，数据库结构变化保留迁移前快照。

### A6. 为多设备 WebDAV 建立冲突协议

**当前状态：** 已落地 `SyncRevision` 不可变归档、父版本图、SHA-256 回读、ETag/CAS 指针、设备身份持久化和多 head 冲突结果；旧数字归档仍可读取。`test/webdav_sync_test.dart` 已覆盖孤儿父版本、重复 parent、并发 head 和首次上传失败后的身份落盘。真实 WebDAV 服务端、双客户端并发和旧客户端共存仍需验收。

**依据：**`lib/network/webdav.dart:113` 使用秒级本地时间与本地上次版本生成文件名；上传前虽然读取目录，却不参与目标版本分配。两个设备可能选择相同文件名。`:119` 把同一天其他版本列入清理，缺少设备或父版本信息，不能证明被删除版本都已合并。本机 Future 队列不提供跨设备互斥。

**已实施：**

1. 新归档采用不可变唯一 ID，descriptor 记录设备 ID、父修订和 SHA-256；读取兼容旧数字文件名。
2. 服务端支持 ETag/条件写入时使用 CAS 指针；不支持或检测到多 head 时保留多分支并返回冲突，不按设备时钟判定胜负。
3. 完整上传、回读和 descriptor 校验后才提交本地版本；首次上传前持久化 device ID，失败重试仍归属同一设备。
4. 导入/冲突解析复用 A2 的同步抑制；选定设置版本最后应用，收藏和阅读进度按分支合并，未确认合并的归档不清理。

**剩余验收：**两个客户端在同一秒并发上传、时钟偏移、其中一个离线后恢复、上传中断及不支持 MOVE/ETag 的服务器均需重放；双方最后有效归档存在且冲突可观察。本轮尚未连接实际 WebDAV 服务器。

**回退：**先增加新版本读取与冲突识别，再切换写入；旧客户端共存期间暂停激进清理，并明确新旧协议写入兼容边界。

### A7. 测量并控制图片和原生网络的峰值资源

**当前状态：** 普通封面与自定义封面已使用按布局尺寸和 DPR 计算的 `cacheWidth/cacheHeight`；内存压力会清理原始字节 LRU、Flutter image cache 和 live images。图片任务已接入 `RuntimeMetrics`，记录活动数、并发峰值、取消和完成耗时；原生 curl 也记录活动数、并发峰值、取消/失败和响应字节。新增 Android `Debug.MemoryInfo` PSS/private dirty/native/dalvik 采样，并通过 `RuntimeMetrics.diagnosticSummaryWithMemory()` 提供显式诊断出口；阅读器原图路径保持不变。尚未有固定设备上的 RSS/PSS、首图 p95、取消延迟和原生并发基线，因此暂不承诺百分比收益。

**依据：**Flutter 解码缓存上限为 200 MiB，见 `lib/main.dart:161`；原始字节 LRU 平时为 50 MiB，进入阅读器升至 100 MiB，见 `lib/foundation/image_loader/base_image_provider.dart:120` 和 `lib/pages/reader/comic_reading_page.dart:217`。原生单响应上限为 64 MiB，且通过 JNI 完整返回字节；见 `android/app/src/main/cpp/pica_curl.c:79`、`:410`。这些不是进程总内存上限，不能相加作为 RSS。

`android/app/src/main/kotlin/com/github/pacalini/pica_comic/MainActivity.kt:26` 使用可增长的 `newCachedThreadPool()`，应用层没有在此设置原生活动请求总数上限。调用侧已有的局部并发限制不能代替跨来源的全局预算。

**实施：**

1. 采集相同设备上的 Dart heap、native heap、PSS/RSS、图片解码尺寸、活动请求数、缓存命中率、首图 p95 和帧耗时；覆盖普通页、长条图、大图和后台下载。
2. 为原生任务设置有界并发与等待队列；等待中取消、页面退出和 Activity 销毁均能释放资源，当前页请求优先。
3. 缩略图按显示尺寸解码，阅读原图保留放大质量；接入内存压力清理，分别评估原始字节缓存与解码缓存的收益。
4. 若测量确认桥接副本是主要峰值来源，再试点原生写临时文件或分块通道，复用缓存提交和取消清理；保留大小限制和 TLS 验证。

**验收：**固定图片集和并发数下对比峰值内存、首图 p95、取消延迟；连续进入/退出阅读器 10 轮，稳定后的存活对象和任务数不持续增长。预算由首轮基线确定，本方案不预先承诺降低百分比。

**回退：**缓存预算独立调整；新原生传输路径先小范围启用，保留旧路径用于对照。

### A8. 校验设置语义，让启动失败可处理

**当前状态：** `SettingsSchema` 已对关键枚举、范围和格式提供默认值/严格模式；启动已拆为可重试阶段，恢复失败显示 `StartupGate`，完成阶段不会重复执行，JS engine/ComicSource 初始化具备重试清理。启动专项已通过；剩余工作是设备上的冷启动 p50/p95 和核心/可选失败的真实初始化验证。

**历史触发原因（已处理）：**旧 `lib/base.dart:289` 只确认设置为非空字符串列表，未校验单个值的枚举、范围和格式；合法 JSON 中的非法数字/枚举仍可能进入运行界面。当前入口已接入 `SettingsSchema`，剩余风险集中在按索引读取的长期维护成本。

`lib/init.dart:91` 捕获初始化失败后仅记日志，`lib/main.dart:36` 等待返回后继续进入界面；同一启动路径还等待 JS 引擎、漫画源和多个管理器，缺少阶段耗时基线。

**实施：**

1. 先在持久化读取和导入入口为主题、阅读模式、布局、预加载数量、缓存大小等关键字段增加统一校验与默认值；错误主文件不能覆盖已知有效备份。
2. 沿现有 `_Settings` 增加具名字段，读取兼容旧数组；持久化引入明确 schema 版本。逐个模块迁移，避免全仓一次替换所有 `settings[index]`。
3. 初始化返回阶段结果，区分核心数据不可用和可延迟功能失败。核心失败进入可重试/恢复入口；不把部分初始化成功当作完整就绪。
4. 给路径、设置、恢复、数据库、JS、来源和翻译初始化记录耗时，再把不影响首屏的任务后移；各功能必须等待自身就绪，避免通过延后初始化引入新的竞态。

**验收：**空文件、坏 JSON、字符串合法但值越界、过短旧数组和备份恢复均可启动或给出明确恢复结果；核心初始化失败不产生后续连锁异常。在相同设备进行至少 30 次冷启动，比较首帧和可交互时间 p50/p95。

**回退：**字段校验、启动结果建模、性能调整分开提交；保留旧格式读取和已知有效备份。

### A9. 建立当前版本的验证与构建基线

**当前状态：** `.flutter-version` 固定 Flutter 3.44.0；Android/iOS/macOS/Linux workflow 使用本地 Flutter action 并启用 `--enforce-lockfile`；Git 依赖已固定 resolved commit；analyzer baseline 和 `tool/android_apk_metadata.sh` 已接入 Android workflow。仍需干净 runner 产出 metadata、实体设备和签名/ABI 验收。

**历史基线与现状：**

- 各平台 workflow 和 README 已统一到 Flutter 3.44.0；后续只需防止新 workflow 绕过 `.github/actions/setup-flutter`，并在 runner 上保留版本输出。
- `pubspec.lock` 已跟踪，Git 依赖已固定 resolved-ref，主要运行时依赖已补明确版本范围；后续升级仍应单独提交并检查 lockfile，不要把 lockfile 变化混入业务修复。
- `android/app/src/main/cpp/CMakeLists.txt:10` 仅为 arm64-v8a 链接 libcurl，而发布流程要求 arm64-v8a、armeabi-v7a、x86_64 和 universal 产物。其他 ABI 可以走回退路径，但需验证能力差异，不能只检查 APK 是否存在。
- `.github/workflows/android.yml` 已把 analyzer baseline、签名策略和 metadata 作为明确步骤；分析退出 0 不等于没有告警，缺少自定义签名时仍不能误报为正式发布成功。

**实施：**

1. 首先为 A1-A5 增加能捕获失败行为的回归。测试替换文件系统、WebDAV transport、时钟和图片 provider，保持离线可运行；杀进程恢复用独立子进程验证。
2. 使用统一的 Flutter 版本来源更新各 workflow 和开发说明；应用依赖继续提交 lockfile，CI 检查解析后锁文件无意外变化，Git 源尽量固定到已验证提交。
3. 将现有分析提示建立基线，新增 warning/error 阻断；弃用 API 随模块维护处理，逐步缩减提示。保留开发探针目录的独立统计，避免把探针输出计入产品缺陷数。
4. 已增加并接入 `tool/android_apk_metadata.sh`：从 APK/环境读取版本、提交、Flutter 版本、ABI、native curl capability、签名 SHA-256 和 APK SHA-256；缺少必需字段时让发布任务失败。
5. Android 至少验收 arm64 原生 curl 与一个回退 ABI 的代理、TLS、取消及下载；其他平台按改动影响安排构建。产物附上述 metadata。
6. 在干净标准 runner 上确认测试和构建，在设备上验证覆盖升级及数据保留。Termux 环境问题单独记录，不通过修改业务逻辑或 SDK hash 规避。

**验收：**同一提交的依赖和工具链可核对；新增关键失败回归能先失败后通过；APK 在对应 ABI 上的实际网络路径与记录一致；同签名旧版覆盖升级保留数据。当前没有新增本轮 CI、签名或设备通过记录。

**回退：**CI 收紧分阶段进行，先记录存量提示，再阻断增量；沿用当前签名选择，不生成替代发布密钥。

## 4. 实施顺序与交付拆分

| 批次 | 顺序与范围 | 交付条件 |
| --- | --- | --- |
| 0. 验证闸门 | 已确认 `sync_transport.dart` nullable `statusCode` 兼容性；迁移、启动、阅读器、缩略图、数据库和 analyzer baseline 专项回归已有上一轮记录 | 上一轮 48 项专项 Flutter 测试通过，native curl 6 项通过；本轮新增测试需在标准 runner 重跑，全量 runner 另有 147 项历史记录，平台产物仍单独验收 |
| 第一批：已落地能力收尾 | A3/A4/A7/A8 代码已落地，完成故障注入、旧版覆盖升级、真实网络失败/取消和固定设备内存/启动采样 | 失败场景可重放；旧数据保留；阅读器任务和内存不持续增长 |
| 第二批：恢复与同步一致性 | A1 工作副本/快照、恢复日志与启动重放；A2 导入等待、`void async` 持久化收口和同步抑制；A6 revision/CAS 第一版已完成 | 重启恢复、多设备并发和故障注入通过，导入不会假成功或逐条触发同步 |
| 第三批：查询与平台矩阵 | A5 查询分页/参数绑定、A7 原生并发预算、A8 冷启动测量；扩展 A9 APK metadata、ABI、签名和覆盖升级矩阵 | 同设备、同数据集的前后对比，正式产物可追溯且功能回归通过 |
| 第四批：安全与规模化运营 | A10 凭据安全迁移；A11 下载任务存储与删除幂等；A12 日志与运行指标；A13 图片收藏大列表与重复删除幂等；A14 漫画源契约和自定义源体积门禁 | 普通设置/日志无敏感值；任务可杀进程恢复；指标可查询；大列表和来源故障可控 |
| 第五批：导出、维护与网络治理 | A17/A18/A19 第一版实现已完成；剩余标准 runner、设备和来源 fixture 验收 | 大文件导出不阻塞 UI；维护任务可恢复且幂等；来源故障分类和退避可观测 |

模块整理放在相关任务中进行：从 `io_tools.dart` 收拢备份/恢复逻辑，从 WebDAV 静态入口分出可替换 transport；为设置持久化和阅读预加载建立可测试边界。`image_manager.dart`、设置页等大文件按实际职责拆分。暂不更换状态管理框架、重写所有漫画源、全面归一收藏表或批量升级全部依赖。

下一步推荐在标准 runner 完成 **A1/A11/A16/A18 的新增回归**，并做真实 WebDAV 双客户端验收；A2 继续进入导入失败传播和同步抑制的跨平台验收。涉及数据的主线先于性能和网络策略扩展。各项修改独立提交，验证失败回到该项最早不确定步骤，保留数据快照和失败样本。

## 5. 本轮验证记录

| 检查 | 本轮结果 | 能证明的范围 |
| --- | --- | --- |
| Git 与版本核对 | `v4.2.46` 已发布；独立提交 A1 `f847e95b`、A18 `6d3c4329`、A16 `d7fad813`、A10 `147f23c3`、A19 `1df99f86`、A17 `4b32939e`、测试时序修复 `594e72c7`，版本提交 `bc485265` 创建 annotated tag `v4.2.46`；Action runtime 更新为 checkout v7、setup-java v6、upload-artifact v7、download-artifact v8；`v4.2.44` tag 保留失败 workflow `43646783070`，`v4.2.45` workflow `43647311291` 和 `v4.2.46` workflow `43652289981` 均已通过；下一轮递增到 `4.2.47+4247` | 方案基线及本轮交付范围 |
| `flutter --version` | Flutter 3.44.0 / Dart 3.12.2 | 本机工具版本 |
| `flutter pub get` | 成功；新增 `flutter_secure_storage 9.2.4` 及平台实现并写入 lockfile | 依赖可解析；不替代各平台插件构建 |
| Analyzer baseline | `bash tool/check-analyzer-baseline.sh` 通过：errors=0/0、warnings=0/0；存量提示仍保留在 baseline | 新增 error/warning 被阻断；不替代设备构建 |
| 专项 Flutter 测试 | 8 个阅读器/预加载用例、11 个恢复、12 个数据库正确性、1 个数据库性能、16 个迁移/启动/缩略图用例，共 48 项通过 | 证明离线专项行为；不替代真实网络、设备和发布验收 |
| Native curl 回归 | `test/native_curl/executor.sh` 通过；`test/native_curl/run.sh` 通过 6 项 JNI 检查 | 覆盖本机 executor 与 JNI 回归；不替代各 ABI APK 验收 |
| 下载/WebDAV 定向分析 | `dart analyze` 目标源码与新增下载/WebDAV 测试无 error/warning；仅保留既有 info | 证明类型和接口可编译；不替代 Flutter runner 的行为测试 |
| A10/A17/A19 定向分析 | WebDAV 凭据、PDF 导出、来源网络策略及新增测试源码 `dart analyze` 无 issue；目标文件格式化和差异检查通过；Flutter 用例受本地 Termux Flutter kernel/`impellerc` 环境阻塞 | 证明安全边界、隔离指标、重配置队列和错误分类 API 可编译；行为仍需标准 Flutter runner、真实网络和设备验收 |
| A5/A7/A15/A19 定向分析 | `dart format`、目标 `dart analyze` 和 `git diff --check` 通过；新增内存结构校验、历史空白搜索、重复 tag/tag 重绑及超时/重配置 fixture | 证明本轮 Dart API、边界校验和测试代码可编译；Flutter runner、Android 编译和设备行为仍需 CI 验收 |
| A1/A2/A11/A16/A18 定向分析 | `dart format`、目标 `dart analyze` 和 `git diff --check` 通过；新增恢复进度/缺失备份、trusted root、导入落盘与结果契约、坏下载快照回退、页面异步边界和迁移目标集合回归 | 证明本轮 Dart API、恢复安全边界和测试代码可编译；Flutter runner、Android 编译、真实 WebDAV 和设备行为仍需 CI/设备验收 |
| A6/A11/A12/A13/A14 定向分析 | 各功能组独立执行 `dart format`、目标 `dart analyze` 和 `git diff --check`；覆盖上传同步祖先缺失、下载/图片收藏重复删除、活动指标标签规范化、自定义源归一化 UTF-8 体积门禁 | 证明本轮窄改动和离线边界测试可编译；Flutter runner、真实 WebDAV、来源 fixture 和设备性能仍需 CI/设备验收 |
| 异步边界扫描 | `lib/` 声明级扫描为 59 个 `void ... async`、184 个 `Future<void> ... async`、50 个同步 I/O 命中 | 仅用于跟踪入口数量；必须结合生命周期和错误传播审查 |
| 全量 Flutter 测试 | `v4.2.46` tag run `43652289981` 的 Flutter regression 全部通过；本地 Termux 仍受 Flutter kernel/`impellerc` 环境阻塞 | 标准 Linux/CI 已覆盖当前已发布版本离线 Flutter 测试集；本地环境不替代 CI |
| Android Gradle/Kotlin | `v4.2.46` tag run 已完成 Android APK 构建；本地 `:app:compileDebugKotlin` 仍受 Flutter kernel/Termux ELF 环境阻塞 | CI 已完成发布构建；本地不修改业务逻辑规避环境问题 |
| APK metadata 门禁 | `v4.2.46` tag run 已完成版本、ABI、metadata、native curl、签名校验、SHA-256 资产生成和 Release 上传 | 证明发布产物可追溯；设备安装和升级矩阵仍需单独验收 |
| 调用链与 SDK 对照 | 核对恢复日志调用点、导入上传链、数据库写入、`precacheImage` 和缩略图解码实现 | 支持文中的静态结论，不替代端到端复现 |
| 本方案文档检查 | 路径/行号核对、引用文件存在性、格式和空白检查 | 文档可追溯、格式完整 |

本轮 `v4.2.46` 已完成 APK metadata、签名产物、平台打包和远端 Actions Release 上传；真实 WebDAV、旧版覆盖升级、系统安全存储可用性和设备性能采样仍未完成。全量 Flutter 测试通过不替代这些平台和运行时验收；方案中的性能目标和风险后果均需按各项验收场景确认。

## 6. A10-A14：下一轮补充优化方向

以下方向不改变 A1-A9 的优先级，而是针对本轮审计发现的剩余工程风险。本轮已完成第一轮实现，下面同时记录实现边界和发布前仍需完成的验收；不要把静态实现误认为设备、远端服务或系统凭据验收已经完成。

| 方向 | 当前实现 | 仍需验收 |
| --- | --- | --- |
| A10 凭据隔离 | `SecretStore` 接口、`flutter_secure_storage` 平台适配、旧 WebDAV 配置迁移、普通导出脱敏、迁移失败回滚；持久化配置缺少安全存储时不创建 transport，不降级匿名 | Android Keystore、iOS Keychain、桌面后端和升级失败保留旧值的设备验收 |
| A11 下载队列 | JSON 快照版本标记、串行原子写入、`.tmp/.bak` 恢复、损坏任务保留、排序白名单；删除操作先完成目录操作再删除数据库记录 | 大规模任务性能；是否迁移 SQLite 需以设备测量决定 |
| A12 日志 | 串行写队列、按日期/大小滚动、保留历史、flush、写失败统计；`RuntimeMetrics` 已接入网络请求、文件下载和缓存/目录维护，并限制 bucket/sample 上限 | 真实生命周期 flush、长期日志权限和导出脱敏；同步结果和活动任务峰值仍需补齐 |
| A13 图片收藏 | keyset 分页、搜索/计数、增量刷新、缩略图和语义标签 | 1,000/10,000 张设备性能、动态字体和页面反复进出泄漏验收 |
| A14 漫画源 | 单源初始化隔离、自定义源归一化 UTF-8 体积上限、更新/新增入口统一落盘和失败记录 | 各来源 fixture 契约、限流/取消语义和发布矩阵 |

### A10. 将凭据与业务设置分离存储

当前普通用户导出默认不再包含 `cookies.db` 和 `comic_source`；只有 WebDAV
同步归档显式传入 `includeSensitive: true` 时才携带这些可复用登录态/源配置。
导入校验将 Cookie 数据库视为可选项，以兼容不含敏感数据的普通归档。

**现状与风险：**

- WebDAV URL、用户名、密码和路径目前拼接在 `appdata.settings[45]`，设置页直接写入该字符串，见 `lib/base.dart:86-90`、`lib/pages/settings/app_settings.dart:1101-1119`。
- 代理认证信息也由设置字符串解析，见 `lib/network/http_client.dart`；Cookie 数据库和导出的用户归档包含可复用的登录态。
- 网络请求日志已有字段级脱敏，但日志文件会写入 Android 外部存储，见 `lib/init.dart:90-101`；敏感数据一旦从其他调用链进入普通文本，仍可能被导出。

**实施：**

1. 建立 `SecretStore` 接口，使用 `flutter_secure_storage` 对接 Android Keystore、iOS/macOS Keychain 及支持的桌面后端；WebDAV/代理密码、账号 token 和 Cookie 密钥不再进入普通 settings JSON。没有系统安全存储时不能静默退回明文文件，应明确报告不可用。
2. 保留旧版本读取兼容：首次启动读取旧值，写入安全存储并回读验证，成功后只清理旧字段；失败保留旧字段和迁移 marker，不能因迁移失败丢失登录态。
3. 归档 manifest 将凭据标记为敏感条目，默认不导出密码和代理认证；恢复时提供“恢复登录态”选项，并对跨设备恢复给出明确提示。
4. 将日志改为统一结构化事件，字段白名单输出；对 URL query、请求头、Cookie、表单字段和异常文本做脱敏测试。日志文件放在应用私有目录，导出前再次过滤。

**验收：**旧版本升级、清除凭据、取消迁移、导出/恢复、代理认证和 Cookie 登录均可重放；普通设置文件、日志和用户可导出的文本中不存在密码、token、Cookie 值。安全存储不可用时功能明确降级且不覆盖旧值。

### A11. 把下载队列从 JSON 快照升级为可恢复任务存储

**本轮增量：** 在迁移到任务存储前，队列恢复会对候选快照执行完整任务解码和目录安全校验；较新的坏快照不会淘汰可恢复的 `.bak`，并保留损坏快照证据。非法任务类型、代次回退和 `.corrupt` 保留已有回归覆盖。

**现状与风险：**

- 下载队列每次图片完成都重新序列化整个 `newDownload.json`，见 `lib/network/download.dart:237-247`；写入没有临时文件、校验和版本 marker，进程终止时可能得到截断 JSON。
- 已下载数据库的排序字段和方向直接插入 SQL，见 `lib/network/download.dart:708-714`；当前调用方虽然使用固定选项，但数据层边界没有白名单保护。
- 队列、图片下载并发、通知和目录元数据分散在多个对象中，恢复后难以区分“已落盘”“正在下载”和“文件已存在但数据库未提交”。

**实施：**

1. 以 SQLite `download_task` 表保存任务、章节、图片进度、重试次数、错误类别、优先级和状态；启用 WAL，单张图片完成使用短事务更新，不再全量写 JSON。
2. 保留一次性 JSON 读取迁移，迁移后先校验全部任务，再原子提交版本号；旧文件保留为备份，恢复失败时不删除。
3. 任务状态使用 `queued/running/paused/failed/completed/cancelled`，启动时将 `running` 重置为 `queued`，根据文件存在性和大小重新核对进度。
4. 用固定列名映射替换 `ORDER BY $order $direction`，方向只接受 `ASC/DESC`；所有分页读取均有 `LIMIT/OFFSET` 或 keyset 边界。
5. 在下载管理器上提供全局并发预算和来源级限流，取消、暂停、切换下载目录时先完成状态提交再释放网络任务。

**验收：**在写入前、事务提交前后和下载目录移动期间终止进程，重启后任务不丢失、不重复下载已完整文件；1,000 个任务下启动和列表滚动不构造全部 JSON 对象。非法排序参数、坏任务记录和目录权限错误均被拒绝并保留原始数据。

### A12. 建立低成本、可查询的运行时可观测性

**现状与风险：**

- `LogManager` 的内存日志有限制，但文件追加是未等待的并发 `writeAsString`，见 `lib/foundation/log.dart:30-83`；高频网络/下载日志可能发生写入竞态或阻塞 UI。
- 启动阶段已有耗时记录，但网络、图片、同步和下载缺少统一的成功率、延迟、重试和取消指标，当前只能从文本日志事后判断。

**实施：**

1. 增加串行日志写队列、大小/日期滚动和崩溃前 flush；日志写失败只记录内存状态，不影响业务调用方。
2. 定义事件字段：操作名、来源、阶段、耗时、字节数、重试次数、取消原因、错误类别和匿名任务 ID；禁止写入 URL 敏感参数和正文。
3. 当前已增加 `RuntimeMetrics`：操作标签只接受结构化字符、每个操作最多保留 256 个耗时样本和 128 个 bucket，已记录网络请求、原生 curl、图片任务、文件下载、缓存清理和目录迁移的 p50/p95、成功/失败/取消、活动峰值和字节数摘要。默认关闭长期采集，用户主动导出时再生成。
4. 为关键指标增加离线 fake clock/fake transport 测试，确保取消、超时、重试和失败不会重复计数。

**验收：**并发写入 1,000 条事件后日志文件可解析且顺序稳定；达到滚动阈值后旧文件可清理；诊断摘要不含凭据且能与专项测试中的请求数、失败数对账。

### A13. 优化图片收藏和大列表的首屏、滚动与可访问性

**现状与风险：**

- 图片收藏页每次构建都调用 `ImageFavoriteManager.getAll()` 全表读取，见 `lib/pages/image_favorites.dart:42-80` 和 `lib/foundation/image_favorites.dart:60-68`；收藏规模增大后会同时构造全部模型和网格项。
- 全局 `StateController` 使用线性列表查找和手动 updater，见 `lib/foundation/state_controller.dart:15-95`；页面销毁与异步任务交错时，重复注册和无效刷新需要持续靠人工约束。

**本轮补充：** `_ImageProvider` 复用 `ImageFavorite.key` 作为缓存键，避免复合字段无分隔拼接导致不同收藏互相命中；边界回归覆盖已加入。

**实施：**

1. 为图片收藏增加稳定排序、keyset 分页和搜索索引，页面使用分页查询，只保留可见窗口附近的模型；删除/新增采用增量更新而非重新全表读取。
2. 对封面和图片卡片设置固定尺寸、`RepaintBoundary` 和明确的 cacheWidth/cacheHeight；测量首帧、首图和滚动帧耗时后再调整缓存预算。
3. 为 `StateController` 增加注册 token、一次性 disposer 和调试模式泄漏检测；异步回调统一检查 `mounted` 或通过生命周期 owner 取消。
4. 补齐键盘焦点、语义标签、动态字体和高对比度验收，避免只优化手机触控路径。

**验收：**使用 1,000/10,000 张图片收藏对比首帧 p95、滚动帧耗时、Dart heap 和 PSS；重复进入/退出页面 30 次后 controller、图片任务和监听器数量回到基线。搜索、删除和分页结果保持稳定。

### A14. 为漫画源建立契约测试和故障隔离

**现状与风险：**

- 内置漫画源和自定义源分布在多个网络实现与页面调用点，协议错误通常在页面层以通用文本展示；源站字段变化时难以区分解析回归、认证失败和限流。
- 当前测试以离线函数/样本为主，尚未形成每个来源统一的分页、详情、图片、登录和错误语义契约。

**本轮补充：** `ComicSourceContract` 已提供来源定义校验、分页/详情/图片 fixture 验证和稳定错误分类；同时拒绝空搜索/分类选项、缺失排行榜加载器及收藏 key 不一致等会导致页面崩溃的元数据。新增和更新自定义源统一 CRLF 归一化，并在写盘前按归一化 UTF-8 字节数执行 1 MiB 门禁，避免超大源先落盘后在 reload 阶段失败。各来源的真实脱敏 fixture 与设备网络验收仍待补齐。

**实施：**

1. 定义 `ComicSourceContract`：搜索分页、详情、章节、图片 URL、登录状态、收藏同步、限流/认证/解析错误和取消语义；各来源实现适配层。
2. 保存脱敏 HTML/JSON fixture 与版本化 golden 结果；CI 对每个来源运行离线契约测试，网络探测单独标记为可选任务。
3. 为来源加入能力和健康状态：短期失败使用指数退避和熔断，解析失败保留原始响应摘要，避免无限重试；单个来源失败不阻塞其他来源启动。
4. 自定义 JS 源限制执行时间、并发和响应体大小，按 source key 隔离缓存与 Cookie，提供禁用异常来源的恢复入口。

**验收：**fixture 字段变化、空分页、重复分页、429/403、超时、取消和错误 JSON 均有稳定错误类别；一个来源连续失败时其他来源仍可启动和浏览。新增来源必须先通过契约测试再进入发布矩阵。

## 7. A15-A16：已实现，待设备与跨平台验收

前述 A1-A14 已覆盖数据一致性、同步、缓存、来源和发布基线。本轮已从页面生命周期和 UI 线程占用补充并实现两项不宜与数据迁移混做的改造；下面保留依据、边界和验收要求，避免把静态代码检查误认为跨平台行为已验证。

### A15. 收紧 StateController 的生命周期与通知成本（P1）

**当前状态：** 已新增订阅 token/disposer；`StateBuilder.dispose` 会移除自身监听，控制器销毁时清空 updater，并在更新过程中跳过已注销监听。清理改为按具体 controller 实例执行，避免重复 tag 时误删其他实例；tag/id 更新会解绑并重新订阅，新增重复 tag 和 tag 重绑 Widget 回归。目标源码分析和差异检查已通过；标准 Flutter runner 仍需覆盖重复进出页面和自注销场景。

**历史触发原因（已处理）：**

- `lib/foundation/state_controller.dart:16` 用全局列表保存控制器，`find`/`findOrNull`/`findAll` 每次线性扫描；页面和标签增多后，通知与查找成本随全局对象数增长。
- `StateBuilder` 在 `:168` 向 `stateUpdaters` 追加闭包，`dispose()` 在 `:177-181` 只移除控制器，不移除该闭包。控制器被复用或 `autoRemove` 为 `false` 时，旧页面闭包会一直保留；闭包虽然检查 `mounted`，仍会增加内存和每次 `update()` 的遍历成本。
- 目前通过字符串/对象 tag 约定查找控制器，缺少重复注册、遗漏释放和异步回调越界的统一诊断。

**实施：**

1. 为每次订阅返回不可变 disposer/token，`StateBuilder.dispose` 按 token 移除监听；控制器销毁时清空所有 updater，并拒绝向已销毁控制器注册。
2. 保持现有 API 兼容，内部把控制器索引从列表改为“类型 + tag”辅助索引；对重复 tag、重复注册和未释放监听在 debug 构建记录计数，不在生产路径输出详细对象。
3. 为异步任务增加页面 owner 或生命周期 token，页面退出时统一取消；回调只更新仍有效的 owner，避免仅依赖 `mounted` 兜底。
4. 先改通知边界和诊断，再评估是否迁移到更完整的状态管理框架；不在此项中一次性重写页面。

**验收：**同一页面重复进入/退出 30 次后，控制器数、updater 数和活动任务数回到基线；1,000 个监听器更新时记录 p50/p95，通知耗时不随已销毁页面数量增长；重复 tag 和异步退出均有可诊断结果。

**回退：**保留现有列表实现作为兼容路径；token/disposer 与索引改造分开提交，出现页面刷新差异时可只回退索引层。

### A16. 清理 UI 线程同步 I/O 与不可等待异步边界（P2）

**当前状态：** 规则文件、漫画源新增/更新和解析写入已改为异步原子替换；相关页面的加载、保存、删除和设置持久化已改为可等待或显式 `unawaited`，主页剪贴板、更新检查、启动同步和错误日志边界也已收口，收藏/历史删除、标签编辑、阅读结束和清空操作也已收口。目标源码分析和差异检查已通过；Windows rename/备份回退、进程终止、低速存储和真实页面生命周期仍需验收。

**历史触发原因（已处理）：**

- `lib/pages/settings/network_setting.dart:141` 在页面初始化同步读取 `rule.json`，`:148` 在 `dispose` 同步写入；规则文件较大或存储较慢时会阻塞首帧和页面切换。
- `lib/pages/settings/comic_source_settings.dart:202` 在下载漫画源后直接写文件；`lib/tools/io_tools.dart:576`、`:596`、`:632` 等导入导出辅助仍有同步文件读写。
- 当前对 `lib/` 使用 `tool/check-async-boundary.sh` 扫描得到 59 个 `void ... async`、184 个 `Future<void> ... async` 和 50 个同步 I/O 命中（统计日期 2026-11-15）。下载子类的 `FavoriteDownloading.start` 已改为兼容入口 + 可观测 Future；EH archive 的 isolate 回调已捕获异步错误，但其 `start` 仍受基类兼容签名约束。Workmanager 的 `executeTask` 因插件 API 固定为 `void async` 也需保留直接调用。通知、后台服务、下载删除、设置、分享以及收藏/历史 mutator 相关边界已收口；剩余页面/手势入口仍可能无法等待、取消或接收异常，需继续按持久化、网络和生命周期风险排序。该数量应由 CI 扫描持续跟踪，而不是作为一次性完成标准。

**实施：**

1. 页面和设置文件统一使用异步读写、临时文件 + 原子替换，并在进入页面前加载状态；写入失败保留旧文件且向调用方返回结果。
2. 对 JSON/归档/大文本解析按大小选择 `compute`/isolate；主 isolate 只负责调度和状态更新，避免把大文件编码、压缩和解码放在帧间隙执行。
3. 优先将持久化、网络、下载和页面生命周期相关的 `void async` 改为 `Future<void>` 或显式 `unawaited`；所有 UI 回调在 `mounted`/owner 检查后更新，错误交给统一处理器。
4. 建立 lint/脚本扫描新增的 `void async` 和同步 I/O；允许启动恢复、事务替换等明确的后台/原子操作保留同步调用，并在代码旁标注边界。

**验收：**在低速存储和 5 MB/50 MB 文件样本下，设置页首帧与退出无可见阻塞；文件写入中终止进程后旧文件或完整新文件可恢复。对网络超时、取消、页面退出和写入失败注入测试，调用方能得到确定的结果且不产生未处理异常。

**回退：**先迁移规则文件和漫画源文件写入，再迁移通用导入导出；每类 I/O 保留旧实现的离线对照测试，避免同步改异步时改变用户可见顺序。

## 8. A17-A19：已实现，待设备与真实服务验收

这些项目不是当前数据一致性主线的前置条件，第一版实现已随 `v4.2.46` 通过标准 runner 和发布构建。下面保留实现边界、测试入口和设备/真实服务验收，避免把 CI 通过误认为所有运行时场景已经验证。

| 方向 | 代码依据 | 方案 | 优先级 |
| --- | --- | --- | --- |
| A17 PDF/分享流水线 | `lib/tools/pdf.dart` 已改为异步枚举/按页读取，支持取消、进度、隔离执行、原子替换和 `RuntimeMetrics`；隔离 isolate 的成功/取消/失败指标已在主 isolate 汇总；`pdf.save()` 受第三方 API 限制仍一次性编码 | 标准 runner 验证封面/章节语义、500/2,000 页、超大图片、取消响应、空间不足和最终文件可打开性 | P1（大图/长篇用户） |
| A18 缓存与下载目录维护 | 已接入 `directory_maintenance.dart`：异步分批清理、容量统计、SHA-256 校验、staging 目录和迁移 journal；`cache_auto_clear.dart` 已改为使用该维护入口 | 固定设备性能、剩余空间不足、进程中断恢复和跨平台目录替换验收 | P2 |
| A19 来源网络策略 | `SourceNetworkPolicy` 已接入 `AppHttpAdapter` 和 JS source 请求，提供每来源/host 并发、间隔、响应体上限、GET/HEAD 重试、429 退避、熔断、错误分类和诊断计数；非幂等请求不自动重放；动态重配置原地保留活动与等待队列；本轮补充 `TimeoutException` fixture | 为内置来源补脱敏 fixture，验证 429/403/超时/取消/错误 JSON；在真实网络下确认取消、代理和原生 curl 路径的一致性 | P1（网络错误频发时升 P0） |

### A17-A19 验收与交付

1. 使用 500 页、2,000 页和单页超大图片样本，比较 PDF 导出峰值 RSS/PSS、耗时、取消响应时间和最终文件可打开性；进程终止后不得留下误报完成的目标文件。
2. 在低速存储、剩余空间不足和迁移中断场景下，缓存清理与下载目录迁移都能重启继续或回到完整旧目录；清理任务不阻塞首帧，重复执行结果幂等。
3. 为每个内置来源准备脱敏 fixture，覆盖分页重复、空结果、429/403、超时、取消和错误 JSON；同一错误类别的重试次数和退避可观测，单源失败不阻塞其它来源。

A17 已复用 `AtomicFile`、`DataMaintenance` 和 `RuntimeMetrics`；A18 已复用这些边界，不要再创建独立的后台队列。A19 已在 transport 层落地，后续只需为来源补 fixture 和特定策略配置，避免页面层继续复制错误处理。

## 9. 本次复核后的收口清单

本次对当前工作区的复核没有发现需要推翻 A1-A19 架构的阻断项，但确认以下事项必须在发布前完成：

1. **凭据迁移回滚已补齐。** `Webdav.migrateLegacyConfig()` 现在会先读取旧安全存储值；普通设置落盘失败或安全存储写入中断时，恢复设置字符串和旧凭据。`test/secret_store_test.dart` 增加了设置路径不可写的故障注入用例。该用例已通过 `dart analyze`，Flutter runner 仍需在标准 Linux/CI 执行。
2. **安全存储不可用应失败闭环。** 当前启动将安全存储初始化设为非关键步骤，应用可以继续启动；但同步请求不能在凭据读取失败时意外按匿名凭据发送。设备验收时应确认 UI 明确显示“凭据不可用”，同步返回失败且不覆盖旧配置；如产品允许匿名 WebDAV，需要增加显式的匿名模式而不是依赖异常降级。
3. **导入与同步要做端到端计数。** 在导入 1,000 条收藏、历史和图片收藏的测试中，分别记录本地写次数、远端上传次数和最终 revision。静默恢复预期远端上传为 0，用户主动合并预期只产生 1 次发布；任何逐条上传都应作为回归失败。
4. **发布闸门已完成一轮验证。** `v4.2.46` 的标准 CI 已通过全量 Flutter 测试、各 ABI 构建、APK metadata、native curl、签名和 Release 上传；当前 Termux 仍受 Flutter kernel hash 与 `impellerc` ELF 环境阻塞，不能用业务代码规避，后续版本继续以标准 CI 为门禁。
5. **恢复 journal 的外部根需要绑定可信运行时配置。** 当前 `DataRestoreTransaction` 会把下载目录作为 `allowedRoots` 写入 journal，导入时会传入运行中的下载目录，因此正常导入路径已覆盖；但启动恢复发生在下载管理器初始化前，后续应让恢复入口从可信的当前下载配置取得外部根，并拒绝仅由 journal 新增或修改的根。需补充“篡改 `allowedRoots`”故障注入，确保不会借恢复日志操作 `App.dataPath` 之外的任意路径。

建议实施顺序调整为：先完成 A1/A2 的故障注入和真实 WebDAV 双设备验收，同时在标准 runner 验证 A15/A16；随后做 A5/A7 的设备性能采样，再将 A16 的剩余同步 I/O 扫描和 A10-A14 纳入发布矩阵。每项都保留可回滚的迁移快照和独立指标，避免一次性大范围重构。

## 10. 2026-11-15 增量交付与下一步

本轮在 `v4.2.46` 基线上继续拆分交付，每个功能组均独立提交并推送：

| 功能组 | 提交 | 交付内容 | 验证 |
| --- | --- | --- | --- |
| A5 查询一致性 | `2d79e088` | `HistoryManager.count({keyword})` 与分页使用同一套 trim/lowercase 过滤和参数绑定；历史搜索页显示过滤后的总数；增加关键词和空白搜索回归 | `dart format`、`dart analyze`、`flutter analyze`、`git diff --check`；标准 CI 随后被更新提交取消 |
| A6 WebDAV 冲突分支 | `a3d2a37d` | 共享远端夹具驱动真实 `Webdav.uploadData()`，覆盖旧 ETag 的 CAS 拒绝、immutable revision 保留，以及无 ETag 时 graph reread 暴露多 head | 本地格式/analyze/diff 检查；CI `43655226897` 全部通过 |
| A16 异步边界 | `558a9a54` | 页面加载/重试入口返回 `Future<void>`，UI 触发点显式 fire-and-forget，测试可直接等待操作完成 | 目标分析和异步边界扫描通过，标准 CI 已覆盖 |

远端门禁 `43655226897` 的 Flutter regression、native curl、Android APK 多 ABI 构建、metadata 和签名校验均成功。Termux 本机 Flutter 测试仍受 Kernel SDK hash mismatch 和部分环境缺少 `impellerc` 影响；该限制不替代标准 runner 结果，也不应通过修改业务代码规避。

下一阶段按以下顺序推进：

1. 在固定设备和 1,000/10,000/50,000 条数据集上测量 A5 查询 p50/p95、首屏和滚动内存，只有测量确认后再调整索引或缓存。
2. 用双客户端真实 WebDAV 重放同秒并发、时钟偏移、离线恢复、上传中断、ETag 和无 ETag 服务；记录最终 revision 图、冲突提示和旧客户端共存行为。
3. 为 A1/A2/A11/A16/A18 建立独立进程、低速存储和中断恢复 runner；重点确认导入失败不假成功、下载任务不丢失、目录迁移可重放。
4. A7/A10-A14 的设备、凭据安全存储和来源 fixture 验收完成后，先对当前 master 重新跑完整 CI；下一次递增版本（预计 `4.2.48+4248`）时再创建新的 annotated tag，现有 `v4.2.47` 保持不可变。tag 只指向已通过 CI 的版本提交。

## 11. 2026-11-15 后续缺口修复

在版本字段升级到 `4.2.47+4247`（`2412a7ae`）后，又完成三项独立修复并推送到 `205deebc`：

| 功能组 | 提交 | 修复内容 | 回归边界 |
| --- | --- | --- | --- |
| A11 下载队列 | `c7f07331` | 删除 `directory` 为空或缺失的旧任务时同步清理数据库孤儿行，重复删除保持幂等 | `test/download_persistence_test.dart` |
| A13 图片收藏 | `2539dfed` | 历史/收藏合并实际插入图片收藏后合并触发页面刷新；重复合并不产生无效刷新 | `test/image_favorites_pagination_test.dart` |
| A18 目录维护 | `205deebc` | 迁移计划、提交和 journal 恢复删除来源前校验完整文件集合、大小与 SHA-256；扫描后新增文件时保留来源和 journal | `test/directory_maintenance_test.dart` |

合并后的 `dart analyze`、目标 `flutter analyze`、`dart format`、analyzer baseline、异步边界扫描和 `git diff --check` 均通过。新增 Flutter 测试已尝试执行，但本机 Termux 的 Flutter SDK/kernel 不匹配，报 `Unexpected Kernel SDK Version 9811646114 (expected d684a576a6)`，因此不能宣称本地测试通过；应由标准 runner 重新执行。

`v4.2.47` 的版本提交曾未生成对应 run，现保留为未发布历史；平台恢复后已由 `v4.2.48` tag workflow 完成标准 CI、APK 和 Release 门禁。后续发布继续使用新版本和新 annotated tag，不覆盖历史 Release。

随后继续完成三项独立修复：

| 功能组 | 提交 | 修复内容 |
| --- | --- | --- |
| A18 缓存清理 | `19633f07` | 启动清理默认使用 `getApplicationCacheDirectory()`，与 `App.cachePath` 和图片缓存实际位置一致；保留目录 provider 注入测试 |
| A12 运行诊断 | `48375723` | 日志导出追加脱敏 `Diagnostics` JSON，包含日志写入失败状态和有界 `RuntimeMetrics` 摘要，不序列化错误文本/堆栈 |
| A10 凭据边界 | `3e7f8713` | 安全存储读取失败时 `configForSettings()` 返回空结果，阻断设置页把半配置转换为匿名 WebDAV one-shot 请求；显式匿名配置仍保留 |

这些提交均已推送至 `origin/master`，目标分析、格式和差异检查通过；版本提交 `8dbcb268` 的 master CI `43707094309` 和 `v4.2.48` tag workflow `43711132707` 均已完成。`v4.2.48` Release 已发布，`v4.2.47` 仍固定到 `82793767` 且不移动、不重写。

## 12. 2026-11-15 A7/A2 审计收口与提交/tag 工作流

### A7 图片源流取消传播

提交 `7ed8a7d7` 已独立推送到 `origin/master`。`StreamImageProvider` 现在覆盖 `loadWithCancellation`，用 `StreamIterator` 将 `ImageLoadCancellation` 绑定到 source stream；提交 `9e604dac` 再将取消与 `finally` 清理合并为幂等 future，避免交叠调用导致挂起。新增 `test/stream_image_provider_cancellation_test.dart` 验证取消会触发 source `onCancel`、返回 `ImageTaskCancelledException`，并覆盖重复取消、chunk 事件消费和异常 matcher 先注册的边界。

目标 `dart analyze`、`flutter analyze`、`dart format` 和 `git diff --check` 已通过。本机 Flutter 测试仍被既有 Kernel SDK mismatch 阻塞（`Unexpected Kernel SDK Version 9811646114 (expected d684a576a6)`）；标准 CI `43705424445` 已通过 293 项 Flutter 测试及 Android 构建，作为本次最终 runner 验收。

### A2 导入链定向审计

A2 本轮覆盖 `importDataResult`、`Appdata.readDataFromJson/writeData/updateSettings`、收藏/历史/图片收藏合并、`Webdav._importRevision` 和 `DataMaintenance` scope/计数。现有路径会等待本地事务提交，导入期间抑制逐条同步并透传错误；未发现可稳定复现且值得修改的源码缺口，因此不新增提交。仍需双客户端真实 WebDAV 和 1,000 条数据端到端计数验收，不能把静态审计当作远端同步证明。

### 提交、推送与 tag 规则

1. 每个功能组先独立完成目标分析、格式、差异和专项回归，再使用单一语义提交；提交后立即推送 `origin/master`，记录 commit 和本地验证结果。普通 master push 不触发 Android workflow。
2. Android workflow 仅由 `v*` tag push 执行完整发布门禁，另保留 pull request 和手动触发用于显式验证；正式发布必须由版本字段、annotated tag 和 tag commit 三者一致触发。tag 创建前先完成本地静态检查，tag workflow 再确认 Flutter regression、各 ABI、metadata、签名和 native curl 全部通过。
3. `v4.2.48` 已固定到 `8dbcb268` 并完成 Release；`v4.2.47` 已固定到 `82793767`，不得移动、重写或覆盖历史。
4. tag workflow 失败时保留失败历史和对应提交，修复用新提交/新版本递增；禁止通过强推 tag 或覆盖 Release 规避门禁。每次发布结束记录 workflow ID、APK SHA-256、证书摘要和 Release 状态。

## 13. 2026-11-15 A1/A17/A19 收口

### A1 恢复根边界审计

A1 本轮没有新增代码提交。`recoverPendingDataRestore` 会重新 canonicalize journal 中的外部根，并要求它们与启动时从严格校验的 settings、备份 settings、SharedPreferences 和默认下载目录得到的 `trustedAllowedRoots` 完全匹配；事务实例还保存不可变信任根，运行中修改 journal 不能扩大授权。现有 `test/data_restore_transaction_test.dart` 已覆盖篡改外部根、当前配置不匹配和符号链接替换。剩余是标准 Flutter runner、独立进程重启和真实设备验收，不把静态审计当作完成证明。

### A17 PDF 图片资源上界

提交 `1d397987` 将 PDF 页面图片改为延迟文件 provider：页面树只保留路径和尺寸，`Document.save()` 逐页读取并交给 `PdfImage`，避免长篇/大图把每页原始 bytes 同时保留到导出结束。提交 `045f81c7` 修正 EXIF 旋转图片的编码尺寸与显示尺寸边界，并在 `test/pdf_export_test.dart` 增加 orientation=6 JPEG 回归。取消、失败和原子替换语义保持不变；标准 runner 仍需执行 PDF 用例以及 500/2,000 页、超大图的 RSS/PSS 和取消延迟测量。

### A19 预租约取消诊断

提交 `38f10056` 修复来源限流队列和最小间隔等待在拿到 lease 前取消时的资源/指标边界：不再对不存在的 lease 解引用，取消请求会计入 `failures/cancelled`，但不会增加连续瞬态失败或打开熔断。新增队列取消和 pacing 取消 fixture；目标 `dart analyze`、`dart format`、analyzer baseline 和 `git diff --check` 通过，标准 CI `43705424445` 已完成 Flutter 与 native curl 回归。

## 14. 2026-11-15 缓存、图片收藏与提交触发收口

| 功能组 | 提交 | 修复内容 | 回归边界 |
| --- | --- | --- | --- |
| A18 缓存清理 | `889db606` | 启动时只在检测到旧版 `cache.json` 时执行一次迁移清理；新缓存不再在每次冷启动被无条件删除 | `test/directory_maintenance_test.dart` |
| A13 图片收藏 | `425678f6` | 检测最高 rowid 回退或空表并重置 keyset 分页水印，覆盖删除全部后重新插入的复用场景 | `test/image_favorites_pagination_test.dart` |
| A2/A6 WebDAV 上传边界 | `89d82a70` | 维护任务忙时 one-shot upload 排队等待维护 scope 释放，避免返回假成功并丢弃上传；增加忙碌状态回归 | `test/webdav_sync_test.dart` |

`.github/workflows/android.yml` 的 `push` 触发已收窄为 `v*` tag；普通 `master` 提交推送不再启动 Android workflow。`pull_request` 和 `workflow_dispatch` 仍保留，分别用于合并前验证和人工显式运行；正式发布只由版本字段、annotated tag 与 tag commit 一致的 tag workflow 门禁完成。此次修改不移动、不重写 `v4.2.47` 或 `v4.2.48`。

## 15. 2026-11-15 按方案继续开发

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A11 下载队列 | `22209575` | `DownloadManager.dispose()` 清空进行中任务后持久化空的 committed 快照，避免导入、重启或目录替换时旧任务复活 | `test/download_persistence_test.dart`；目标分析、格式和差异检查通过 |
| A12 运行诊断 | `baed6f0c` | 日志目标切换等待旧写入队列；Workmanager 后台 isolate 配置应用私有日志文件，并在任务结束时 flush | `test/log_manager_test.dart`；目标分析、格式和差异检查通过 |
| A16 阅读器异步边界 | `769f1a2a` | `ComicReadingPage.loadInfo` 暴露 `Future<void>`，构建入口显式 `unawaited`，generation 失效时旧章节响应不覆盖当前状态 | `test/reader_preload_test.dart`；异步扫描 `void_async=56`（基线 64） |
| A5 收藏查询性能 | `3349e9a8`, `b75a1f84` | 为每个收藏夹建立 `(display_order, target, type)` 复合索引，并确保运行时新建收藏夹同步创建索引，降低大列表稳定排序的临时 B-tree 和全表排序成本 | `test/database_correctness_test.dart` 的 `EXPLAIN QUERY PLAN` 回归；目标分析、格式和差异检查通过 |

上述新增 Flutter 用例已尝试在本机执行，但 Termux Flutter 编译器仍报 `Unexpected Kernel SDK Version 9811646114 (expected d684a576a6)`；这只能作为环境阻塞记录，不能替代标准 runner。下一步仍按方案执行 A1/A2/A6/A18 的独立进程、真实双客户端 WebDAV、设备性能和中断恢复验收。

## 16. 2026-11-15 异步边界与任务取消继续收口

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A16 身份验证生命周期 | `b94000e6` | `AuthPage.auth()` 改为可等待 Future，异常安全复位进行中状态，等待后检查 mounted，并移除生命周期 observer | 目标分析、格式、差异检查和异步扫描通过；平台认证控件仍需设备验收 |
| A7 图片任务取消 | `a8d4eb5d` | `ImageManager.clearTasks()` 增加 generation，使同 key 等待者在清理后取消而不是重新发起网络请求 | `test/jm_image_cache_test.dart`；目标分析、格式和差异检查通过 |
| A16 下载页异步入口 | `06989077` | 字体下载和 PDF 导出入口返回 Future；Dio 用户取消不显示失败提示，加载对话框在所有路径 finally 关闭 | `test/download_page_async_test.dart`；目标分析、格式和差异检查通过 |

异步边界扫描从基线 `64` 降至 `53` 个 `void async`（已包含阅读器章节加载、认证页和下载页修复），本轮未引入新的未等待持久化写入。剩余页面入口继续按数据写入、网络请求、取消和 mounted 风险排序，不一次性重写低风险回调。
