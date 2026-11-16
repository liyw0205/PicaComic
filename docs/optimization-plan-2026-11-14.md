# PicaComic 当前项目优化方案

日期：2026-11-16。历史发布基线：`bc485265`，当前正式发布版本：`4.2.51+4251`（tag `v4.2.51`）；版本提交 `353b1a5c` 已通过 tag workflow `43775549354` 的 Flutter/native curl/Android 门禁并发布 4 个 APK、`SHA256SUMS` 和 `apk-metadata.json`。annotated tag `v4.2.47` 仍固定指向 `82793767`，保留为未发布历史；tag 不移动、不重写。上一轮已发布 A5、A7 和 A15；`v4.2.40` 已交付 A1、A2、A11 和 A16。本轮已补齐 A1 启动恢复授权边界、A2 导入结果契约、A6 上传同步祖先校验、A10 凭据安全边界、A11 下载删除幂等、A12 活动指标标签规范化、A13 图片收藏重复删除幂等、A14 自定义源落盘前体积门禁和更新路径归一化、A16 LoadingDialog 关闭竞态、A17 隔离导出指标、A18 迁移目标完整性校验和 A19 来源限流器重配置。`v4.2.41` 的 tag workflow 因导入测试 fixture 的 UTF-8 字节长度问题失败，已由 `d12a8339` 修正；该 tag 保留为失败历史，不移动或重写。`v4.2.39` 的首次 tag workflow 暴露了恢复重试 fixture 的 journal 覆盖问题，已在 `88133da3` 修正；`v4.2.42`、`v4.2.43` release workflow 均已通过；`v4.2.44` workflow `43646783070` 因来源限流器测试时序失败而保留为失败历史，测试修复提交为 `594e72c7`；`v4.2.45` workflow `43647311291`、`v4.2.46` workflow `43652289981`、`v4.2.49` workflow `43763170198`、`v4.2.50` workflow `43772878266` 和 `v4.2.51` workflow `43775549354` 均已通过并发布 APK；后续 Flutter/Android 行为回归以 tag workflow 为最终发布门禁。

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

`android/app/src/main/kotlin/com/github/pacalini/pica_comic/MainActivity.kt:28` 当前使用 `NativeCurlExecutor(4, 64)`，原生请求已有活动数和等待队列上限；后续仍需用设备测量确认这组预算在不同网络和图片负载下是否合适。调用侧已有的局部并发限制不能代替跨来源的全局预算。

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

### 本轮测试流程优化（2026-11-16）

- 将未被 `flutter test` 自动发现、且与 `network_logging_test.dart` 重复的旧回归入口合并后删除；主测试补齐 Dio 响应体脱敏断言，行为覆盖不减少。
- 下载并发回归仍跨越 16 MiB 分块阈值，但 fixture 从 32 MiB+1 降为 16 MiB+1，保留两块并发调度验证，减少 CI 内存和写盘成本。
- 新增 `tool/run_flutter_tests.sh` 作为唯一 Flutter 测试入口，默认串行执行并启用 `--fail-fast`；可通过 `FLUTTER_TEST_CONCURRENCY` 显式调整。由于 `DownloadManager`、`appdata.settings` 和网络 override 仍有跨 suite 的进程级状态，tag 门禁保持串行，待隔离完成后再启用并发。Android tag workflow 仍执行全量 `flutter test` 集合，普通 `master` push 不触发该 workflow。
- 同领域 fixture 已合并到测试文件内部的 helper（下载 SQLite schema、队列任务、收藏项、WebDAV HTTP server 生命周期），不合并具有不同全局状态或持久化隔离语义的 `setUp`。

优化后的验证边界：并发只改变测试调度，不改变断言集合，但当前只作为显式实验参数；若出现全局状态串扰，先将 `FLUTTER_TEST_CONCURRENCY=1` 作为回退基线，再定位具体 suite。

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
4. A7/A10-A14 的设备、凭据安全存储和来源 fixture 验收完成后，先对当前 master 重新跑完整 CI；版本递增后推送与版本字段一致的 `v*` tag。tag 创建或更新都只发布仍指向本次构建 SHA 的 run。

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
2. Android workflow 仅由 `v*` tag push 自动执行完整发布门禁；普通分支 push 和 pull request 不触发，仍保留手动 `workflow_dispatch` 供明确需要时验证。正式发布要求版本字段、tag 名称和本次 tag commit 一致；tag 创建或更新都可触发，tag workflow 再确认 Flutter regression、各 ABI、metadata、签名和 native curl 全部通过。
3. `v4.2.48` 当前 Release 基线指向 `8dbcb268`；每次 `v*` tag 构建只要求该次 tag 解析到本次 `GITHUB_SHA`，允许同名 tag 更新后重新发布。
4. tag workflow 失败时保留失败 run 和对应提交；修复后可重新推送同名 tag，旧 run 会被取消，发布前的远端 SHA 校验会拒绝过期构建。已有 Release 的同名资产由 workflow 更新，避免旧资产与可变 tag 混用。每次发布结束记录 workflow ID、APK SHA-256、证书摘要和 Release 状态。

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

`.github/workflows/android.yml` 的自动触发已收窄为 `v*` tag push；普通 `master` 提交推送和 pull request 不再启动 Android workflow，`workflow_dispatch` 仅供人工显式运行。正式发布只由版本字段、tag 名称与本次 tag commit 一致的 tag workflow 门禁完成；同名 tag 更新会取消旧 run，并允许已有 Release 资产更新到当前构建。

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

## 17. 2026-11-15 导入契约与探索页并发收口

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A2 导入结果契约 | `9a7b62ca` | staging 目录创建失败统一返回 `DataImportResult.failed`；清理失败只记录 warning，不覆盖已完成或失败的导入结果 | `test/data_import_contract_test.dart`；目标分析、格式和差异检查通过；Flutter 测试仍受本机 Kernel SDK mismatch 阻塞 |
| A16 探索页异步边界 | `96cc9b84` | multipart 探索页增加请求中的互斥和 generation；refresh 后旧响应丢弃，避免 build 重复发起网络请求 | `test/explore_page_async_test.dart`；目标分析、格式、差异检查和异步扫描通过，`void_async=52` |

A1/A18 本轮继续完成源码和专项测试复核，没有发现比现有 journal、可信根、完整文件集合校验更可靠的新缺口；独立进程、真实 WebDAV 双客户端、设备性能和中断恢复仍是发布前验收，不以静态检查替代。

## 18. 2026-11-15 页面异步生命周期继续收口

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A16 收藏夹操作 | `0e5c3713` | 重命名和导出入口返回 `Future<void>`，菜单回调显式 `unawaited`；重命名完成后检查 controller 生命周期，导出对话框统一在 `finally` 关闭 | 目标分析、格式和差异检查通过；无可靠离线 UI fixture，底层重命名的持久化边界仍需单独收口 |
| A16 JM 评论分页 | `211fbf06` | loader 注入、首屏/分页互斥、retry/refresh/dispose generation 和旧响应丢弃，页面入口显式 `unawaited` | `test/jm_comments_page_async_test.dart` 5 项生命周期回归；目标分析、格式、差异检查和异步扫描通过 |
| A16/A17 阅读器图片操作 | `4c2023e4` | 分享/保存改为可等待 Future；图片读取后校验当前 controller、章节和 load generation，toolbar 显式 `unawaited` | 目标分析、格式和差异检查通过；真实图片流取消、设备相册/分享插件仍需标准 runner 与设备验收 |

本轮异步边界扫描从基线 `64` 降至 `45` 个 `void async`。剩余入口继续按持久化、网络请求、取消和生命周期风险排序；不为降低统计数量改写插件固定签名或纯同步回调。

## 19. 2026-11-15 收藏夹与阅读器生命周期继续收口

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A2/A13 收藏夹持久化 | `f1432dea`, `057e9a0a` | 收藏夹重命名等待 `saveData()`；维护任务期间返回排队 Future；对话框等待完成后再关闭并检查 mounted，错误可传播到 UI | `test/data_sync_boundary_test.dart` 覆盖维护排队、事务失败回滚和错误传播；目标分析、格式和差异检查通过 |
| A16 收藏阅读入口 | `febc04f1`, `c9b0ea11` | 更新收藏信息和阅读入口改为可等待；取消/异常统一关闭 loading；更新任务检查 mounted，重复阅读请求按漫画键合并并在完成后释放 | 目标分析、格式和差异检查通过；网络与导航耦合的 Widget 验收仍需标准 runner/设备 |
| A3/A16 阅读器手势与自动翻页 | `ff963522` | 双击/长按延迟回调绑定原 reader 并校验当前 controller；自动翻页改 generation 单循环，退出时失效旧任务，toolbar 显式 `unawaited` | 目标分析、格式、差异检查和异步扫描通过；真实触摸、图片流取消和设备生命周期仍需验收 |

本轮异步边界扫描从基线 `64` 降至 `40` 个 `void async`。`362ad032` 仅为 reader touch 控制文件的独立格式化提交，不改变行为。Flutter 测试仍被本机 `Unexpected Kernel SDK Version 9811646114 (expected d684a576a6)` 阻塞，不能替代标准 CI 和设备验收。

## 20. 2026-11-15 网络重试与提交触发收口

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A19/A16 网络异步边界 | `b0ac1314`, `1a570011` | Cloudflare 和 nhentai 登录完成回调保持幂等并在异常后释放互斥；鉴权 401 刷新共享进行中的 Future，避免并发重复刷新；Dio 错误重试仍回传原始错误 | `test/cloudflare_interceptor_test.dart`；目标分析、格式、差异检查和 analyzer baseline 通过 |
| A16 缩略图分页 | `1a570011` | 分页请求用 `finally` 复位 `isGetting`，网络异常后可再次请求同一页，不改变失败结果的传播语义 | `test/thumbnails_data_test.dart`；异步边界扫描 `void_async=34` |
| CI 触发门禁 | `f1f56774` | Android workflow 自动触发仅保留 `v*` tag push；普通分支 push 和 pull request 不触发，手动 `workflow_dispatch` 保留为显式验证入口 | `gh run list --commit HEAD` 为空；现有 `v4.2.47`、`v4.2.48` tag 未移动 |

本机 Flutter 测试仍受 Termux SDK/kernel 不匹配阻塞（`Unexpected Kernel SDK Version 9811646114 (expected d684a576a6)`），不能替代标准 runner。新提交均使用 `liyw0205 <2650115317@qq.com>`，未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak` 保护文件未纳入提交。

## 21. 2026-11-15 推荐页与同步清理继续收口

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A16 JM 每周推荐生命周期 | `f235c0e1` | 推荐分类和三类漫画 loader 可注入；同一分类请求互斥，retry/切换使用 generation 丢弃旧响应；dispose 后不再更新状态；空分类和异常进入可恢复错误态，页面入口显式 `unawaited` | `test/jm_week_recommendation_async_test.dart` 覆盖重复请求、旧响应丢弃和 dispose；目标分析、格式、差异检查通过 |
| A2 WebDAV 临时目录清理 | `f235c0e1` | 上传/下载临时目录改为异步清理并记录 warning；清理失败不覆盖已经完成的上传或导入结果，也不触发重复同步 | 目标分析、格式、差异检查和 analyzer baseline 通过；异步边界扫描 `void_async=29`、`sync_io=49` |
| A16 设置类型收窄 | `f235c0e1` | 设置网络操作使用显式 `Res` 类型，保持异步结果契约清晰 | 目标分析和 analyzer baseline 通过 |

本机专项 Flutter 测试仍因 Termux Flutter 编译器与 SDK/kernel 不匹配失败（`Unexpected Kernel SDK Version 9811646114 (expected d684a576a6)`），不能替代标准 runner；真实 WebDAV 双客户端、设备生命周期和中断恢复仍需发布前验收。普通 `master` push 不触发 Android workflow，`v*` tag 创建或更新均触发，旧 run 不得覆盖新构建。

## 22. 2026-11-16 来源页面异步边界继续收口

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A16 HTManga 详情页 | `34ecf23e`, `6c8849dc` | 阅读/缩略图历史写入改为可等待内部任务；详情请求和图片加载增加互斥、generation、dispose 与异常保护；导航后补充 mounted 检查 | 目标分析、格式、差异检查和异步扫描通过 |
| A16 Hitomi 首页/详情 | `7555cd29`, `2a7f38f7`, `d61fbc36`, `2ce905c4` | 首页首屏/分页请求互斥并丢弃旧响应；分页到达末尾不重复请求，brief 解析失败回滚游标和 ID；详情历史与导航异常记录并校验当前 controller | `test/hitomi_home_page_async_test.dart`；目标分析、格式、差异检查通过 |
| A16 nhentai 评论/详情 | `5f688827` | 评论页改为可注入 loader，首屏请求互斥、retry/dispose generation 和异常状态可恢复；详情阅读/缩略图入口等待历史并校验页面仍有效 | `test/nhentai_comments_page_async_test.dart`；目标分析、格式、差异检查通过 |
| A16 EH 评论/画廊/登录 | `2ce905c4`, `d1a9b855`, `f89f1394` | 评论请求和投票动作统一异常安全；画廊历史、缩略图加载和导航增加生命周期保护；移动/桌面 WebView 登录防重复回调，Cookie 抓取/校验/清理和 UA 持久化均可等待 | 目标分析、格式、差异检查通过；登录目标文件 `void_async=0` |
| A16 PicACG/JM/通用详情 | `2ce905c4`, `3b45fbc1` | 推荐页 loader 注入、请求互斥和坏响应校验；阅读/章节入口改为 Future 内部任务并检查历史提交、controller 和 context；下载状态读取异常可记录并恢复 | `test/picacg_collections_async_test.dart`、目标分析、格式和差异检查通过 |
| A16 列表页选择器 | `1141bb2c` | 页码对话框增加重复触发锁、generation、dispose/context 守卫和异常处理，入口显式 `unawaited` | 目标分析、格式、差异检查和异步扫描通过 |

本轮全仓异步边界扫描为 `void_async=2`（基线 64）、`future_void_async=235`、同步 I/O 命中 49；剩余两个 `void async` 属于插件/固定回调边界，保留并在方案中持续跟踪。新增 Flutter 专项测试在本机仍受 Termux Kernel SDK mismatch（`9811646114` vs `d684a576a6`）阻塞，不能替代标准 runner；普通 `master` push 不触发 Android workflow，`v*` tag 创建或更新均触发。

## 23. 2026-11-16 恢复、WebDAV 与下载队列边界复核

本轮针对持久化和同步路径继续做可复现审计，确认并修复三处边界：

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A1 恢复事务 | `ac8919d1` | 恢复目标带尾部分隔符时先规范化路径，确保 `restore-new`/`restore-old` 产物位于目标旁侧，不会落入待替换目录内部 | `test/data_restore_transaction_test.dart`；目标分析、格式、差异检查通过 |
| A6 WebDAV 传输 | `d6b3339e` | transport 关闭异常不覆盖主操作结果；指针 GET 遇 405/501 时降级为无 ETag 的 revision graph 检测，兼容不支持指针方法的服务端 | `test/webdav_sync_test.dart`；目标分析、格式、analyzer baseline、差异检查通过 |
| A11 下载队列 | `650a4b12` | 下载根目录切换时清理静态目录缓存；拒绝数据库中含路径分隔符、`.`/`..` 或清洗后变化的目录，避免误删其他目录并保留坏记录重试 | `test/download_persistence_test.dart`；目标分析、格式、analyzer baseline、异步边界、差异检查通过 |

本机对应 Flutter 专项测试均被 Termux 环境的 Kernel SDK mismatch 阻塞（`Unexpected Kernel SDK Version 9811646114 (expected d684a576a6)`），不能宣称本地 Flutter runner 通过；需由标准 runner 重跑。三项提交作者均为 `liyw0205 <2650115317@qq.com>`，当前普通 `master` 提交只推送分支，不触发 Android workflow；`v4.2.47`、`v4.2.48` 未移动或重写。真实 WebDAV 双客户端、独立进程恢复和设备目录切换仍属于发布前验收。

## 24. 2026-11-16 下载生命周期、迁移 journal 与同步结果收口

本轮继续沿 A11/A18/A2 的可复现路径推进：

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A11 下载取消 | `c4257716`, `76a42a5b` | 重复取消按任务 identity 合并 Future，等待 stop 和队列快照写入；即使队列项已移除，按 id 的重复取消仍等待同一持久化操作 | `test/favorite_download_test.dart`；目标分析、格式、差异检查通过 |
| A11 下载生命周期 | `7a2b557d` | `updatePath`/`dispose` 使用生命周期 gate 串行化，取消请求不会在目录切换或销毁期间交错；dispose 不会对同一任务重复 stop | `test/favorite_download_test.dart`；目标分析、格式、差异检查通过 |
| A18 迁移 journal | `b88b2900`, `d4871601` | 严格校验 journal 类型、大小、摘要、完成标记、重复路径和总字节数；拒绝 staging/目标符号链接，并在 rename 后重新校验完整文件集合 | `test/directory_maintenance_test.dart`；目标分析、格式、差异检查通过 |
| A2 WebDAV 上传结果 | `0a63face` | 将 late coalesced upload 纳入同一个稳定 Future，调用方等待最终批次结果，错误也不会在微任务窗口中丢失或提前报告 | `lib/network/webdav.dart`、目标分析、格式、analyzer baseline、差异检查通过 |

本轮 A2 静态审计未发现导入逐条上传、同步抑制泄漏或错误吞掉的稳定缺口；`importDataResult(null)` 的文件选择器异常和真实双客户端远端计数仍需平台/服务 fixture 验收。对应 Flutter 测试在本机加载阶段仍受 Kernel SDK mismatch（`9811646114` vs `d684a576a6`）阻塞，不能替代标准 runner。普通 `master` push 与版本发布分开处理：`v*` tag 创建或更新均触发 Android workflow，旧 run 会在并发组中取消。

## 25. 2026-11-16 页面加载与评论请求生命周期继续收口

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A16 通用加载状态 | `3707c4bc`, `f86c8b7f` | `LoadingState` 使用请求 generation、异常归一化和 dispose 守卫；retry 不再让旧响应覆盖新状态，首帧微任务启动前也检查 mounted | `test/loading_state_async_test.dart` 覆盖页面销毁后迟到响应；目标 `dart/flutter analyze`、格式、baseline 和差异检查通过 |
| A16 Hitomi/EH 页面 | `3707c4bc` | 动态漫画卡片按 id 丢弃旧响应并提供失败重试；EH 归档下载和 Profile 请求增加互斥、generation、错误态和重试入口 | 目标分析、格式和差异检查通过；Flutter runner 受本机 Kernel SDK mismatch 阻塞 |
| A16 账号登录 | `51f42b3c` | 登录提交增加重复请求互斥、异常复位和页面生命周期检查，离开账号页后不再回写状态 | 目标分析、格式和差异检查通过 |
| A16 PicACG 评论/回复 | `634027b2`, `1d8c99c2` | 首屏和分页请求互斥，retry 会失效旧分页；评论发送等待刷新结果，异常、dispose 和代际变化不再回写 controller 或状态；旧分页 finally 不会清除新请求的锁 | 目标 `dart analyze`、格式、差异检查通过；需标准 Flutter runner 补充注入网络 fixture |
| A16 桌面窗口状态 | `634027b2` | 最大化状态查询使用 mounted 守卫和异常兜底，窗口销毁后不再调用 `setState` | 目标分析、格式和差异检查通过 |

普通 `master` 提交仍只推送分支，不触发 Android workflow；版本号、发布产物和标准 CI 准备完成后，推送名称与版本一致的 `v*` tag，让 tag workflow 执行发布门禁。同名 tag 后续更新也会触发新 run，已有 Release 资产按当前构建更新。

## 26. 2026-11-16 目录恢复、窗口轮询与 WebDAV 配置边界

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A18 目录维护 | `24c85697` | committed journal 在来源目录已被删除、目标文件集合完整时仍可重放并清理 journal；其他阶段仍要求来源存在，避免把缺失来源误判为成功 | `test/directory_maintenance_test.dart`；目标分析、格式、analyzer baseline 和差异检查通过 |
| A16 桌面窗口状态 | `3c6a8592` | 窗口布局轮询改为单飞异步循环，避免 100ms 定时器重叠调用窗口 API 和磁盘写入；仅成功写入后更新缓存，失败在下一轮重试 | 目标分析、格式、异步边界和差异检查通过；窗口插件仍需设备验收 |
| A2/A6 WebDAV 配置 | `46ea2cfe` | 区分默认设置未配置与显式一次性配置错误；显式 malformed upload/download 返回失败并记录 `SyncStatus.failed`，不会创建 transport 或静默成功 | `test/webdav_sync_test.dart`；目标分析、格式和差异检查通过；本机 Flutter 测试受 Kernel SDK mismatch 阻塞 |
| A5 图片收藏查询 | `b03dc1c3`, `73d8d3d8`, `a9eaac38`, `c1b75d5e` | 为图片收藏标题增加可选 FTS5 trigram external-content 索引和增删改触发器；长关键词使用 MATCH 缩小候选集后仍用原 `instr(lower(title), ?)` 精确过滤，短关键词和 FTS 不可用时回退旧查询；补齐 JOIN 后 keyset 游标限定、第二页回归和非 FTS 辅助表降级 fixture | `test/image_favorites_pagination_test.dart` 覆盖语义、EXPLAIN、初始化后写入/删除、分页和启动回退；目标分析、格式和差异检查通过；本机 Flutter 测试受 Kernel SDK mismatch 阻塞 |

上述提交均使用 `liyw0205 <2650115317@qq.com>` 并已推送 `origin/master`。本机 Flutter runner 仍报 `Unexpected Kernel SDK Version 9811646114 (expected d684a576a6)`，因此这些专项测试需由标准 runner 重跑。普通 `master` push 不触发 Android workflow；tag 名称与版本字段一致时，创建或更新 `v*` tag 都会触发发布门禁。

## 27. 2026-11-16 恢复校验清理与 WebDAV 本地状态一致性

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A1/A9 备份恢复 | `f2db7418`, `9107ffb7` | manifest、appdata 或 SQLite 完整性校验失败时删除派生解压目录，保留原始备份供重试；清理失败不遮蔽原始校验异常 | `test/data_restore_transaction_test.dart` 验证坏备份输出目录不残留；目标分析、baseline、格式、异步边界和差异检查通过 |
| A2/A6 WebDAV 上传 | `10a74a81` | 远端 revision 已发布但本地 sync state 写入失败时，回滚并持久化 `settings[46]`，避免磁盘 revision 声称已同步而本地 heads 未提交 | `test/webdav_sync_test.dart` 验证 upload 失败、远端 archive 保留且本地 settings revision 恢复；目标分析、baseline、格式、异步边界和差异检查通过 |

上述提交均使用 `liyw0205 <2650115317@qq.com>` 并已推送 `origin/master`。Flutter 测试仍受本机 Kernel SDK mismatch（`9811646114` vs `d684a576a6`）阻塞，需由标准 runner 重跑；真实双客户端 WebDAV、独立进程恢复和设备故障注入仍属于发布前验收。普通 `master` push 不触发 Android workflow；任意 `v*` tag 的创建或更新都会触发发布，workflow 只发布仍指向当前构建 SHA 的那一次结果。

本轮通过 `gh run list --workflow android.yml --commit HEAD` 复核当前普通提交没有新增 Android run；最近成功的自动发布仍对应历史 `v4.2.48` tag。该结果与 workflow 的 `push.tags: ['v*']` 和 `workflow_dispatch` 配置一致；同名 `v*` tag 更新时由并发取消和远端 SHA 校验保证只发布最新指向。

## 28. 2026-11-16 下载取消与阅读器图片回调继续收口

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A11 下载队列 | `6b05638a`, `c358cfee` | 取消任务先提交 durable queue snapshot；快照失败时按原位置恢复任务并保持暂停，非队头取消失败会停止当前队头；取消写盘期间不提前通知监听器，避免启动下一项造成状态竞态 | `test/favorite_download_test.dart` 覆盖备份文件故障、重试和队列恢复；目标分析、格式和差异检查通过 |
| A3/A16 阅读器图片 | `9410228d` | `ComicImage` 的 frame/chunk/error 回调增加 mounted 守卫；组件销毁后晚到 frame 释放 `ImageInfo`，避免 `setState after dispose` 和图像资源泄漏 | `test/reader_image_owner_test.dart` 增加晚到 error fixture；目标分析、格式和差异检查通过 |

本机 Flutter 定向测试仍被 Termux 的 Kernel SDK mismatch 阻塞（`9811646114` vs `d684a576a6`），不能替代标准 runner。本轮已递增到 `4.2.49+4249` 并发布 `v4.2.49`；若该 tag 后续需要修正指向，重新推送同名 tag 也会正常启动新 run，旧 run 不得覆盖新构建。

## 29. 2026-11-16 v4.2.49 发布收口

本轮修复图片收藏页在数据库关闭后收到延迟刷新通知的生命周期竞态：`HistoryManager` 暴露只读 `isOpen` 状态，页面在重载、分页和外部变更协调前确认数据库仍可用；widget fixture 在测试结束时主动卸载页面，避免关闭数据库后残留 controller 继续消费通知。该修复与翻译 fixture 初始化、重复删除测试的微任务等待一起进入 `6bb4e164`。

标准 tag workflow `43763170198` 已通过全部 Flutter 回归、native curl、版本/tag 校验、APK 构建、metadata、签名和 Release 发布；`v4.2.49^{}`、远端 `master` 与 `6bb4e164` 一致。普通 `master` push 未触发 Android workflow；后续仍按真实双客户端 WebDAV、独立进程恢复、设备目录中断和内存/启动基线推进，不能以静态检查替代这些验收。

## 30. 2026-11-16 测试流程优化与 v4.2.50 发布收口

本轮将重复测试收敛到统一入口：合并重复 fixture，删除未被 `flutter test` 自动发现且与现有网络日志回归重复的旧入口；下载并发 fixture 从 `32 MiB + 1` 降为跨越分块阈值的 `16 MiB + 1`，保留两块并发调度断言并减少 CI 内存、写盘和执行时间。新增 `tool/run_flutter_tests.sh` 统一执行全量 Flutter 测试，默认 `FLUTTER_TEST_CONCURRENCY=1` 并启用 `--fail-fast`；并发仅作为显式实验参数，避免 `DownloadManager`、`appdata.settings` 和网络 override 等进程级 singleton 在 suite 间互相污染。

本轮测试流程优化提交为 `2ea92f10`、`a3c19d39`、`1db21743`。标准 tag workflow `43772878266` 已通过 Flutter regression、native curl、版本/tag 校验、Android 多 ABI、metadata、签名检查和 Release publish，发布 `v4.2.50` 的 4 个 APK、`SHA256SUMS` 和 `apk-metadata.json`。普通 `master` push 仅推送分支，不触发 Android workflow；`v*` tag 创建或更新均可触发发布，workflow 只接受仍指向本次构建 SHA 的结果。Termux 本地 Flutter 测试仍受 `Unexpected Kernel SDK Version 9811646114`（期望 `d684a576a6`）阻塞，不能替代标准 CI；analyzer baseline、异步边界、格式化和 `git diff --check` 已通过。

## 31. 2026-11-16 A1/A18/A19 收口与 v4.2.51 发布

本轮按方案继续推进三项可复现边界：

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A1/A18 恢复可信根 | `3467480b` | 恢复路径检查先解析最近存在的祖先，拒绝 `dataPath` 内符号链接下的缺失目标；`replace`/`applied` 阶段的外部根缺失不再使用 lexical fallback，只有已核对的 `committed` journal 允许清理已删除外部根 | `test/data_restore_transaction_test.dart` 覆盖数据目录符号链接、提交前外部根删除和已提交清理；目标 `dart analyze`、baseline、异步边界、格式和差异检查通过 |
| A19 来源网络策略 | `0d384045` | 流式响应完整读取后才记录成功；响应体超限或读取异常计入失败并释放 lease，后续请求不会被错误占用的并发额度阻塞 | `test/source_network_policy_test.dart` 覆盖流式超限、失败计数和后续 lease；目标分析、baseline、异步边界、格式和差异检查通过 |

版本提交 `353b1a5c` 将版本递增到 `4.2.51+4251`，annotated tag `v4.2.51` 指向该提交。标准 workflow `43775549354` 的 build 用时约 9m27s、publish 约 16s，Flutter regression、native curl、版本/tag 校验、Android 多 ABI、metadata、签名和 Release publish 全部成功，发布 4 个 APK、`SHA256SUMS` 和 `apk-metadata.json`。普通 `master` push 仍不触发 Android workflow；tag 创建或更新才触发发布。Termux 本地 Flutter 测试继续受 Kernel SDK mismatch 阻塞，不能替代上述标准 CI。

## 32. 2026-11-16 A2/A16 异步契约收口与 v4.2.52 发布

本轮继续沿统一测试入口推进，新增回归均并入现有契约/生命周期 suite，避免为单个边界重复启动完整 Flutter 测试流程：

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A2 导入结果契约 | `ef9a3cdb` | 文件选择器返回空路径时明确返回 `DataImportResult.cancelled`，与已有导入成功/失败契约测试合并维护 | `test/data_import_contract_test.dart`；目标分析、analyzer baseline、异步边界、格式和差异检查通过 |
| A16 设置页生命周期 | `da5bbfd8` | 代理可用性/质量探测在配置、TCP 和 HTTP await 边界检查 `mounted`，结果先落局部变量再统一提交；WebDAV 设置等待配置后补 context 守卫 | `test/proxy_setting_dialog_async_test.dart` 覆盖对话框销毁后迟到配置；目标分析、analyzer baseline、异步边界、格式和差异检查通过 |

版本提交 `9413e53c` 将版本递增到 `4.2.52+4252`，annotated tag `v4.2.52` 指向该提交。标准 tag workflow `43777530632` 的 build 用时 13m23s、publish 用时 21s；Flutter regression、native curl、版本/tag 校验、Android 多 ABI、metadata、签名和 Release publish 全部成功。Release 已上传 `PicaComic-4.2.52.apk`、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。普通 `master` push 仍只推送分支，不触发 Android workflow；`v*` tag 创建或更新才触发发布，workflow 只接受仍指向本次构建 SHA 的结果。提交作者统一为 `liyw0205 <2650115317@qq.com>`。

标准 runner 已通过本轮新增测试；Termux 本地 Flutter runner 仍受 `Unexpected Kernel SDK Version 9811646114`（期望 `d684a576a6`）阻塞，不能替代 CI。工作区保留用户原有未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak`，未纳入提交。

## 33. 2026-11-16 A15/A17/A19 收口与 v4.2.53 发布

本轮继续按风险优先级推进，并将新增边界合并到已有 suite，避免为每个异常路径新增独立 runner：

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A15 StateController 生命周期 | `ff6cd424` | `putIfNotExists` 命中已有实例时释放未被其他 tag 注册的候选 controller；同实例和已有其他注册保持存活，避免重复构造造成资源泄漏 | `test/state_controller_test.dart` 新增候选释放、跨 tag 保活和同实例幂等回归；目标分析、baseline、异步边界、格式和差异检查通过 |
| A19 来源契约与脱敏 | `991bc622` | 统一识别 `RATE_LIMITED`、`FORBIDDEN`、`REQUEST_TIMEOUT`、`REQUEST_CANCELLED` 等结构化错误码；契约 violation 不回显原始 payload；重试/状态 fixture 合并覆盖 403、408、Retry-After 和退避上限 | `test/comic_source_contract_test.dart`、`test/source_network_policy_test.dart`；目标分析、格式和差异检查通过 |
| A17 PDF 资源上界 | `eae56369` | 普通/isolate 导出增加单图 128 MiB 编码字节和 100 MP 解码像素默认上限，读取前检查文件大小、解码后检查像素数，超限不替换旧 PDF | `test/pdf_export_test.dart` 合并覆盖取消后无临时文件、字节超限和像素超限；目标分析、baseline、异步边界、格式和差异检查通过 |

版本提交 `cf975029` 将版本递增到 `4.2.53+4253`，annotated tag `v4.2.53` 指向该提交。标准 tag workflow `43780343004` 的 build 用时 10m26s、publish 用时 13s；Flutter regression、native curl、版本/tag 校验、Android 多 ABI、metadata、签名和 Release publish 全部成功。Release 已上传 `PicaComic-4.2.53.apk`、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。普通 `master` push 仍只推送分支，不触发 Android workflow；`v*` tag 创建或更新才触发发布，workflow 只接受仍指向本次构建 SHA 的结果。提交作者统一为 `liyw0205 <2650115317@qq.com>`。

标准 runner 已通过本轮新增及合并后的全量测试；Termux 本地 Flutter runner 仍受 Kernel SDK/kernel 与 `impellerc` 环境不匹配阻塞，不能替代 CI。工作区继续保留用户原有未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak`，未纳入提交。

## 34. 2026-11-16 测试流程收敛、恢复边界与 v4.2.54 发布

本轮先压缩日常测试路径，再继续处理恢复和持久化边界，避免每个异常分支都启动一次独立 Flutter suite：

| 功能组 | 提交 | 修复/优化内容 | 回归/验证 |
| --- | --- | --- | --- |
| A10 WebDAV 凭据 | `ba546774` | 合并安全存储不可用的 legacy、匿名设置和设置页读取场景；保留显式一次性匿名配置的独立正向回归。`Webdav` 对安全存储写入/删除执行回读验证，迁移失败时保留 legacy 设置，缺失凭据时禁止匿名降级 | `test/secret_store_test.dart`；目标 Dart analyze、analyzer baseline、异步边界、格式和差异检查通过 |
| Flutter 测试入口 | `ba546774` | `tool/run_flutter_tests.sh` 默认仍串行、fail-fast、全量运行；新增 `FLUTTER_TEST_FILES` 去重筛选和 `FLUTTER_TEST_NAME` 过滤，日常只跑受影响 suite，tag 门禁不改变 | 定向参数校验通过；标准 tag runner 全量 Flutter regression 通过 |
| A1/A18 恢复可信根 | `52a5748e` | 恢复拒绝 `journal.json`/`.previous` 符号链接；目录迁移拒绝 journal 符号链接，避免外部控制面伪造 committed 状态触发源目录删除 | `test/data_restore_transaction_test.dart`、`test/directory_maintenance_test.dart`；标准 runner 通过 |
| A11 下载队列 | `52a5748e` | legacy 快照含非法 generation 时允许回退有效 `.bak`，并保留坏源文件为 `.corrupt` | `test/download_persistence_test.dart`；标准 runner 通过 |

版本提交 `65024f22` 将版本递增到 `4.2.54+4254`，annotated tag `v4.2.54` 指向该提交。标准 tag workflow `43782966404` 的 build 用时约 12m08s、publish 用时约 22s；Flutter regression、native curl、analyzer baseline、异步边界、版本/tag 校验、Android 多 ABI、metadata、签名和 Release publish 全部成功。Release 资产为 `PicaComic-4.2.54.apk`、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。

普通 `master` push 仍只推送分支，不触发 Android workflow；`v*` tag 创建或更新才触发发布，workflow 只接受仍指向本次构建 SHA 的结果。提交作者统一为 `liyw0205 <2650115317@qq.com>`。Termux 本地 Flutter runner 仍受 `Unexpected Kernel SDK Version 9811646114`（期望 `d684a576a6`）阻塞，不能替代标准 CI；用户原有未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak` 继续保留且未纳入提交。

## 35. 2026-11-16 下载生命周期 gate 与 v4.2.55 发布

继续处理 A11 下载目录切换期间的进程内竞态，并把三个入口合并到一个可控生命周期 fixture：

| 功能组 | 提交 | 修复内容 | 回归/验证 |
| --- | --- | --- | --- |
| A11 下载生命周期 | `91eb14a6` | `updatePath`/`dispose` 持有生命周期 gate；切换期间的新任务先暂存，`start()` 请求延后到新目录初始化后，`moveToFirst()` 等待迁移完成；销毁期间拒绝新增任务，内部暂停仍使用受控路径 | `test/favorite_download_test.dart` 单个 gate 用例合并覆盖延迟启动、延迟入队和延迟置顶；目标 analyze、baseline、异步边界、格式和差异检查通过 |

版本提交 `8220e877` 将版本递增到 `4.2.55+4255`，annotated tag `v4.2.55` 指向该提交。workflow `43785315346` 最终 rerun 成功，build 用时约 9m15s、publish 用时约 27s；Flutter regression、native curl、analyzer baseline、异步边界、版本/tag 校验、Android 多 ABI、metadata、签名和 Release publish 全部通过。Release 资产为 `PicaComic-4.2.55.apk`、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。首次尝试因 artifact 上传服务长时间无响应取消，未产生发布结果；同一 SHA/tag 的 rerun 完成并发布资产。

普通 `master` push 仍只推送分支，不触发 Android workflow；`v*` tag 创建或更新才触发发布，workflow 只接受仍指向本次构建 SHA 的结果。提交作者统一为 `liyw0205 <2650115317@qq.com>`。Termux 本地 Flutter runner 仍受 Kernel SDK mismatch 阻塞，不能替代标准 CI；用户原有未跟踪文件继续保留且未纳入提交。

## 36. 2026-11-16 来源 pacing 重配置与测试路径继续收敛

本轮把动态来源策略的 pacing 重配置边界并入现有 `test/source_network_policy_test.dart`，没有新增独立 Flutter suite：

| 功能组 | 提交 | 修复/优化内容 | 回归/验证 |
| --- | --- | --- | --- |
| A19 来源网络策略 | `048a7da1` | `SourceNetworkPolicy.configure()` 变更 `minInterval` 时同步更新下一次允许时间；增大间隔立即生效，缩短间隔保留已经承诺的旧间隔，不触碰活动 lease 和等待队列，避免动态预算绕过或重复延迟 | 单个来源策略 suite 合并覆盖升、降间隔重配置及取消/重新放行；目标 `dart analyze`、analyzer baseline、异步边界、格式和 `git diff --check` 通过 |
| 测试流程 | `048a7da1` | 新边界直接扩展已有 pacing/队列 fixture，日常可用 `FLUTTER_TEST_FILES` 定向执行；tag workflow 仍只运行一次完整串行 Flutter 回归，不降低发布覆盖，也不为每个异常分支重复启动 runner | 标准 tag workflow `43789031234` 负责最终全量门禁；本机 Termux 定向 runner 仍受 `impellerc` 缺失阻塞 |

版本提交 `83943454` 将版本递增到 `4.2.56+4256`，annotated tag `v4.2.56` 指向该提交。普通 `master` 提交已推送但不触发 Android workflow；仅创建或更新 `v*` tag 才触发发布，workflow 校验 tag、版本字段和本次构建 SHA 一致后发布。上述提交作者统一为 `liyw0205 <2650115317@qq.com>`。用户原有未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak` 继续保留且未纳入提交。

## 37. 2026-11-16 A7 native 响应预算与 v4.2.57 发布

本轮继续处理图片/来源网络的资源上界，并复用现有 native curl 回归，避免为 JNI 边界另起 Flutter 测试流程：

| 功能组 | 提交 | 修复/优化内容 | 回归/验证 |
| --- | --- | --- | --- |
| A7 图片与原生网络资源 | `7c6557cc` | 将来源 `maxResponseBytes` 传入 Dart native channel、Kotlin JNI 和 C 写回调；native 层在响应缓存超过来源预算时立即中断，保留 64 MiB 硬上限，并将超限映射为 `responseTooLarge`，避免先构造完整 C buffer/JNI `byte[]`/Dart bytes 再拒绝 | `test/native_curl/NativeCurl.java` 合并超限流式 fixture，native curl 回归由 6 项增至 7 项；`test/network_retry_test.dart` 验证预算参数和错误分类；目标分析、baseline、异步边界、格式和 `git diff --check` 通过 |
| 测试流程 | `7c6557cc` | A7 边界复用已有 native curl 与网络 retry suite；tag workflow 仍一次性执行完整串行 Flutter/native 门禁，不为每个平台边界重复启动 runner | 本机 native curl 7 项全部通过；标准 tag workflow `43791053238` 负责最终 Flutter、Android 和 Release 验收 |

版本提交 `71685412` 将版本递增到 `4.2.57+4257`，annotated tag `v4.2.57` 指向该提交。普通 `master` push 仍不触发 Android workflow；仅创建或更新 `v*` tag 才触发发布，workflow 校验 tag、版本字段与构建 SHA 一致。上述提交作者统一为 `liyw0205 <2650115317@qq.com>`。

## 38. 2026-11-16 测试性能门禁收敛、下载快照 symlink 防护与 v4.2.58 发布

本轮继续压缩日常测试耗时，同时保留发布门禁的完整证据，并补齐下载队列恢复的文件类型边界：

| 功能组 | 提交 | 修复/优化内容 | 回归/验证 |
| --- | --- | --- | --- |
| Flutter 测试流程 | `13b8921a` | 1k/10k/50k 数据库性能基准默认跳过，仅通过 `FLUTTER_TEST_PERFORMANCE=1` 显式开启；`tool/run_flutter_tests.sh` 校验参数并导出 `PICA_RUN_PERF_TESTS=1`，保留 `FLUTTER_TEST_FILES` 定向执行和全量功能回归 | 日常 runner 不重复执行 4 分钟诊断型基准；Android tag workflow 显式开启性能基准，发布覆盖不降低；本地参数校验、分析基线、异步边界、格式和差异检查通过 |
| A11 下载队列恢复 | `13b8921a` | `_readQueueSnapshot()` 使用 `followLinks: false`，只读取 regular file；`.bak`/`.tmp` symlink 不得从下载根之外导入有效 JSON，异常候选仍由现有恢复逻辑隔离为 `.corrupt.*` | `test/download_persistence_test.dart` 合并覆盖外部有效队列 symlink、队列不恢复、外部文件内容不变和链接隔离 |

版本提交 `cc45a2c9` 将版本递增到 `4.2.58+4258`，annotated tag `v4.2.58` 指向该提交。标准 tag workflow `43793949396` 的 build 用时 11m38s、publish 用时 14s；Flutter 全量回归（含显式性能基准）、native curl、analyzer baseline、异步边界、版本/tag 校验、Android 多 ABI、metadata、签名和 Release publish 全部成功。Release 已上传 `PicaComic-4.2.58.apk`、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。

普通 `master` push 仍只推送分支，不触发 Android workflow；只有 `v*` tag 创建或更新才触发发布。提交作者统一为 `liyw0205 <2650115317@qq.com>`。Termux 本地 Flutter 定向 runner 仍受 `impellerc` 缺失阻塞，不能替代标准 CI；用户原有未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak` 继续保留且未纳入提交。

## 39. 2026-11-16 图片收藏搜索去重与 v4.2.59 发布

本轮继续处理页面层重复查询，先收敛图片收藏搜索，不改动历史页和数据库查询语义：

| 功能组 | 提交 | 修复/优化内容 | 回归/验证 |
| --- | --- | --- | --- |
| A13 图片收藏搜索 | `bc72fc0a` | `_setKeyword` 增加 180ms debounce，连续输入只在停顿后执行一次 `count()+getPage()`；销毁和关闭搜索时取消定时器，避免迟到回调访问已释放页面 | `test/image_favorites_pagination_test.dart` 合并 widget 回归，验证输入期间保留旧结果、停顿后切换过滤结果；目标分析、analyzer baseline、异步边界、格式和差异检查通过 |

版本提交 `dfb04f58` 将版本递增到 `4.2.59+4259`，annotated tag `v4.2.59` 指向该提交。标准 tag workflow `43795930087` 的 build 用时 11m10s、publish 用时 21s；Flutter 全量回归、native curl、analyzer baseline、异步边界、版本/tag 校验、Android 多 ABI、metadata、签名和 Release publish 全部成功。Release 已上传 `PicaComic-4.2.59.apk`、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。

普通 `master` push 仍只推送分支，不触发 Android workflow；只有 `v*` tag 创建或更新才触发发布。提交作者统一为 `liyw0205 <2650115317@qq.com>`。Termux 本地 Flutter 定向 runner 仍受 `impellerc` 缺失阻塞，不能替代标准 CI；用户原有未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak` 继续保留且未纳入提交。

## 40. 2026-11-16 启动延后维护与 v4.2.60 发布

本轮继续优化首帧前的工作边界，同时避免把启动步骤并发化后引入迁移竞态：

| 功能组 | 提交 | 修复/优化内容 | 回归/验证 |
| --- | --- | --- | --- |
| A8 启动阶段 | `4d91f470` | `StartupStep` 增加显式 `deferUntilReady`；仅缓存清理允许在首帧后通过 `runDeferredStartup()` 执行。日志、凭据迁移、旧数据迁移、代理、后台任务和深链仍保持原有顺序；重复重试与延后调用共享 in-flight Future，不重复初始化 | `test/startup_test.dart` 合并覆盖延后任务不提前启动、首帧后执行、并发调用复用，以及非延后 optional 仍保持依赖顺序；目标分析、analyzer baseline、异步边界、格式和差异检查通过 |
| 测试流程 | `4d91f470` | 将启动延后语义直接并入既有启动 suite，避免新增独立 runner；本地可定向执行单个启动 suite，tag 门禁仍只执行一次完整串行 Flutter 回归并显式开启性能基准 | 标准 tag workflow `43799340358` 的 Flutter regression、native curl、版本/tag 校验全部通过 |

版本提交 `af8bd3b9` 将版本递增到 `4.2.60+4260`，annotated tag `v4.2.60` 指向该提交。标准 workflow build 从 03:37:55 至 03:50:56，约 13m01s；publish 成功。Release 已上传 `PicaComic-4.2.60.apk`、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。

普通 `master` push 仍只推送分支，不触发 Android workflow；只有 `v*` tag 创建或更新才触发发布。提交作者统一为 `liyw0205 <2650115317@qq.com>`。Termux 本地 Flutter 定向 runner 仍因缺少 `impellerc` 无法执行，不能替代标准 CI；用户原有未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak` 继续保留且未纳入提交。

## 41. 2026-11-16 历史搜索去重与 v4.2.61 发布

本轮将页面层重复查询继续收敛到统一的输入节流路径，并控制回归成本：

| 功能组 | 提交 | 修复/优化内容 | 回归/验证 |
| --- | --- | --- | --- |
| A13 历史搜索 | `2862bd69` | 输入增加 180ms debounce；搜索模式下不再执行不展示的 `count()`；debounce 期间阻止旧关键词分页，切换搜索、清空和销毁统一取消定时器，保留原有小写关键词语义 | 目标 `dart analyze`、analyzer baseline、异步边界、格式和差异检查通过；不新增网络图片 widget suite，避免重复启动和外部请求拖慢测试 |
| 测试流程 | `764125bb` | 排查 tag runner 卡测后移除高成本网络绑定 widget 回归，保留现有历史数据库 fixture；最终 tag runner 只执行一次完整串行 Flutter 门禁，避免为页面输入边界重复启动独立 runner | 标准 tag workflow `43806494156`：Flutter regression 1m21s、native curl、版本/tag 校验全部通过 |

版本提交 `38d257c0` 将版本递增到 `4.2.61+4261`；为修复测试 fixture 卡测，`v4.2.61` 最终移动到 `764125bb`，workflow `43801646138`、`43803217956`、`43804225706` 均按并发策略取消，最终 workflow `43806494156` 成功。最终 build 约 9m30s、publish 约 17s；Release 已上传 `PicaComic-4.2.61.apk`、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。

普通 `master` push 仍只推送分支，不触发 Android workflow；只有 `v*` tag 创建或更新才触发发布。提交作者统一为 `liyw0205 <2650115317@qq.com>`。Termux 本地 Flutter 定向 runner 仍因缺少 `impellerc` 无法执行，不能替代标准 CI；用户原有未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak` 继续保留且未纳入提交。

## 42. 2026-11-16 回归入口合并与 v4.2.62 发布收口

本轮继续压缩测试维护和手工执行成本，把未被 `flutter test` 自动发现的旧回归入口并入现有标准 suite：

| 功能组 | 提交 | 修复/优化内容 | 回归/验证 |
| --- | --- | --- | --- |
| 测试流程 | `7f782c99` | 删除 `download_progress_regression.dart`、`eh_archive_page_count_regression.dart`、`eh_archive_utils_regression.dart` 和 `eh_image_response_regression.dart`；下载进度断言并入 `test/download_image_task_test.dart`，归档路径、页数、图片字节和 EH 响应流断言并入 `test/eh_archive_symlink_test.dart`，不新增 runner | 同一 Flutter suite 统一发现和执行，避免维护未发现的 `main()` 入口；下载器、缓存和字节缓存既有 wrapper 保持不变，行为覆盖不减少 |
| 测试门禁 | `7f782c99` | 保持 `tool/run_flutter_tests.sh` 的串行、fail-fast、定向筛选和 tag 性能开关；新增断言只增加到既有 suite，日常不重复启动进程 | 目标 `dart analyze`、analyzer baseline、异步边界、格式和 `git diff --check` 通过；本地 Flutter runner 仍受 Termux 缺少 `impellerc` 阻塞，待标准 tag workflow 完成最终回归 |

版本提交 `7f782c99` 将版本递增到 `4.2.62+4262`；文档收口提交为 `a7f2b4d0`，annotated tag `v4.2.62` 已指向该提交。标准 workflow `43811172395` build 用时约 9m35s、publish 用时 17s，Flutter regression、native curl、版本/tag 校验、Android 多 ABI、metadata、签名和 Release publish 全部成功；Release 已上传通用 APK、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。普通 `master` push 仍不触发 Android workflow，只有 `v*` tag 创建或更新才触发发布。提交作者统一为 `liyw0205 <2650115317@qq.com>`；用户原有未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak` 继续保留且未纳入提交。

## 43. 2026-11-16 测试 suite 去重与 v4.2.63 发布收口

本轮继续压缩日常测试的重复启动成本，同时保持 tag workflow 的全量回归门禁：

| 功能组 | 提交 | 修复/优化内容 | 回归/验证 |
| --- | --- | --- | --- |
| 图片生命周期测试 | `7684acfb` | 将 `stream_image_provider_cancellation_test.dart`、`image_task_owner_test.dart` 的两个纯 stream 用例并入 `reader_image_owner_test.dart`；断言和测试名保持不变，减少两个独立 Flutter suite | 合并 suite 目标 `dart analyze` 通过；标准 tag runner 仍全量发现并执行 |
| 数据备份测试 | `7684acfb` | 将单用例 `data_backup_copy_test.dart` 并入已有 `data_restore_transaction_test.dart`，统一 A1 备份/恢复 fixture，减少一个独立 suite | 合并 suite 目标 `dart analyze` 通过；不减少备份复制覆盖 |
| 测试 runner | `7684acfb` | `tool/run_flutter_tests.sh` 对显式参数和 `FLUTTER_TEST_FILES` 使用同一去重集合，避免同一 `test/*.dart` 被传入两次；tag 全量调用路径不变 | `bash -n`、显式参数与环境参数重叠追踪、非法路径返回码和 analyzer baseline、异步边界、格式、差异检查通过 |

版本提交 `7684acfb` 将版本递增到 `4.2.63+4263`；annotated tag `v4.2.63` 指向文档提交 `79d6f207`。标准 workflow `43815160601` build 用时 12m29s、publish 用时 15s，Flutter regression 通过 381 tests，native curl、版本/tag 校验、Android 多 ABI、metadata、签名和 Release publish 全部成功；Release 已上传通用 APK、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。普通 `master` push 仍只推送分支，不触发 Android workflow，只有 `v*` tag 创建或更新才触发发布。提交作者统一为 `liyw0205 <2650115317@qq.com>`；用户原有未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak` 继续保留且不纳入提交。Termux 本地 Flutter 定向 runner 仍因缺少 `impellerc` 无法执行，标准 tag workflow 已完成最终回归。
版本提交 `7684acfb` 将版本递增到 `4.2.63+4263`；annotated tag `v4.2.63` 指向文档提交 `79d6f207`。标准 workflow `43815160601` build 用时 12m29s、publish 用时 15s，Flutter regression 通过 381 tests，native curl、版本/tag 校验、Android 多 ABI、metadata、签名和 Release publish 全部成功；Release 已上传通用 APK、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。普通 `master` push 仍只推送分支，不触发 Android workflow，只有 `v*` tag 创建或更新才触发发布。提交作者统一为 `liyw0205 <2650115317@qq.com>`；用户原有未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak` 继续保留且不纳入提交。Termux 本地 Flutter 定向 runner 仍因缺少 `impellerc` 无法执行，标准 tag workflow 已完成最终回归。

## 44. 2026-11-16 恢复与分页生命周期收口、测试 suite 继续合并

本轮按 A1/A15/A16 方案修复跨平台恢复和迟到异步响应边界，并继续把同域小用例合并到已有 suite：

| 功能组 | 提交 | 修复/优化内容 | 回归/验证 |
| --- | --- | --- | --- |
| A1 备份 manifest | `f5520f9b` | 生成 manifest 时先把相对路径统一为 `/`，再排除 `backup-manifest.json`；修复 Windows 路径分隔符导致 manifest 自包含、后续恢复文件数量校验失败的问题 | `test/data_restore_transaction_test.dart` 验证正常文件和嵌套文件被列出且 manifest 不列自身；目标分析、格式、baseline、异步边界和差异检查通过 |
| A16 漫画分页生命周期 | `f5520f9b` | `ComicsPageLogic.dispose()` 递增 generation 并清除 loading 状态；dispose 后迟到的分页响应不再修改 comics/current | `test/comics_page_logic_test.dart` 使用 Completer 覆盖迟到响应；目标分析通过，Flutter 定向 runner 受本机 Kernel SDK mismatch 阻塞 |
| A15 状态更新契约 | `f5520f9b` | 在既有 StateController suite 增加 `update(ids)` 过滤回归，验证只通知匹配 id 的监听器 | `test/state_controller_test.dart`；目标分析、baseline、异步边界、格式和差异检查通过 |
| 测试流程 | `f5520f9b`, `222ec65c` | 搜索语言纯函数并入 `search_result_language_test.dart`，LoadingDialog 用例并入 `loading_state_async_test.dart`；页面 fixture 收进 group，避免污染纯函数测试；删除两个独立 suite 入口 | 测试数量保持不变、减少两个 Flutter suite 启动；目标分析和格式检查通过，tag 门禁仍全量串行执行 |

版本提交 `f5520f9b` 将版本递增到 `4.2.64+4264`；annotated tag `v4.2.64` 指向文档提交 `e8e981bd`。标准 workflow `43819467270` build 用时 12m15s、publish 用时 17s，Flutter regression 通过 384 tests，native curl、版本/tag 校验、Android 多 ABI、metadata、签名和 Release publish 全部成功；Release 已上传通用 APK、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。普通 `master` push 仍只推送分支，不触发 Android workflow，只有 `v*` tag 创建或更新才触发发布。提交作者统一为 `liyw0205 <2650115317@qq.com>`；用户原有未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak` 继续保留且不纳入提交。Termux 本地 Flutter 定向 runner 仍受 Kernel SDK mismatch 阻塞，标准 tag workflow 已完成最终回归。

## 45. 2026-11-16 网络收藏夹生命周期与测试入口继续收敛

本轮继续处理页面卸载期间的异步回调，并把低成本、同域测试合并到现有 suite，减少重复启动 Flutter 测试进程：

| 功能组 | 提交 | 修复/优化内容 | 回归/验证 |
| --- | --- | --- | --- |
| 网络收藏夹生命周期 | `6fbecca8` | `_MultiFolderFavoritesPageState` 抽取带 `mounted` 检查的 `_reloadFolders()`，删除收藏夹和创建收藏夹完成后的刷新回调统一经过该入口；页面卸载后迟到响应不再调用 `setState` | `test/network_favorite_page_async_test.dart` 复用现有 widget suite，以 Completer 覆盖删除请求挂起、页面卸载、请求完成；目标分析和格式检查通过 |
| 测试流程 | `6fbecca8`、`8c3b01ea` | 删除空的 `test/widget_test.dart`；将缩略图尺寸断言并入 `test/thumbnails_data_test.dart`；将运行时内存 2 项断言并入 `test/runtime_metrics_test.dart`，仅指标 group 保留 `RuntimeMetrics.reset`；断言总数不减少，减少 3 个独立入口；补齐收藏夹 widget 回归中的 toast timer 清理 | `dart analyze`、analyzer baseline、异步边界、格式、`git diff --check` 和 runner shell 语法通过；标准 workflow `43824776395` 的 Flutter regression 通过 385 项，native curl 通过 7 项 |

版本 `4.2.65+4265` 已由提交 `8c3b01ea` 发布；annotated tag `v4.2.65` 指向该提交。首次 workflow `43823709447` 因新 widget 回归未清理删除流程的 2 秒 toast timer 而失败，修复提交 `8c3b01ea` 后移动 tag 重跑；标准 workflow `43824776395` build 用时 9m48s、publish 用时 29s，Flutter regression、native curl、版本/tag 校验、Android 多 ABI、metadata、签名和 Release publish 全部成功。Release 已上传通用 APK、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。

普通 `master` push 仍只推送分支、不触发 Android workflow；只有 `v*` tag 创建或更新才触发发布。提交作者统一为 `liyw0205 <2650115317@qq.com>`；用户原有未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak` 继续保留且不纳入提交。Termux 本地 Flutter runner 仍因缺少 `impellerc` 无法执行，标准 tag workflow 已完成最终回归。

## 46. 2026-11-16 下载恢复与设置目录生命周期收口

本轮继续把边界回归并入已有 persistence/restore/widget suite，未新增独立 Flutter 测试入口：

| 功能组 | 修复/优化内容 | 回归/验证 |
| --- | --- | --- |
| A11 下载快照 | 原子快照写入失败时隔离未提交 `.tmp`；`dispose()` 清空任务后若空快照提交失败，隔离 `target/.tmp/.bak`，避免停止任务在重启时复活；保留失败证据 | `test/download_persistence_test.dart`、`test/favorite_download_test.dart` 合并覆盖失败写入、取消和重新初始化 |
| A1 恢复事务 | 恢复 journal 已记录 `restored=true`、目标被删除但 backup 仍在时，继续现有 backup rename 恢复；仅 backup 也缺失时保持 fail-closed | `test/data_restore_transaction_test.dart` 合并覆盖中断窗口恢复 |
| A16 设置目录 | 桌面/Android 两个提交入口统一到 `_submit()`，防重复提交；等待迁移和设置落盘，页面卸载后不再访问失效 context，失败恢复旧路径 | 保留既有 proxy 配置卸载回归；目录迁移边界以目标 analyze、异步检查和标准 runner 验收，未增加会拖慢全量 runner 的独立 widget 用例 |
| 测试流程 | 新增边界均追加到现有 suite，删除会卡住发布 runner 的重复 widget 用例；日常仍可通过 `FLUTTER_TEST_FILES` 定向执行；发布 tag 仍只运行一次完整串行 Flutter/native/Android 门禁 | `dart analyze`、analyzer baseline、异步边界、format、shell 语法和差异检查通过；workflow `43842756497` 的 Flutter regression 通过 387 项，native curl 通过 7 项 |

版本 `4.2.66+4266` 已由提交 `2fc8a3cd` 发布；`v4.2.66` 指向该提交。workflow `43842756497` 的 build 用时 11m54s、publish 用时 14s，Flutter regression、native curl、版本/tag 校验、Android 多 ABI、metadata、签名和 Release publish 全部成功。Release 已上传通用 APK、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。普通 `master` push 仍不触发 Android workflow；只有 `v*` tag 创建或更新才触发发布。提交作者统一为 `liyw0205 <2650115317@qq.com>`。用户原有未跟踪的 `.ai-memory/` 和 `tool/proxy_probe.sh.bak` 继续保留且不纳入提交。

## 47. 2026-11-16 异步持久化边界与数据库测试入口收敛

本轮继续减少重复测试启动，同时修复两个会让异步失败被吞掉或阻塞后续操作的边界：

| 功能组 | 提交 | 修复/优化内容 | 回归/验证 |
| --- | --- | --- | --- |
| A2 收藏夹标签持久化 | `c14afc7e` | `LocalFavoritesManager.addTagTo()` 改为 `Future<void>`；维护忙时进入 `DataMaintenance` 队列，正常路径等待 `saveData()`，持久化失败会传播给调用方；文件夹可用性扫描同步等待标签写入 | `test/data_sync_boundary_test.dart` 覆盖维护等待、SQLite 触发器失败传播、失败后后续写入可继续 |
| A11 下载生命周期 gate | `c14afc7e` | `_runLifecycle()` 对 pending enqueue flush 使用内层 `finally` 清理 gate、标志位和 completer；持久化失败时保留已转入主队列的任务，但不错误自动启动，也不阻塞后续 lifecycle 请求 | `test/favorite_download_test.dart` 覆盖 flush 失败、任务保留、暂停状态和后续 gate 可用 |
| 测试流程 | `c14afc7e` | 删除独立 `test/database_performance_test.dart`，将 1k/10k/50k 历史数据库性能基准并入 `test/database_correctness_test.dart`；默认跳过，仅 `PICA_RUN_PERF_TESTS=1` 或 tag runner 显式开启；旧维护用例显式等待新的 Future API | 自动发现的 Flutter suite 减少一个，正确性覆盖和发布性能门禁不降低；目标 analyze、analyzer baseline、异步边界、格式、shell 语法和差异检查通过 |

版本提交 `3e0305e1` 将版本递增到 `4.2.67+4267`，annotated tag `v4.2.67` 指向该提交。标准 tag workflow `43849041708` 的 build 用时约 10m32s、publish 用时 14s；Flutter regression 通过 389 项，native curl 通过 7 项，版本/tag 校验、Android 多 ABI、metadata、签名校验和 Release publish 全部成功。Release 已上传 `PicaComic-4.2.67.apk`、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。普通 `master` push 仍只推送分支、不触发 Android workflow；只有 `v*` tag 创建或更新才触发发布，且 workflow 校验 tag 仍指向本次构建提交。Termux 本地 Flutter 仍可能受 Kernel SDK mismatch 或 `impellerc` 环境限制，不能替代标准 CI。提交作者统一为 `liyw0205 <2650115317@qq.com>`，用户原有未跟踪文件继续保留且不纳入提交。

## 48. 2026-11-16 缓存测试 suite 继续合并

本轮只调整测试入口，不改变缓存行为或断言：

| 功能组 | 提交 | 修复/优化内容 | 回归/验证 |
| --- | --- | --- | --- |
| 测试流程 | `57e91e56` | 将唯一用例 `test/byte_lru_cache_test.dart` 并入已有 `test/cache_manager_test.dart`，保留 `byte_lru_cache_regression.dart` 作为局部 helper；不合并共享 `DownloadManager` 状态的高耦合 suite | 自动发现的 Flutter suite 从 54 减少到 53，缓存替换、淘汰和 owner-safe cleanup 断言保持不变；目标 analyze、analyzer baseline、格式和 `git diff --check` 通过 |

版本提交 `71f348b5` 将版本递增到 `4.2.68+4268`，annotated tag `v4.2.68` 指向该提交。标准 tag workflow `43852898428` 的 build 用时约 9m53s、publish 用时 20s；Flutter regression 通过 389 项，native curl 通过 7 项，版本/tag 校验、Android 多 ABI、metadata、签名校验和 Release publish 全部成功。Release 已上传 `PicaComic-4.2.68.apk`、三种 ABI APK、`SHA256SUMS` 和 `apk-metadata.json`。普通 `master` push 仍只推送分支、不触发 Android workflow；只有 `v*` tag 创建或更新才触发发布，且 workflow 校验 tag 仍指向本次构建提交。Termux 本地 Flutter runner 仍受 `impellerc` 环境限制，不能替代标准 CI。提交作者统一为 `liyw0205 <2650115317@qq.com>`，用户原有未跟踪文件继续保留且不纳入提交。
