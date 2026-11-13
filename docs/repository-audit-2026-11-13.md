# 当前仓库审查与优化方案

日期：2026-11-13。基线：`master`，HEAD `631954f0`，版本 `4.2.17+4217`。

本报告审查当前工作区，包括上一轮未提交的修复；不是只审查 HEAD。
本报告随修复继续更新。当前版本为 `4.2.18+4218`，代码与 CI 依赖修复已推送到 `master`。
用户原有未跟踪的 `tool/` 保持原状，不纳入建议提交。

## 结论

初审发现发布可追溯性、下载完成判定、任务生命周期和列表分页方面的明确缺陷；修复过程中还定位并修正了版本比较的 Dart 类型错误。
关键代码修复已落地；通过 Debian proot 中与 Flutter engine 匹配的 Linux runner，全量 Flutter tests 97 项通过，全仓 analyze 为 0 error、0 warning、149 info，Native curl 6 项通过。GitHub Actions 对 `master` 的 Android debug 构建、artifact 上传亦已成功。
Termux 原生 Flutter/Dart 与 Linux tester 仍不匹配；签名 Release、设备验收与升级一致性仍未验证。仓库未列出 repository-level Actions secrets，因此本轮未推送签名 Release tag；CI artifact 是 7 天保留的 debug APK。部分独立 `dart run` FFI 脚本也会触发当前 Dart FFI transformer 崩溃，不能将其误记为通过。

以下缺陷由当前代码路径确认；除验证章节明确列出的回归外，尚未在设备上逐项复现。
本轮重点覆盖网络、搜索、图片、下载、缓存、更新与工作流，不构成所有功能的穷尽审计。

## P1：应在下次发布前修复

### R01：发布流程会覆盖已有版本

- 位置：`.github/workflows/android.yml:94`、`:101`。
- 触发：未增加 `pubspec.yaml` 版本时推送 master，或同版本工作流重跑。
- 原因：`git tag -f`、强制推送 tag、`gh release upload --clobber`，且无 concurrency。
- 后果：同一版本的 tag 与 APK 可变化；并行工作流可能互相覆盖，无法可靠追溯或回滚。
- 方案：分离验证和发布。分支推送只验证/上传 Actions artifact；不可变版本 tag 才发布。校验 tag、pubspec、提交一致性；同 tag 不覆盖已有资产。为验证和发布分别设置并发策略。
- 验收：同版本重跑不移动 tag、不更换 APK；两个并行运行不会使旧提交覆盖新产物。
- 状态：工作流已改为 master 只做 CI/debug，版本 tag 才发布；tag 与 package 版本/提交校验、发布阶段远端 tag 复核、不可覆盖 Release 和并发控制已配置。仓库仍需配置 ruleset 禁止 `v*` tag 更新/删除；GitHub Actions 实跑待验证。

### R02：Release 在缺少签名配置时使用临时 debug 密钥

- 位置：`android/app/build.gradle:115`；Android 工作流没有恢复签名材料的步骤。
- 触发：全新 CI runner 中没有 `android/key.properties`。
- 后果：新生成的 debug 密钥不能保证与已安装 APK 一致，后续版本可能无法覆盖安装。
- 方案：使用现有发布密钥，通过 CI secrets 注入；正式 release 缺少材料时直接失败，禁止静默退回 debug 签名。不创建替代密钥。
- 验收：连续两个版本证书 SHA-256 一致；已安装旧版能覆盖升级且数据保留。
- 前置条件：未读取私钥或密码；GitHub repository-level Actions secrets 列表为空，既有签名材料仍待确认。
- 状态：Release 缺少签名配置时已改为失败，工作流从 secrets 恢复既有密钥；新增必需的 `ANDROID_CERT_SHA256` secret，并在发布前用 apksigner 核对每个 APK。配置既有 secrets、核对指纹与旧 APK 一致性、覆盖升级及数据保留仍须在仓库/设备侧验收。

### R03：EH 的 MPV 图片分支会完成一个空文件

- 位置：`lib/foundation/image_manager.dart:248`、`:251`、`:272`、`:428`。
- 触发：画廊认证信息包含 `mpvKey`。
- 原因：MPV 分支获取 `ResponseBody` 后，没有消费其 stream；实际流读取仅在另一个分支中。
- 后果：关闭空缓存、输出 `0/0` 完成进度；阅读端报空图片，下载 wrapper 甚至可能把未写入图片视作完成。
- 方案：让 showpage/MPV 共用响应读取、写缓存、长度检查和完成判定；非空有效图片才完成。重试时同时重置缓存、缓冲与字节计数。
- 同模块边界：`:383` 的 Content-Length 双重强制读取会使无长度响应失败；改为可选长度并支持 chunked 响应。
- 验收：MPV/showpage、无长度、截断、重试均有回归；完成时文件可解码且字节计数准确。
- 状态：MPV 与 showpage 共用响应读取、长度核对和图片解码校验，空/HTML/截断/损坏响应不会标记完成，重试会重置缓存与计数。两个纯 Dart 回归覆盖有效图片、未知/错误长度及损坏响应并已通过；EH 网络、缓存和设备集成仍待验证。

### R04：EH ZIP 可能乱序、误报完成或在停止后继续解压

- 位置：`lib/network/eh_network/eh_download_model.dart:284`、`:301`、`:344`、`:348`、`:361`。
- 原因：排序后的 `files` 未用于遍历；`openAndExtract` 的依赖实现忽略原生返回码；停止需要尚未初始化的 `late sendPort`，且没有等待 worker 退出。
- 后果：阅读顺序依赖文件系统；坏 ZIP 也可能触发 finish；启动时立即停止可能异常；下载目录删除与 worker 写入竞争。
- 方案：用显式阶段和完成消息区分下载、解压、验证、提交。解压至临时目录，核验有效图片与页数，递归收集并自然排序，采用两阶段重命名避免覆盖；成功后才删除 ZIP。worker 使用启动握手和停止确认，删除目录前等待退出。
- 验收：乱序的 `1/2/10`、子目录、坏 ZIP、空 ZIP、重名目标、启动即停止、解压中停止都不得误报成功或丢失源文件。
- 已核对依赖：锁定的 `zip_flutter` 中 `openAndExtract` 是同步 `void`，不是忘记 await；仅添加 await 不能修复错误传播。
- 状态：已改为临时目录解压、校验路径和图片、自然排序、暂存后带回滚提交；声明页数与实际候选图片数不符会失败。解压前解析 ZIP 外部属性并拒绝 Unix 符号链接，防止条目将文件写出目标目录。解压改在受控 worker 内同步运行，不再使用 `openAndExtractAsync` 创建不可跟踪的子 isolate；worker 超时后 kill 会等待 isolate 的真实退出消息，再允许删除目录。cover 与取归档链接的 POST/跳转 GET 接入取消令牌；proxy 等待期间取消、真实 isolate 下载中取消和恶意 symlink ZIP 回归通过。原生解压中的强制停止及真实站点集成仍需设备或 CI 验证。

### R05：暂停不能阻止延迟重试重新启动下载

- 位置：`lib/network/download_model.dart:156`、`:267`、`:284`。
- 触发：下载失败进入延迟重试后，用户暂停或删除任务。
- 原因：`retry()` 的延迟完成后无条件 `start()`，没有校验原运行代次或暂停状态。
- 后果：用户已停止的任务重新下载，可能重建已删除目录。
- 方案：重试捕获当前运行代次；暂停/停止使等待失效；延迟结束后再次校验任务仍在队列且处于运行状态。
- 验收：重试等待期间暂停、删除、重新开始，旧代次均不得发送新请求或写文件。
- 状态：重试捕获运行代次，并在延迟后确认任务仍是队首且下载队列处于运行状态；暂停、停止或切换任务会使旧重试失效。身份比较已改为对象 identity，成功落盘进度后重置连续失败次数。新增退避期间暂停、删除、队首替换的专项回归；包含既有收藏下载用例共 8 项通过。

### R06：收藏下载会启动两次，并可能替换错误队列项

- 位置：`lib/network/favorite_download.dart:32`、`:89`、`:91`。
- 原因：`onStart()` 已调用 `downloadLogic.start()`，返回后 `start()` 又调用一次；异步详情获取结束后无条件 `removeFirst()`，没有确认队首仍是当前任务。
- 后果：重复请求/写入；初始化期间暂停或队列变化可能导致替换其他下载任务。
- 方案：初始化只产生一个下载实现，统一在一个位置启动；替换队列前核对任务身份及运行代次；初始化错误必须传递给调用方。
- 验收：一次操作仅启动一次；详情获取期间暂停/删除/切换队首不影响其他任务。
- 注意：不要仅为消除 `must_call_super` warning 机械补调用，需先明确 wrapper 与实际下载实现的目录所有权。
- 状态：详情加载完成后核对队首仍为当前收藏 wrapper，才替换为下载实现；进行中的详情请求复用，只在替换后启动一次，初始化错误向错误回调传递。暂停/停止会取消封面请求；finish 等待持久化后重新核对下载状态和队首身份，避免再次启动已取消的后继项。封面取消、持久化期间取消队首、重复启动、队首变化及取消期间 start/pause 与 finish 清理交错回归通过。

### R07：共享列表在失败和刷新后会跳页

- 位置：`lib/components/comics_list.dart:68`、`:90`、`:96`。
- 原因：`loadNextPage()` 在错误响应后仍 `current++`；refresh 不重置 current、maxPage、dividedComics 和请求代次；异常路径没有 finally 释放 loadingData。
- 后果：失败的页被跳过；第 N 页刷新后只加载第一页却继续请求 N+1；旧请求可能回填刷新后的结果或使列表卡在加载中。
- 方案：成功接纳结果才推进页码；刷新统一重置状态；请求捕获目标页和 generation，过期结果丢弃；使用 try/finally 管理加载标志。
- 验收：第二页失败后重试仍为第二页；第十页刷新后加载顺序为 1、2；刷新期间旧响应不污染数据；抛异常后可重试。
- 状态：页码仅在响应成功接纳后推进；刷新重置分页状态并使旧请求代次失效，过期响应不回填；加载标志由 `finally` 释放。失败重试、刷新隔离和异常恢复回归已通过。

### R08：图片任务标记不等于任务所有权，也未正确取消资源

- 位置：`lib/foundation/image_manager.dart:48`、`:142`、`:733`；`lib/network/download_model.dart:430`。
- 原因：wait 超时会删除其他请求的标记；登记与等待分离，旧 finally 无条件 remove；clearTasks 只清 map；EH 缓存命中也无条件递减未获取的 ehgtLoading；wrapper.cancel 仅设置布尔值。
- 后果：同图重复下载、并发计数为负、限流失效；暂停后仍消耗网络；流消费者提前退出时临时缓存可能残留。
- 方案：在获取任务时原子登记独立所有者；释放只影响该所有者；仅在确实获取 EH 并发名额后释放。将 CancelToken/订阅取消连接至网络请求，并在 finally 等待未提交缓存释放。
- 调用方：保留并核对 `download_model.dart:289` 与 `reader/comic_reading_page.dart:253` 两处 clearTasks 的语义，不能全局清标记替代定向取消。
- 验收：同 key 并发、超过 15 秒慢请求、缓存命中、提前取消、异常后再次请求；EH 同时请求不超过 3，计数最终回到 0。
- 状态：图片任务改为 owner token，移除超时偷删标记；下载 wrapper 取消时只取消自身 Dio token 和订阅，下载暂停不再全局清除阅读器请求。EH 并发名额仅对实际获取者释放，自定义图片及缓存异常路径由 `finally` 清理。流式响应末块进度改为非完成事件，只有缓存关闭后才发完成事件。wrapper 异步读取期间取消会等待 iterator/listener 收尾，目录删除和队列推进等待全部 wrapper 清理；`test/download_image_task_test.dart`、`test/image_task_owner_test.dart` 与队列取消交错回归均通过。EH 下载取消已有 isolate 回归，真实 EH 图片网络、缓存及 3 并发集成仍未覆盖。

## P2：功能可靠性与安全收尾

### R09：更新地址仍指向上游，更新摘要截取错误

- 位置：`lib/network/update.dart:10`、`:65`、`:69`、`:75`。
- 证据：origin 为 `liyw0205/PicaComic`，检查/下载更新使用 `Pacalini/PicaComic`；replaceAll 结果未保存；sublist(5) 删除前五行而非只显示前五行。
- 方案：复用一个当前发行仓库配置；使用安全版本解析；取前五行后追加省略号。
- 验收：检查版本、下载地址和发布仓库一致；空摘要、CRLF、长摘要及非法版本字符串不会异常。
- 状态：发行仓库、tag 解析、摘要前五行及版本组件类型错误已修复；GitHub Release 的 `body: null` 作为有效空摘要处理，不会掩盖更新；版本比较和空摘要回归通过。

### R10：坏图片保留在内存缓存，磁盘清理不能恢复

- 位置：`lib/foundation/image_loader/base_image_provider.dart:55`、`:90`、`:93`。
- 原因：解码前写入静态 `_cache`，解码失败只删除磁盘缓存及 Flutter imageCache。
- 后果：同 key 重试继续使用坏字节，直到内存缓存自然淘汰或重启。
- 方案：解码成功后缓存，或在失败时同时删除对应内存项并修正计数；同 key 并发写入避免重复计算容量。
- 验收：服务器先返回 HTML/损坏图片，再返回正常图片；第二次加载必须重新请求并成功。
- 状态：原始字节仅在图片解码成功后进入内存缓存，命中按 LRU 次序更新，坏缓存解码失败时同步移除。新增 provider 级真实解码回归：坏 HTML 缓存被删除，后续同 key 请求重新取数并成功解码，测试通过。

### R11：语言设置变更尚未使已加载列表失效

- 位置：`lib/pages/search_result_page.dart:40`、`:80`、`:243`；`lib/pages/settings/explore_settings.dart:73`。
- 原因：每一页读取当前设置，但已展示的数据和页面 key 不包含语言；设置变更仅保存文件，没有刷新相关列表。
- 后果：旧语言第一页与新语言后续页混合；设置 Chinese 后保留的英文/日文仍可见。
- 方案：一次查询固定语言与排序快照；语言变更触发新查询及第一页重载；key/tag 使用完整查询身份，旧响应不得追加。
- 验收：无筛选 -> Chinese -> English、已加载多页、请求期间切换、跨源查询均不会混合结果；显式 language 条件优先的现有规则保持不变。
- 状态：分页回调固定使用构建时语言设置，列表 key/tag 按最终查询区分；语言设置变更触发全局重建，覆盖式搜索按有效查询重建子树。显式 `language:` 优先逻辑保留；默认语言切换与显式条件优先的 widget 回归均通过。

### R12：nhentai 首页仍使用虚构的 20000 页

- 位置：`lib/comic_source/built_in/nhentai.dart:121`、`:123`；`lib/network/nhentai_network/models.dart:31`。
- 原因：首页模型没有真实总分页数，网络层未将分页信息传出；loadMoreHomePageData 在空结果时也返回 true。
- 后果：可请求超过真实末页的页面，页数提示错误，末尾仍显示加载。
- 方案：传递 API/HTML 的分页元数据或明确 hasMore；空原始结果终止。区分“漫画总页数 pages”和“列表总分页数”，不能混用。
- 验收：单页、多页、无分页元数据、空末页及筛选后末页停止；原有漫画块 pages 显示不回退。
- 状态：硬编码 `20000` 已移除，首页透传 API/HTML 总页数；通用分页组件将未知总数的空响应视为终页，并捕获首屏/后续页异常、释放加载状态、允许重试；刷新会使旧请求代次失效，避免过期结果回填。复核发现 HTML fallback 在无分页元数据的空第 N 页仍把 N 算入总数，且 mixed explore 把空页包装成非空外层列表；现改为空页返回空外层列表，并按 N-1 计页。API 元数据缺失、空末页、HTML fallback 及漫画页数展示回归通过；真实站点响应兼容性待 CI/设备验证。

### R13：网络日志脱敏没有覆盖所有错误路径

- 位置：`lib/foundation/image_manager.dart:817`；`lib/network/eh_network/eh_main_network.dart:1121`、`:1150`。
- 原因：通用 interceptor 已脱敏，但业务层仍直接记录完整 URL、异常及响应正文。
- 后果：签名链接的 rkey/token、认证相关正文仍可能进入可导出的日志。
- 方案：错误日志复用结构化摘要和 URL 脱敏；完整正文默认不记录；逐一核对业务 catch，而不是只修 interceptor。
- 验收：使用虚构 token/cookie/rkey 测试成功、异常、解析失败和重定向，日志不出现任何原始敏感值。
- 状态：EH 归档信息异常路径改为脱敏 URL 和响应摘要，图片异常不再输出原始 URL/异常文本；EH、JM 直连 Dio 的默认 `LogInterceptor` 已移除。网络源、脚本源解析、下载 worker、WebDAV、登录/代理调试、全局异常处理及本地文件错误日志均改用安全异常摘要；Dio 异常仅记录类型、方法、脱敏 URL 和状态码，不记录异常消息或响应正文。EH 图片 `/s/{imgKey}/...` 路径段现也脱敏。新增覆盖 App Link、代理 URI、敏感 query/path/header 与错误 interceptor 的回归，定向测试通过。真实网络重定向与设备日志导出仍未验收。

### R14：Hitomi 二进制索引解析缺少完整性校验

- 位置：`lib/network/hitomi_network/search.dart:135`、`:213`、`:269`、`:308`。
- 原因：Range 响应未验证就写缓存；节点字段长度/数量缺少边界检查；子节点地址递减时 continue 跳过游标推进并缩短地址数组。
- 后果：截断/错误响应缓存后持续失败；子节点解析错位或查询访问越界。
- 方案：先验证响应状态、区间与长度，再原子缓存；ByteData 使用真实 view 边界；校验每个字段；固定消费全部子节点槽位，不能以地址大小推断合法性。
- 验收：200 替代 206、短响应、非四字节对齐 ID 列表、异常字段计数、下降/零子节点地址、正常 B-tree 查询；现有排除词测试继续通过。
- 状态：已加入严格 206/Content-Range/长度校验、校验后原子缓存、Nozomi 4 字节对齐、节点字段数量和边界检查，并按原槽位读取全部子节点。现对 Range 长度有效但节点/图库数据结构损坏的响应删除对应缓存；图库 ID 必须为正数，否则拒绝并清除该范围缓存，避免后续查询持续命中语义非法数据。正常查询、异常 Range、偏移 view、坏节点缓存失效及非正 ID 回归通过。

## 发布与性能治理

以下不应与功能修复混成一次大重构，但发布验证要求是下一次发布的前置条件。

| 项目 | 现状与方案 | 验收 |
| --- | --- | --- |
| Android CI | `.github/workflows/android.yml` 配置全量 `flutter analyze`、`flutter test`、Native curl 回归；master 构建 debug，版本 tag 构建签名 release，复核远端 tag、校验 APK 证书指纹并生成 SHA256SUMS。真实 Actions run `43371123167` 的 analyze、97 项测试、Native curl 6 项、Android debug 构建和 artifact 上传均成功；首次运行发现 Ubuntu runner 缺少 libcurl 开发包，现已在 workflow 安装。Release 签名仍待 secrets。 | 配置签名与预期证书指纹 secrets、保护 `v*` tag；干净 GitHub runner 上各 ABI release 构建与签名通过；确认 armeabi-v7a 产物实际存在；失败时不能发布。 |
| iOS 工作流 | `.github/workflows/ios_simulator.yml` 已升级 upload-artifact@v4，并固定 Flutter 3.44.0、Xcode 16.4。 | 模拟器构建和产物上传成功；保留可追溯运行结果。 |
| 图片内存 | 通用、EH、Hitomi、JM、自定义图片流已改用 `BytesBuilder`，减少逐块扩容复制；EH 已校验图片通过完成进度标记避免 wrapper 对同一 bytes 再完整解码；native curl 仍全量缓冲并限制 64 MiB；`BaseImageProvider` 的原始字节缓存仍独立存在，坏图清理、LRU 次序与容量维护已修复。重复持有与流式落盘仍需基准测试决定。 | 固定图片集比较峰值 RSS、首字节与完成时间；大图片明确区分资源大小限制和连接错误；不取消安全上限。 |
| 内存缓存预算 | `BaseImageProvider` 原始字节缓存现为 50 MiB 容量受限 LRU，命中会更新次序，替换及解码失败会修正计数；Flutter `ImageCache`、磁盘缓存、网络缓冲和 native curl 缓冲各自独立，尚无整机总预算基线。 | 用固定阅读/下载场景测峰值 RSS；明确总预算、单项上限及大图淘汰行为，不因单缓存达标就假设总内存受控。 |
| 依赖可重复性 | webdav_client 使用 main、flutter_to_arch 无 ref，部分包为 any。现有 pubspec.lock 已锁定 resolved-ref，不能据此声称当前每次构建必然飘移。固定剩余 Git SHA、为关键包补范围并验证 lock。 | 干净环境 --enforce-lockfile 解析一致；升级单独提交并运行完整回归。 |
| Termux SDK 兼容 | kernel SDK hash 修改现仅由显式 `-Ppica.termuxKernelSdkHashPatch=true` 启用；默认 debug 任务图不包含补丁，opt-in 任务图包含补丁，PR 验证工作流也不设置该属性。dry-run 证明任务图隔离，不证明本机实际构建或运行成功。 | 标准 CI 不做 hash 替换仍能构建；Termux 调试有独立、可复现路径；不盲删目前仍依赖的补丁。 |
| 小型取消语义 | `app_dio.dart` 的请求重试会在取消后停止；取消重试回归现已增加 `DioExceptionType.cancel` 分类断言。 | Flutter test 可运行环境验证无重试且异常分类正确。 |
| 静态债务 | unused_import 已清理；本轮全仓分析为 0 error、0 warning、149 条 info，主要为弃用 API、既有风格提示和少量测试代码提示；用户未跟踪 `tool/` 中另有 12 条 `avoid_print`。继续分模块治理，不批量屏蔽规则。 | warning 清零；info 分批减少；不改变用户原有 tool/。 |

## 实施顺序

1. **代码修复与本地回归**：R01-R14 对应代码修复和专项测试已落地，并补齐 ZIP symlink、EH 取链取消、下载封面取消/队列竞态、空 Release 摘要及 Hitomi 非正 ID 回归；全量 Flutter tests 97 项、Native curl 6 项通过，analyze 为 0 error、0 warning、149 info。版本 `4.2.18+4218` 已推送至 `master`。
2. **发布前置验收**：在 GitHub 配置既有 keystore 与证书指纹 secrets、保护 `v*` tag；用干净 Ubuntu runner 验证 APK 的四种产物和签名，并由真实 Actions 执行发布流程。不能用本机 Termux 构建失败替代这些结果。
3. **设备验收**：核对旧 APK 证书并验证覆盖升级和数据保留；实机检查语言切换、多页阅读、代理/TLS、下载暂停恢复及 EH 图片/归档取消。
4. **性能与依赖治理**：先建立图片和整机内存基线，再决定流式落盘、缓存预算及依赖固定；不凭感觉引入大规模重构或升级。
5. **交付**：master CI 已生成 debug APK artifact；签名 Release tag 等既有 keystore 与证书指纹 secrets 配置并验收后再创建，不生成新密钥、不覆盖现有 tag。

## 本轮验证

- 测试运行环境：Termux SDK 内的 Dart 是 Android VM，而 `flutter_tester` 是 Linux ARM64。为不改原 SDK，在 Debian proot 和 `~/.cache/pica-linux-flutter` 建了匹配 engine revision `4c525dac5ebe5971c5708ef73558ed8edcf4a362` 的 Linux Dart 3.12 / Flutter 3.44 source-runner shim。
- `flutter test --no-pub`：全量 97 项通过，覆盖本轮新增回归。测试通过 Debian proot 内与 Flutter engine revision 匹配的 Linux runner 执行；`LD_LIBRARY_PATH` 指向 Debian SQLite；因 proot 以 root 运行，权限拒绝子测例跳过，非 root CI 会运行该分支。Termux 原生 runner 仍因 SDK snapshot/impellerc 不匹配不可用。
- `flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings`：退出码 0，0 error、0 warning、149 info。新增 `tool/` 中已有的 `avoid_print` 与其余 info 未修改。
- `sh test/native_curl/run.sh`：6 项 JNI/C 回归通过。复核修正了 POST body 用例的假阳性：服务端线程只记录校验结果并返回成功/失败响应，主线程断言请求次数、重试次数、curl/HTTP 状态、响应体及请求 body 校验结果。`git diff --check` 通过。
- `.github/workflows/android.yml` 与 `ios_simulator.yml` 均通过 Ruby YAML 解析；提取所有 `run:` 块后逐块执行 `bash -n` 均通过。Actions run `43371123167` 中 Android debug 构建与 artifact 上传成功；Release APK 重命名逻辑与 Gradle `splits.abi`/universal 配置一致。签名 Release 仍需干净 Ubuntu 构建确认四种产物及签名。
- `flutter build apk --debug --no-pub`：首次失败于 `:app:processDebugResources`，Termux 下 Gradle 调用 Linux AAPT2 包装脚本被 `sh` 解析并报 `Syntax error: ")" unexpected`。再通过 `-Dorg.gradle.project.android.aapt2FromMavenOverride=/data/data/com.termux/files/usr/bin/aapt2` 指向本机 AAPT2 后，构建继续到资源链接，但本机 AAPT2 无法读取当前 SDK 平台资源：对 API 36 `android.jar` 的 `dump resources` 以退出码 139 崩溃，对 API 35 报 `illegal map type 'string' (22)`。尚未产出 APK，不能视为应用构建通过。
- 直接以 Linux `dart run` 编译涉及 FFI 的 `cache_manager_regression.dart` 仍会触发 Dart SDK `InvalidType` / `FunctionType` transformer 崩溃；Flutter test runner 中相同 CacheManager 回归已通过。Termux 原生 Flutter test 的 ICU / SDK hash 错误仍存在。
- Gradle `:app:packageDebug --dry-run` 默认任务图成功且不包含 `fixDebugFlutterKernelSdkHash`；显式 opt-in 任务图包含该任务；`:app:assembleRelease --dry-run` 包含 `validateReleaseSigning`。这些只验证任务图，不是 APK 构建或 hash 实际改写验收。
- GitHub Actions run `43371123167` 成功，产出 master debug artifact；签名 Release tag 未触发，因为 repository-level Actions secrets 列表为空。旧 APK 证书一致性、既有 keystore secrets 与覆盖升级仍待仓库/设备验收。

## 既有改动状态

下载器、缓存、安全 TLS、幂等重试限制、Hitomi 排除词、语言默认补全、Hitomi 搜索修复和版本页数展示均在当前未提交工作区。
本轮没有重置或丢弃这些改动；`tool/` 仍为用户已有未跟踪内容，没有纳入修改或提交范围。

## 后续待办

- 确认既有 APK 发布 keystore secrets 已配置，并核对证书 SHA-256；不创建替代密钥。
- 在 GitHub Actions 干净 runner 验证全量 Flutter tests、分析、Android debug/release 构建以及签名。
- 在标准 Linux runner 验证 Android 构建；本机 Termux AAPT2 包装脚本不兼容，不能用本地 debug 构建替代 CI 结果。
- EH cover 请求仍缺真实网络/目录重建集成验证；ZIP 插件长时间阻塞时的取消边界也需在设备或 CI 验证。
- 真实设备验证已加载多页时切换语言、代理/TLS、下载暂停恢复、阅读与图片缓存恢复。
- 核对现有 APK 证书指纹和 Release secrets；本地 dry-run 与全量单测不替代正式签名和覆盖升级验收。
- 正式发布前增加版本号并创建新不可变 tag；不重推现有版本 tag。
- 以真实 Ubuntu Release 构建确认 armeabi-v7a APK 是否生成并完成签名校验；若缺失，再依据目标设备支持策略调整 workflow 产物要求。
