## PhysicoBridge

本项目为一套系统化、基于 LSL（Lab Streaming Layer）的多模态生理信息采集与对齐工具。目前支持对 Polar（H10、Verity 等）设备、呼吸带设备的直连采集能力。核心思想是将不同来源、不同传输方式的原始信号统一抽象为标准化的 LSL 流，借助 LabRecorder 录制为 XDF 文件，并配套提供数据校验与格式转换工具，保证实验数据在时序与结构上的一致性与可复用性。

本项目已升级为一套系统化、基于 LSL（Lab Streaming Layer）的多模态生理信息采集与对齐工具。除延续对 Polar（H10、Verity 等）设备的支持外，新增了对呼吸带（HKH 系列）的直连采集能力。核心思想是将不同来源、不同传输方式的原始信号统一抽象为标准化的 LSL 流，借助 LabRecorder 录制为 XDF 文件，并配套提供数据校验与格式转换工具，保证实验数据在时序与结构上的一致性与可复用性。

整体的工作流程可分三大部分。（1）数据采集。（2）建立UDP通道并发送数据。（3）接受数据并在LSL中同步记录数据。本项目中，数据采集由心电仪（Polar）、呼吸带负责。项目开发的App负责提取Polar数据、与UDP连接与发送的工作。在电脑端运行的py脚本负责LSL环节的工作。其原理是Polar捕获到生理信号后，由App将这些数据拿到手。App接着主动地找到用于保存数据的电脑所载的位置，也就是负责记录数据的电脑的网络地址，这就是所谓的“UDP目标”。然后向该地址发送数据。电脑则负责监听本地网络环境是否有信号传过来，不论什么信号、多少信号会全部接受，并通过LSL技术同步把这些信号记录下来。

整体链路为：Polar 测量心率数据 → iPhone App获取数据 → UDP 发包 → 局域网 → 桥接器/`udp_to_lsl.py`（Mac） → 在本机发布两路 LSL → LabRecorder 发现并录制 → `.xdf` 文件 →  `.csv` 文件

## 目录

  

- 总体概览

  

- 系统架构

  

- 数据与时间同步

  

- 支持的设备与数据流

  

- 代码结构与职责

  

- 构建与运行

  

- 采集流程

  

- UDP 文本格式与 LSL 映射

  

- 质量核查与可视化

  

- 已知限制

  

- 后续计划

  

- 参考资料

  

## 总体概览

  

- iOS 端使用 Polar 官方 iOS SDK（ReactiveX/RxSwift 风格 API）直连传感器，订阅所选数据流（HR、RR、ECG、ACC）。

  

- iOS 端将采样批量封装为单行 JSON 文本，通过 UDP 发往上位机的 Python 桥接脚本。

  

- Python 端 udp_to_lsl.py 将 UDP 文本转换为两路 LSL 输出：

  

- 数据流：PB_UDP_TEST（type=udp_text）

  

- 标记流：PB_MARKERS_TEST（type=Markers）

  

- LabRecorder 订阅上述 LSL 流并写出 XDF 文件。

  

- 下游脚本对 XDF 做质量核查和导出 CSV，并可绘图。

  

这一设计的出发点是将设备接入、网络出站、录制与后处理分离，使实验流程清晰、可替换、可扩展。

  

## 系统架构

```java
Polar H10/Verity (BLE)
      │
      │  PolarBleSdk (iOS, Rx)
      ▼
iOS App (PolarManager / AppStore)
  ├─ 选择订阅 HR / RR / ECG / ACC / PPI / PPG
  ├─ 生成 JSON 包
  └─ UDP 发送至上位机（Host:Port）
      │
      ▼
Python: bridge_hub.py
  ├─ 监听 UDP 文本
  ├─ 解析 JSON / 基本容错
  ├─ 输出 LSL 数据流（udp_text）
  └─ 输出 LSL 标记流（Markers）
      │
      ▼
LabRecorder → XDF
      │
      ▼
分析脚本：
polar_check_xdf.py, 
polar_xdf_to_csv.py, 
plot_data_plot_validity.py
  ├─ 质量核查
  ├─ CSV 导出
  └─ 可视化与数据质量平贵
```

### 基本介绍

这套系统面向真实实验场景里“生理信号 + 行为/阶段标记”并行采集与复盘的需求。合理分开手机端（iOS）和电脑端（UDP→LSL 桥接与记录）分工，最大限度地把容易出错的复杂逻辑压回到工程最适合的边界内。系统可支持多个设备的采集。

第一、心电设备针对Polar品牌开发。Polar是一款经济、简便、稳定的小型设备，用于运动健身场景，但大量研究证实该设备获取的心电信号能满足最小科研要就。研究者操作从 iOS 端开始：先在主界面看到可用设备，选择 Polar H10 或 Verity Sense，点击连接；一旦连上，就能在采集页选择要订阅的信号种类。这里有两条性质完全不同但同样重要的“流”：一条叫数据流（ECG、PPG、ACC、HR、RR、PPI 等），另一条叫控制流（实验阶段标记，如 baseline / 诱导 / 干预的起止）。数据流体现“客观生理过程”，控制流承担“时间锚点”。这两条流都走 UDP→LSL 这一条通道，但在协议与 LSL 命名上严格区分：数据流经由数值型 LSL 流（如 PB_ECG_H10、PB_PPG_Verity、PB_RR_H10 等）承载，控制流单独以 PB_MARKERS 文本流记录，保证后续分析可以各取所需地做对齐与统计。

第二、系统提供了“直连串口”的第二条采集路线，用于接入呼吸带。与手机中转不同，HKH 通过 USB/虚拟串口（115200, 8N1） 直接连接上位机，由电脑端桥接脚本发出“启动/停止测量”等设备指令并持续读取原始字节流，解析为 标准化的 LSL 数值流 HB_Respiration_HKH（type=Respiration，单通道），与 Polar 的多路 PB_* 流在同一时间基线上汇合。这样做的收益是：呼吸信号不再依赖手机链路，延迟与不确定性更小；下游仍然以统一的 LSL/XDF → CSV 规范消费数据，实现“多设备、双路径，但同一规范”的采集与复盘。

### IOS 部分

手机端是一个面向用户的“采集工作站”。最高层的指令来自研究者的点击与选择，这些操作转交给全局状态机 `AppStore.swift`（AS）统一调度。AS 的职责是“把用户意图翻译成设备级动作”：它在应用启动时即要求 `PolarManager.swift`（PM）开始扫描，记录发现的设备清单和状态；用户点选设备卡片，AS 决定是连接还是断开，并在连接成功后立刻触发一次“能力探测”。所谓“能力探测”，就是让 PM 通过 Polar SDK 查询此设备可以提供哪些信号、对应的采样率/量程/分辨率能否设置、以及实际可行的组合。AS 把这份能力表投喂给采集页，让“选择数据”卡片只呈现“真的可用”的选项。研究者勾选想要的信号集合后，AS 把选择传回 PM，PM 才会逐条启动对应的 SDK 流。我们刻意把“每条流的开启/关闭”做成相互独立：ECG/ACC/HR/RR/PPG/PPI 之间互不影响，谁被选中谁启动，谁被取消谁停止，避免了“单入口大开关”的锁死问题，也为双设备并行（H10 + Verity）留下了充足余地。

Polar 的 SDK 有一个容易忽略但对实验至关重要的差异：ECG/PPG/ACC 是“等间隔采样”的连续波形；HR 是设备侧估算的瞬时心率；RR 与 PPI 则是“不等间隔事件”，它们每来一条就是一次心搏间期。把这些信号没有被强行揉进一个格式里，而是在 `TelemetryModels.swift` 中给每类信号定义了语义明确、字段自洽的 JSON 报文，例如：`ECG` 带 `uV` 阵列与 `fs`，P`PG` 带 4 通道 22-bit 计数与 fs，`ACC` 带三轴 `mG` 阵列与 `fs`，`HR` 带 `bpm`，`RR/PPI` 则以“单事件”为基本单位，包含 ms 与质量标志；控制流的标记则只是一条带 label 的简洁事件。这样做的价值在于，手机端的 UDP 报文已经有了清晰的物理量与单位，从协议层面把“是什么”说清楚，电脑端不必再去猜测或反推。

真正的时间轴对齐发生在手机端。实验里最难的并不是让两条数据能“同时出现”，而是让它们在下游分析时能“对齐到同一条时间线”。这个需求通过 `BeatEventAligner` 实现：当 `RR/PPI` 这些“不等间隔事件”到来时，`Aligner` 会用设备送来的相对时间 + 本机稳定时钟去推算这个心搏到底“发生在什么时候”。这个推算结果以 `te`（time of event）写回每条 `RR/PPI` 事件。也就是说，`RR/PPI` 在 `UDP` 报文里不只是“间期数值”，还是“带精确事件时间戳的点过程”。后续一旦把 `XDF` 转成 `CSV`，就能看到 `PPI/RR` 除了 `ms` 之外，还有一列 `te`，它处在和 LSL `local_clock` 一致的时标上，和 `ECG/PPG/ACC` 的采样时标天然可对齐。我们没有把这件事丢给电脑端做，是因为跨机推断事件时间不仅会引入额外的不确定性，还会让桥接器背负与设备耦合的复杂逻辑；把它放回 iOS 侧，既贴近数据源，又便于结合 SDK 的已知节奏（例如 Verity 的 PPI 存在慢启动与批量回送），从源头上保证了“Beat 级时间轴”的可复现性。

在复杂网络环境下，UDP 的大包被 IP 分片后更易在途中遗失某个分片而整体作废；同时，Polar 数据属于高频持续上报，若不控制单包尺寸与启停节奏，容易出现“丢包、乱序、状态抖动”等问题。项目在 iOS 端引入了两项稳态机制：尺寸限载（capping）与启停排队（per-device op queue）。前者在序列化的最后一步，按“负载上限（默认 1200B，可在设置页修改）”动态缩减批量样本数，确保每个 UDP 报文足够小，从源头规避 IP 分片；对等间隔流（ECG/ACC/PPG）会依据通道数与编码尺寸自动计算“本批最多能塞多少样本”，超过即切为多包发送；事件流（RR/PPI/HR/Marker）天然较小，通常无需切分。切分过程中样本顺序、时间戳与序列号完全保真，仅改变“每包承载的样本数”，并在调试日志与 Information 页（若开启）统计切分发生的次数、最小/最大/均值，便于回溯与容量评估。后者针对 Polar SDK 的“流启停是设备内状态机”这一特性，在每台设备内部维护一个串行操作队列：applySelection 先做集合差分（需要停的、需要起的），再把 stop/start 作为有序任务入队执行，同一时刻仅处理一个，并在上一个任务“完成/失败/释放订阅”后才继续下一个，从而消除因并发与重入造成的 "Already in state" 的错误。两项机制对上层透明：App 只关心“勾选了哪些信号”和“目标 UDP 地址”。它们既提高了抗网络抖动与稳定性，又避免对数据语义做任何篡改；是否启用“尺寸限载”与上限阈值，均可在设置页配置，默认值即适配常见 MTU 的安全水位。开发期可用 tcpdump 快速抽检：看到 UDP, length < 上限 即代表未触发 IP 分片（必要但不充分），结合 PC 端 LSL 的到达率/乱序统计即可闭环验证。

### UDP-LSL桥接

发包设计秉持“保守而简单”的原则。手机端的 `UDPSenderService` 只做三件事：接受 AS 的目标地址设置（目前手动在 App 中录入电脑的局域网 IP 和端口，避免移动端 mDNS 各种边界问题），建立/维护 `UDP socket`，按序把 JSON 文本送出去。每条报文都带上本机时间戳与必要的元数据，便于电脑端在极端情况下做基本容错。App 端无须知道电脑端有没有 LabRecorder 正在录，甚至不知道有无桥接器在运行，只需“持续广播”。这让用户操作的故障模式可控：如果电脑端短时离线，手机端不会崩溃；桥接器恢复后能立即接续；LabRecorder 可在任何时刻开始或停止。

### Polar UDP-LSL桥接

电脑端的职责更加单一。统一入口脚本 `polar_bridge.py` 启动后会打印本会话 `ID`、`UDP` 监听地址、旁路日志路径，并立即创建两条“基础” LSL 流：`PB_UDP`（所有原始 JSON 文本照单全收，便于事后排查）与 `PB_MARKERS`（只收控制流的文本标签）。随后，hub 载入“翻译器”（当前是 `polar_numberic.py`），它的工作原则很像“编解码插件”：遇到 `{"type":"ecg"}` 就把阵列解包、附上单位和标称采样率，映射到 `PB_ECG_H10` 这样的数值型 LSL 流；遇到 `{"type":"ppg"}` 就生成 `PB_PPG_Verity` 四通道流；`ACC` 则是三通道 `mG`；`HR` 映射为事件型 `bpm` 流；`RR` 和 `PPI` 则映射为“单事件”流，其中 `PPI` 按 Polar SDK 的定义扩成五通道：`ms, quality, blocker, skinContact, skinSupported`。翻译器只做“面向物理量的轻处理”，不做任何跨设备、跨时钟的复杂推断，不做分析意义上的清洗或滤波，也不做二次估计；它只负责把 iOS 端已经说清楚的报文，尽可能“无损”地转为 LSL 生态熟悉的结构与单位。首次见到某类报文时，hub 会即时创建对应的 LSL 流并在控制台打印 "[LSL] create PB_... stype=... ch=... fs=..."，提醒 LabRecorder 端刷新；`PPI` 因为设备端批处理，会在会话开始十几秒后才出现，此时 hub 会后补创建该流。整个过程中，基础文本流 `PB_UDP` 一直在旁路记录所有原始 JSON，便于对照核验或重放。

`polar_bridge` 在控制台按流持续输出网络体征：丢包率、到达速率、抖动与近 60 秒缺口计数；同时通过 Mac↔iOS 的轻量 Ping/Pong 计算 RTT 与主机时钟偏移，用于标注“网络在何时开始变差”。所有指标会以 JSONL 同步落盘，配套脚本 `dp_packet_quality_report.py` 可一键生成 Markdown 报告与曲线（RTT、loss、gap 率），给出“可用/警告/不建议”的人话结论。默认已把 Ping/Pong 流量排除在丢包统计之外，避免误判。若遇到拥堵网络，建议将单包负载上限从 1200B 下调到 600–900B，并优先使用手机热点或电脑端互联网共享以减小分片与竞争。

为降低单点失败风险，提供与 LabRecorder 并行的镜像录制：运行 `lsl_mirror.py` 自动发现当前会话的全部 LSL 流，并将每条流实时写入 `../Data/mirror_lsl_data/<会话>/` 下的 Parquet。镜像不依赖 LabRecorder，可独立回放或导出；脚本 `mirror_parquet_to_csv.py` 会把镜像数据转换为与主线 `xdf_to_csv.py` 相同命名与列规范的 CSV，便于后续工具直接复用。为验证一致性，`compare_mirror_vs_main.py` 采用“流覆盖一致性 + Markers（baseline/stop）对齐 + 分段统计 + 抽样时间快检”的口径，避免用总行数/起止时间这种易误导指标，能快速判断“镜像是否可作为主线的等价备份”。

完成记录之后，需要对记录的数据质量评估。`polar_check_xdf.py` 先做结构体检：它读取 `XDF`，罗列出现了哪些流、每条流的通道数/采样率/时长、是否覆盖实验时间段、是否缺口过大等，并给出“是否达到预期”的直观结论；如果只看到基础流、看不到数值流，它会提示“可能手机端尚未开始采集或 PPI 慢启动”。随后可以用 `xdf_to_csv.py` 把各流转为 `CSV`，同时生成一份文字报告，清楚写出每个 `CSV` 的含义、单位、行列数，尤其把 `RR/PPI` 的 `te` 一并落列，减少后续对齐的摩擦。最后，`polar_data_plot_validity.py` 画出 `HR` vs `PPI/RR` 的叠加、`PPG` 连续性与通道一致性、`ACC` 活动指数、`Poincaré/Tachogram` 等，并给出依据经验阈值的 `PASS/WARN/FAIL` 判定。这样，实验当场就能知道“这段数据能不能用”，避免把不合格的记录带回去才发现问题。

所有这些机制最终指向两点：一是职责清晰。iOS 端用 PM + AS 面向设备和用户，把可订阅能力、流的生命周期、Beat 级 te 对齐、UDP 发包做好；电脑端用一个 `bridge_hub.py` 承担所有外设对接，翻译器以“插件”方式增删，不会把核心桥接器越改越大；记录之后的检查/转换/可视化独立成工具脚本，互不污染。二是时间轴可信。等间隔的波形流（`ECG/PPG/ACC`）靠 LSL 的 `local_clock` 保序；不等间隔事件（`RR/PPI`）靠 iOS 侧的对齐器给出 `te`；控制流的标记单独存在，不混淆物理量。哪怕设备在会话中段加入，或 `PPI` 晚到，只要 `te` 在，后续就能严谨地把它们拼回同一条时间线。

### 呼吸带

呼吸带的桥接遵循与 UDP 端同样的“保守而简单”原则。入口脚本 `src/bridges/HKH/hkh_bridge.py` 只做三件事：占有并管理串口：独占打开指定 COMx，按厂商协议发送“启动/停止测量”指令，处理异常与重连；解析与时间戳：将设备回送的两字节幅值解码为整型呼吸波形，使用 `LSL local_clock` 为每个样本打点（采样率约 50 Hz），不在电脑端做任何二次估计或滤波；流构建与旁路预览：首次收到有效数据时即时创建 `HB_Respiration_HKH` 数值流（`type=Respiration，channel_count=1，channels[0].label="Breathing"，unit="arbitrary_units"`），并同步写出一份轻量 预览 CSV（默认 `data/recorder_data/HKH/preview_*.csv`），便于当场查错。LSL流命名与通道规范与 Polar 保持一致：前缀区分来源（`PB_* / HB_*`），`type` 用于算法自动分流。HKH 的下游 CSV 列表遵循 Polar 的时间标记口径：`["time_lsl","BreathingValue"]`，其中 `time_lsl` 与各等采样流共享同一时标，保证跨设备“锁时”整合。实验标记仍通过 `PB_MARKERS` 文本流记录，HKH 不再重复承载控制语义，从而保持物理量与控制量的分离。

运行方式与并行策略与 UDP 侧完全对齐：可在同一会话中同时启动 `src/bridges/Polar/poloar_bridge.py` 与 `src/bridges/HKH/hkh_bridge.py`，LabRecorder 将动态发现并列出 PB_* 与 HB_Respiration_HKH 两类流；镜像脚本 `lsl_mirror.py` 无需改动即可全量订阅两路来源作为冗余备份。此外，`src/tools/xdf_to_csv.py`：从 XDF 提取 `type=Respiration` 的 HKH 流，输出到 `data/recorder_data/HKH/<stem>/<stem>_Respiration_HKH.csv`，列规范为 `["time_lsl","BreathingValue"]`。脚本在开始时打印解析到的 LSL 流清单与输出路径，并生成简要文字报告（行数、时长、采样率估计），口径遵循 `xdf_to_csv.py` 规范。

这组新增能力确保 HKH 的“串口→LSL→XDF→CSV”路径与 Polar 的“UDP→LSL→XDF→CSV”在接口层完全同构：上游各用最稳妥的链路，下游统一由 LSL/XDF 驱动的工具栈接管。实际搭实验时，只需在桥接层多启动一个进程；录制与复盘的心智模型与原先保持一致。在实验一线，这种设计有很务实的收益：操作者只要运行一个脚本就能开始；设备连接、勾选信号、打标记的心智模型和“真实实验”一致；录完立刻能看到是否达标；如果需要切换或新增设备，只要给翻译器补一小段“怎样把它变成 LSL 的数值流”即可，无须动桥接器和 App 的主干。我们认为这正是“工程为实验服务”的应有姿态。

## 代码结构与职责

仓库分为两端：**iOS 采集端**与**桌面桥接/检查端**。两端职责边界清晰、互不越界。

**iOS 采集端（PolarBridge App）**

- `AppStore.swift`（全局状态 / 协调中心）  
    应用的“总控台”。单一数据源，管理蓝牙可用性、设备连接摘要、信号选择、采集生命周期（开始/停止/计时）、Subject 信息与 UI 派生状态；对 `PolarManager` 做选择下发（`applySelectionToConnectedDevices()`），并承接设置页的配置变更（UDP 目标、功能开关），统一广播给业务层。
    
- `FeatureFlags.swift`（特性开关与参数）  
    `progressLogEnabled`（采集进度卡可视化）、`cappedTxEnabled`（尺寸限载开关）、`maxPacketBytes`（单包上限，默认 1200B，可改 600–900B 以降丢包风险）。
    
- `PolarManager.swift`（设备接入 / 数据源头）  
    封装 Polar BLE SDK：扫描、连接、能力探测与订阅装配；为 ECG/ACC/PPG/HR/RR/PPI 建立流并在回调里完成样本打包与 UDP 发送；内置每设备串行操作队列，保证启停顺序化；实现尺寸限载（定频流按通道×分辨率计算批量上限，超出则切包）；保持序列号与时间戳一致性。
    
- `UDPSenderService.swift`（轻量 UDP 传输层）  
    管理连接、目标地址应用与异步发送队列。只负责“把字节送出”，不参与业务语义。
    
- `TelemetryModels.swift`（传输模型）  
    UDP JSON 事实标准：不同信号使用各自语义与单位。RR/PPI 事件含 `te`（事件时刻，便于与 LSL 对齐）。Marker 以简洁文本事件承载。
    
- 其余 UI/状态文件（`CollectView`、`SettingsView`、`ProgressLogView*`、`BluetoothManager.swift` 等）与原说明一致。
    

**桌面桥接/检查端（LSL 桥接与工具链）**

> 根目录：`src/`；公共路径常量：`/paths.py`。所有脚本均推荐用 `python -m 包.模块` 方式运行（无需手动改 `sys.path`）。

- **桥接层（bridges/）**
    
    - `src/bridges/Polar/polar_bridge.py`  
        监听 UDP，创建基础文本流 `PB_UDP`（原始 JSON 旁路）与 `PB_MARKERS`（控制流标签），并把数值报文送入翻译器。  
        与下游配套的流命名规范：`PB_<KIND>_<DEVICE>`（如 `PB_ECG_H10`、`PB_PPG_Verity`）。
        
    - `src/bridges/Polar/polar_parser.py`  
        把 iOS JSON 无损映射为数值型 LSL（ECG/PPG/ACC/HR/RR/PPI），含通道 label、单位与标称采样率。
        
    - `src/bridges/HKH/hkh_bridge.py`  
        **串口→LSL**：独占打开 `COMx`（115200, 8N1），按协议发送“启动/停止测量”，解析二字节幅值，基于 LSL `local_clock` 打时间戳，创建单通道流 **`HB_Respiration_HKH`（type=`Respiration`）**。并行生成一份**预览 CSV**（用于当场查错）：`data/recorder_data/HKH/preview_*.csv`。
        
- **通用工具与基建（utils/）**
    
    - `paths.py`：统一的数据与输出路径（如 `RECORDER_DATA_DIR`、`PROCESSED_DATA_DIR`）。
        
    - `lsl_registry.py`：LSL outlet 注册与复用。
        
    - `clock_sync.py`：时钟/偏移提示。
        
    - `json_guard.py`、`stream_metrics.py`：输入健壮化与基础指标统计。
        
    - 其他小工具（迭代中补充）。
        
- **数据转换与质量检查（tools/）**
    
    - `xdf_to_csv.py`：Polar 多流通用 XDF→CSV（输出到 `data/recorder_data/Polar/...`）。
        
    - `lsl_mirror.py`：订阅会话内全体 LSL 流做冗余镜像（Parquet 到 `data/mirror_data/<session>/`）。
        
    - `mirror_parquet_to_csv.py`：镜像 Parquet → 与主线一致命名/列的 CSV。
        
    - `udp_packet_quality_report.py`：把桥接端网络指标汇总为报告与图表（若你使用 UDP 路径）。
        
    - `compare_preview_vs_xdf.py`：**预览 CSV vs XDF→CSV** 一致性对齐与指标（相关、MAE/RMSE、偏置、叠加图）。
        
---

## 构建与运行

**iOS 端**  
设备与系统、依赖与网络要求同前述，不再赘述。

**桌面端**

- 操作系统：macOS/Windows/Linux
    
- Python：3.10/3.11
    
- 依赖（含 Parquet/绘图）：
    
    `pip install pylsl pyxdf numpy pandas matplotlib pyarrow`
    
- LabRecorder：按平台下载解压即可运行。
    

---

## 采集流程

1. **启动桥接**：运行 `bridge_hub.py`。终端会显示会话 ID、UDP 监听（默认本机 IPv4:端口）、已加载翻译器与日志目录：`UDP2LSL/logs/<会话>/metrics.jsonl`。
    
2. **（可选）启动镜像**：另开终端（或在编辑器新控制台）运行 `lsl_mirror.py`。它会自动发现当前 LSL 流，并实时写入 `UDP2LSL/Data/mirror_lsl_data/<会话>/`。按 **ESC** 停止镜像。
    
3. **手机端设置**：在 App 的设置页填入电脑 IPv4 与端口（与 `bridge_hub.py` 一致）。
    
4. **连接设备与选择信号**：在 App 连接 H10/Verity，勾选需要的 ECG/ACC/PPG/HR/RR/PPI。提示：Verity 的 PPI 通常在开始后十几秒才出现。
    
5. **LabRecorder 录制**：打开 LabRecorder，看到 `PB_*` 数值流与 `PB_MARKERS` 后点击 **Start**。若提示离线流，先让手机开始 2–3 秒再刷新选择。
    
6. **打标与结束**：在 App 打 baseline/诱导/干预等标记。结束顺序建议：先手机端停止采集，再 LabRecorder **Stop**，最后在镜像终端按 **ESC** 停止（若开启了镜像）。
    
7. **（可选）网络质量报告**：运行 `udp_packet_quality_report.py`，它会读取 `src/data/recorder_data/logs/<会话>/metrics.jsonl` 并生成 `*_udp_quality.md` 与图（RTT、loss、gap 率，位于同一 `<会话>` 目录）。
    

**数据落地路径（规范）**

- 主线 CSV：`/data/recorder_data/<会话>/..._<kind>_<device>.csv`（由 `polar_xdf_to_csv.py` 生成）
    
- （可选）镜像 Parquet：`/data/mirror_data/<会话>/*.parquet`（`lsl_mirror.py`）
    
- （可选）镜像 CSV：同目录，由 `mirror_parquet_to_csv.py` 生成，命名与主线一致
    
- 网络日志与报告：`data/recorder_data/logs/<会话>/metrics.jsonl`、`*_udp_quality.md`、`*_rtt.png`、`*_ecg_loss.png` 等
    

---

## 数据检查

1）**结构体检（录到“对的流、对的参数”）**  
`polar_check_xdf.py` 打开 `.xdf`，列出各流 name/type/通道/采样率/样本量/时长，对期望流逐项 PASS/WARN/FAIL。典型提醒：仅见 `PB_UDP/PB_MARKERS` 表示手机未开始或 PPI 慢启动；采样率异常请核查设备与 PM 日志。

2）**CSV 导出（标准列与单位）**  
`xdf_to_csv.py` 将 XDF 导出到 `UDP2LSL/Data/main_lsl_data/<会话>/`，并生成文字说明。列规范：

- ECG：`time_lsl, uV`；ACC：`time_lsl, x_mG, y_mG, z_mG`；HR：`time_lsl, bpm`；
    
- RR（H10）：`time_lsl, ms, te`；PPI（Verity）：`time_lsl, ms, quality, blocker, skinContact, skinSupported, te`；
    
- PPG：`time_lsl, ch1…ch4`（22-bit 计数，含环境光通道）。

- Respiration: `time_lsl, breathingValue`。
    

3）**内容体检（图与自动判级，可选）**  
`polar_data_plot_validity.py` 输出 HR↔RR/PPI 叠加、PPG 连续性与一致性、ACC 活动指数、Poincaré/Tachogram 等，并给出 PASS/WARN/FAIL。

4）**镜像一致性（可选，主线与镜像对比）**

- 先对镜像目录运行 `mirror_parquet_to_csv.py`，得到与主线一致的 CSV 命名与列。
    
- 运行 `compare_mirror_vs_main.py`：
    
    - 覆盖一致性：是否录到同一批流；
        
    - Markers 对齐：`baseline_start/stop` 差异 ≤50 ms 视为达标；
        
    - 统计特征：重叠窗口内 mean/median/std/p5/p95/min/max 与覆盖率接近；
        
    - 时间快检：抽样窗口的极值与互相关滞后（`lag_ms≈0` 为理想）。  
        脚本会写 `compare_report.txt` 到主线会话目录。
        

5）**网络质量报告（可选）**  
`udp_packet_quality_report.py` 读取 `logs/<会话>/metrics.jsonl` 并生成报告：

- 建议口径：RTT 中位 <50 ms、稳定丢包 <2%、出现 `gap60s>0` 时定位问题时段；
    
- 若网络波动，建议把 `maxPacketBytes` 调至 600–900B，并优先使用手机热点/电脑“互联网共享”。
    

---

## 注意事项

- **PPI 慢启动**：Verity 的 PPI 为设备端估计并批量回送，开始后十几秒才出现。我们在 iOS 侧为每个事件写入 `te`，用于与等间隔波形对齐。
    
- **HR 与 RR/PPI 的差异**：短时偏差常见；MAE 较大时优先信 RR/PPI，并结合 `quality/blocker/skinContact` 过滤。
    
- **PPG/ACC 固定配置**：Verity PPG≈55 Hz、ACC≈52 Hz；H10 ACC 可 25/50/100/200 Hz；ECG≈130 Hz。按分析目标合理选档，不追求“越高越好”。
    
- **LabRecorder 离线提示**：先让手机采集 2–3 秒，待桥接端打印 `[LSL] create PB_...` 后再在 LabRecorder 勾选与 Start，可减少离线与崩溃。
    
- **网络与防火墙**：手机与电脑同网段；无数据时先核对 IPv4 与端口，并允许 Python 接收 UDP。
    
- **双设备并行**：H10 与 Verity 可同时连接并各自推流；按设备前缀区分（HACC/HHR、VACC/VHR）。
    
- **最简清洗建议**：PPI `blocker==1` 直接丢弃，`quality>30 ms` 丢弃；PPG 做 0.3–0.5 Hz 高通去漂移并带通 0.5–5 Hz；RR 与 ECG R 峰对齐时以 `te` 为准。
