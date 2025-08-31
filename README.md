## Polar Bridge

本项目将 Polar 生理传感器（ H10、Verity等 ）的实时数据通过手机端（iOS）采集，经局域网 UDP（User Datagram Protocol，用户数据报协议）发送至上位机，即电脑端，由桥接器（以py脚本的方式实现）转换为 LSL（Lab Streaming Layer，实验室流层）数据流，最终用 LabRecorder 录制为 XDF（Extensible Data Format，可扩展数据格式）文件，供后续统计分析与可视化使用。

本项目的目标场景是心理与人机实验中的多模态生理信号采集与对齐：例如在“基线/诱导/干预”三阶段范式里，同时记录Polar设备，如Verity Senser、H10等提供的心率（HR）、心搏间期（RR）、心电图（ECG）、PPI、PPG与三轴加速度（ACC），配合实验标记（Markers）保证后续分段与统计检验的可重复性。

整体的工作流程可分三大部分。（1）数据采集。（2）建立UDP通道并发送数据。（3）接受数据并在LSL中同步记录数据。本项目中，数据采集由Polar设备执行。项目开发的App负责提取这些数据、与UDP连接与发送的工作。在电脑端运行的py脚本负责LSL环节的工作。其原理是Polar捕获到生理信号后，由App将这些数据拿到手。App接着主动地找到用于保存数据的电脑所载的位置，也就是负责记录数据的电脑的网络地址，这就是所谓的“UDP目标”。然后向该地址发送数据。电脑则负责监听本地网络环境是否有信号传过来，不论什么信号、多少信号会全部接受，并通过LSL技术同步把这些信号记录下来。

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

这套系统面向真实实验场景里“生理信号 + 行为/阶段标记”并行采集与复盘的需求。合理分开手机端（iOS）和电脑端（UDP→LSL 桥接与记录）分工，最大限度地把容易出错的复杂逻辑压回到工程最适合的边界内。研究者操作永远从 iOS 端开始：先在主界面看到可用设备，选择 Polar H10 或 Verity Sense，点击连接；一旦连上，就能在采集页选择要订阅的信号种类。这里有两条性质完全不同但同样重要的“流”：一条叫数据流（ECG、PPG、ACC、HR、RR、PPI 等），另一条叫控制流（实验阶段标记，如 baseline / 诱导 / 干预的起止）。数据流体现“客观生理过程”，控制流承担“时间锚点”。这两条流都走 UDP→LSL 这一条通道，但在协议与 LSL 命名上严格区分：数据流经由数值型 LSL 流（如 PB_ECG_H10、PB_PPG_Verity、PB_RR_H10 等）承载，控制流单独以 PB_MARKERS 文本流记录，保证后续分析可以各取所需地做对齐与统计。

### IOS 部分

手机端是一个面向用户的“采集工作站”。最高层的指令来自研究者的点击与选择，这些操作转交给全局状态机 `AppStore.swift`（AS）统一调度。AS 的职责是“把用户意图翻译成设备级动作”：它在应用启动时即要求 `PolarManager.swift`（PM）开始扫描，记录发现的设备清单和状态；用户点选设备卡片，AS 决定是连接还是断开，并在连接成功后立刻触发一次“能力探测”。所谓“能力探测”，就是让 PM 通过 Polar SDK 查询此设备可以提供哪些信号、对应的采样率/量程/分辨率能否设置、以及实际可行的组合。AS 把这份能力表投喂给采集页，让“选择数据”卡片只呈现“真的可用”的选项。研究者勾选想要的信号集合后，AS 把选择传回 PM，PM 才会逐条启动对应的 SDK 流。我们刻意把“每条流的开启/关闭”做成相互独立：ECG/ACC/HR/RR/PPG/PPI 之间互不影响，谁被选中谁启动，谁被取消谁停止，避免了“单入口大开关”的锁死问题，也为双设备并行（H10 + Verity）留下了充足余地。

Polar 的 SDK 有一个容易忽略但对实验至关重要的差异：ECG/PPG/ACC 是“等间隔采样”的连续波形；HR 是设备侧估算的瞬时心率；RR 与 PPI 则是“不等间隔事件”，它们每来一条就是一次心搏间期。把这些信号没有被强行揉进一个格式里，而是在 `TelemetryModels.swift` 中给每类信号定义了语义明确、字段自洽的 JSON 报文，例如：`ECG` 带 `uV` 阵列与 `fs`，P`PG` 带 4 通道 22-bit 计数与 fs，`ACC` 带三轴 `mG` 阵列与 `fs`，`HR` 带 `bpm`，`RR/PPI` 则以“单事件”为基本单位，包含 ms 与质量标志；控制流的标记则只是一条带 label 的简洁事件。这样做的价值在于，手机端的 UDP 报文已经有了清晰的物理量与单位，从协议层面把“是什么”说清楚，电脑端不必再去猜测或反推。

真正的时间轴对齐发生在手机端。实验里最难的并不是让两条数据能“同时出现”，而是让它们在下游分析时能“对齐到同一条时间线”。这个需求通过 `BeatEventAligner` 实现：当 `RR/PPI` 这些“不等间隔事件”到来时，`Aligner` 会用设备送来的相对时间 + 本机稳定时钟去推算这个心搏到底“发生在什么时候”。这个推算结果以 `te`（time of event）写回每条 `RR/PPI` 事件。也就是说，`RR/PPI` 在 `UDP` 报文里不只是“间期数值”，还是“带精确事件时间戳的点过程”。后续一旦把 `XDF` 转成 `CSV`，就能看到 `PPI/RR` 除了 `ms` 之外，还有一列 `te`，它处在和 LSL `local_clock` 一致的时标上，和 `ECG/PPG/ACC` 的采样时标天然可对齐。我们没有把这件事丢给电脑端做，是因为跨机推断事件时间不仅会引入额外的不确定性，还会让桥接器背负与设备耦合的复杂逻辑；把它放回 iOS 侧，既贴近数据源，又便于结合 SDK 的已知节奏（例如 Verity 的 PPI 存在慢启动与批量回送），从源头上保证了“Beat 级时间轴”的可复现性。

### UDP-LSL桥接

发包设计秉持“保守而简单”的原则。手机端的 `UDPSenderService` 只做三件事：接受 AS 的目标地址设置（目前手动在 App 中录入电脑的局域网 IP 和端口，避免移动端 mDNS 各种边界问题），建立/维护 U`DP socket`，按序把 JSON 文本送出去。每条报文都带上本机时间戳与必要的元数据，便于电脑端在极端情况下做基本容错。App 端无须知道电脑端有没有 LabRecorder 正在录，甚至不知道有无桥接器在运行，只需“持续广播”。这让用户操作的故障模式可控：如果电脑端短时离线，手机端不会崩溃；桥接器恢复后能立即接续；LabRecorder 可在任何时刻开始或停止。

### 电脑端

电脑端的职责更加单一。统一入口脚本 `bridge_hub.py` 启动后会打印本会话 `ID`、`UDP` 监听地址、旁路日志路径，并立即创建两条“基础” LSL 流：`PB_UDP`（所有原始 JSON 文本照单全收，便于事后排查）与 `PB_MARKERS`（只收控制流的文本标签）。随后，hub 载入“翻译器”（当前是 `polar_numberic.py`），它的工作原则很像“编解码插件”：遇到 `{"type":"ecg"}` 就把阵列解包、附上单位和标称采样率，映射到 `PB_ECG_H10` 这样的数值型 LSL 流；遇到 `{"type":"ppg"}` 就生成 `PB_PPG_Verity` 四通道流；`ACC` 则是三通道 `mG`；`HR` 映射为事件型 `bpm` 流；`RR` 和 `PPI` 则映射为“单事件”流，其中 `PPI` 按 Polar SDK 的定义扩成五通道：`ms, quality, blocker, skinContact, skinSupported`。翻译器只做“面向物理量的轻处理”，不做任何跨设备、跨时钟的复杂推断，不做分析意义上的清洗或滤波，也不做二次估计；它只负责把 iOS 端已经说清楚的报文，尽可能“无损”地转为 LSL 生态熟悉的结构与单位。首次见到某类报文时，hub 会即时创建对应的 LSL 流并在控制台打印 "[LSL] create PB_... stype=... ch=... fs=..."，提醒 LabRecorder 端刷新；`PPI` 因为设备端批处理，会在会话开始十几秒后才出现，此时 hub 会后补创建该流。整个过程中，基础文本流 `PB_UDP` 一直在旁路记录所有原始 JSON，便于对照核验或重放。

完成记录之后，需要对记录的数据质量评估。`polar_check_xdf.py` 先做结构体检：它读取 `XDF`，罗列出现了哪些流、每条流的通道数/采样率/时长、是否覆盖实验时间段、是否缺口过大等，并给出“是否达到预期”的直观结论；如果只看到基础流、看不到数值流，它会提示“可能手机端尚未开始采集或 PPI 慢启动”。随后可以用 `polar_xdf_to_csv.py` 把各流转为 `CSV`，同时生成一份文字报告，清楚写出每个 `CSV` 的含义、单位、行列数，尤其把 `RR/PPI` 的 `te` 一并落列，减少后续对齐的摩擦。最后，`polar_data_plot_validity.py` 画出 `HR` vs `PPI/RR` 的叠加、`PPG` 连续性与通道一致性、`ACC` 活动指数、`Poincaré/Tachogram` 等，并给出依据经验阈值的 `PASS/WARN/FAIL` 判定。这样，实验当场就能知道“这段数据能不能用”，避免把不合格的记录带回去才发现问题。

所有这些机制最终指向两点：一是职责清晰。iOS 端用 PM + AS 面向设备和用户，把可订阅能力、流的生命周期、Beat 级 te 对齐、UDP 发包做好；电脑端用一个 `bridge_hub.py` 承担所有外设对接，翻译器以“插件”方式增删，不会把核心桥接器越改越大；记录之后的检查/转换/可视化独立成工具脚本，互不污染。二是时间轴可信。等间隔的波形流（`ECG/PPG/ACC`）靠 LSL 的 `local_clock` 保序；不等间隔事件（`RR/PPI`）靠 iOS 侧的对齐器给出 `te`；控制流的标记单独存在，不混淆物理量。哪怕设备在会话中段加入，或 `PPI` 晚到，只要 `te` 在，后续就能严谨地把它们拼回同一条时间线。

在实验一线，这种设计有很务实的收益：操作者只要运行一个脚本就能开始；设备连接、勾选信号、打标记的心智模型和“真实实验”一致；录完立刻能看到是否达标；如果需要切换或新增设备，只要给翻译器补一小段“怎样把它变成 LSL 的数值流”即可，无须动桥接器和 App 的主干。我们认为这正是“工程为实验服务”的应有姿态。

## 代码结构与职责

仓库分为两端：**iOS 采集端**与**桌面桥接/检查端**。两端职责边界清晰、互不越界。

**iOS 采集端（PolarBridge App）**

- `AppStore.swift`（AS）：应用的“总控台”。持有全局状态（已发现设备、连接状态、可订阅能力、用户所选信号、UDP 目标等），协调页面与业务模块。对外暴露“我现在该干什么”的单一入口（连接/断开、开始/停止采集、发送标记等）。
    
- `PolarManager.swift`（PM）：和 Polar BLE 设备打交道的唯一模块。负责扫描、连接、能力探测、逐流启动/停止（ECG/ACC/HR/RR/PPG/PPI），并把设备给的数据按**物理语义**封装成 JSON 包（见下一条）。
    
- `TelemetryModels.swift`：**数据协议的事实标准**。不同信号有不同的 JSON 结构与单位：
    
    - ECG：`{"type":"ecg","fs":130,"uV":[…],…}`
        
    - PPG：`{"type":"ppg","fs":55,"ch":4,"mU":[…],…}`（22-bit 原始计数）
        
    - ACC：`{"type":"acc","fs":50|52,"mG":[[x,y,z],…],…}`
        
    - HR：`{"type":"hr","bpm":…}`
        
    - RR：`{"type":"rr","ms":…,"te":…}`（不等间隔事件，带 **事件时刻 te**）
        
    - PPI：`{"type":"ppi","ms":…,"quality":…,"blocker":0/1,"skinContact":0/1,"skinSupported":0/1,"te":…}`
        
    - 标记：`{"type":"marker","label":"baseline_start",…}`
        
- `BeatEventAligner.swift`：把 **RR/PPI** 这种“不等间隔事件”映射到**统一的本地时间轴**。计算得到精确事件时间 `te` 并写回到每个 RR/PPI 事件里（下游 CSV 会落这一列）。
    
- `UDPSenderService.swift`：最小可用的 UDP 客户端。AS 负责告诉它目标 IP:PORT；它只管按顺序把 JSON 文本包发出去。
    
- `HomeView.swift` / `CollectView.swift` / `DeviceState.swift`：UI 与状态渲染。Home 负责发现/连接；Collect 负责信号选择与打标；`DeviceState` 是设备与信号的枚举/映射（含 `sfSymbol`、前缀 VHR/HHR/VACC/HACC 等）。
    
**桌面桥接/检查端（UDP→LSL 与质检工具）**

- `bridge_hub.py`：**唯一需要手动运行的入口**。
    
    1. 开两个“基础” LSL 文本流：`PB_UDP`（原始 JSON 旁路流）和 `PB_MARKERS`（标记流）；
        
    2. 监听 UDP，把 JSON 路由给翻译器；
        
    3. 按需**动态**创建数值型 LSL 流（ECG/ACC/HR/RR/PPG/PPI），并推送样本。
        
- `Translators/polar_numberic.py`：**翻译器插件**。把 iOS 端 JSON 包“无损”转为 LSL 数值流：
    
    - ECG→`PB_ECG_H10`（1ch / 130 Hz / uV）
        
    - ACC→`PB_ACC_H10`（1ch×3 / 50 Hz / mG）、`PB_ACC_Verity`（1ch×3 / 52 Hz / mG）
        
    - HR→`PB_HR_H10`、`PB_HR_Verity`（事件流 bpm）
        
    - RR→`PB_RR_H10`（事件流 ms + te）
        
    - PPI→`PB_PPI_Verity`（事件流 5ch：ms、quality、blocker、skinContact、skinSupported + te）
        
- `Libs/`：桥接侧的小工具
    
    - `lsl_registry.py`（LSL outlet 注册管理）、`json_guard.py`（输入健壮化）、`clock_sync.py`（保留，用于必要的时钟提示）。
        
- `Visual and Check/`：质检与可视化
    
    - `polar_check_xdf.py`：**结构体检**（是否有期望的 LSL 数值流、通道/采样率/跨度/覆盖度）。
        
    - `polar_xdf_to_csv.py`：**规范导出 CSV**（附一份人读得懂的报告），RR/PPI 会把 **te** 落列。
        
    - `polar_data_plot_validity.py`：**内容体检**（HR↔RR/PPI 叠加、PPG 连续性与通道一致性、ACC 活动指数、Poincaré/Tachogram 等，给出 PASS/WARN/FAIL）。
        

---

## 构建与运行

**iOS 端**

- **设备**：Polar H10（胸带，ECG/ACC/HR/RR），Polar Verity Sense（臂带，PPG/PPI/ACC/HR）。
    
- **系统**：建议使用近两代 iOS（例如 iOS 16/17），Xcode 与 SwiftUI 正常构建即可。
    
- **依赖**：Polar BLE SDK 6.5.0（RxSwift 版）、RxSwift、SwiftUI（按项目配置即可）。
    
- **网络**：iPhone 与电脑需在**同一局域网**；App 中手动填电脑的 IPv4 与 UDP 端口。
    

**桌面端**

- **操作系统**：macOS/Windows/Linux 任一可跑 Python 与 LabRecorder 的环境。
    
- **Python**：3.10/3.11（基于 3.11 开发）。
    
- **依赖**（pip 安装）：
    
    `pip install pylsl pyxdf numpy pandas matplotlib`
    
- **LabRecorder**：从 LSL 官方发布页下载对应平台的二进制，解压后直接运行（无需安装）。
    

---

## 采集流程

1. **设备佩戴**  
    H10 置于胸骨上方、良好润湿电极；Verity 紧贴上臂，传感窗朝内、避免强光直射。
    
2. **启动桥接**  
    桌面运行 `bridge_hub.py`。终端会打印会话信息、UDP 监听端口、已加载的翻译器。如果 IP 检测到多张网卡，你会看到一个“建议地址”，以便在手机端填写。
    
3. **填写 UDP 目标**  
    在 App 中设置电脑的 IPv4 与端口（与 `bridge_hub.py` 一致）。

4. **手机端连接设备**  
    打开 App 首页，等待扫描出现设备卡片；点击连接 H10 与/或 Verity。连接成功后，`CollectView` 的“选择数据”会自动显示**当前设备的可用信号**。
    
5. **选择信号并开始采集**  
    在 `CollectView` 勾选需要的信号（ECG/ACC/HR/RR/PPG/PPI）。
    
    - **提示**：Verity 的 **PPI** 属于“慢启动 + 批量回送”，通常**十几秒后**才会出现第一批事件。
        
6. **开启 LabRecorder**  
    先打开 LabRecorder 界面，刷新或等待几秒，直到出现：
    
    - 数值流：`PB_ECG_* / PB_ACC_* / PB_HR_* / PB_RR_* / PB_PPG_* / PB_PPI_*`
        
    - 文本流：`PB_UDP`（旁路）、`PB_MARKERS`（标记）  
        选中需要的流后点击 **Start** 开始录制。

    - 注意：LabRecorder极易崩溃。建议点击开始采集后稍等十几秒，然后停止采集，再开LabRecorder。所有LSL流都选择后，再次手机端开启，可减少 LabRecorder 崩溃概率
        
7. **打标与结束**  
    采集中可在 App 里触发 baseline / 诱导 / 干预等标记（走 `PB_MARKERS` 流）。完成后先在 App 里停止采集，再在 LabRecorder 里 **Stop**。
    
8. **质量体检**  
    用 `polar_check_xdf.py` 打开生成的 `.xdf` 文件，确认结构与覆盖度；再用 `polar_xdf_to_csv.py` 产出规范 CSV 与报告；需要时用 `polar_data_plot_validity.py` 画图与自动判级。
    

---

## 数据检查

**1）结构体检：是否录到“对的流、对的参数”**  
运行 `polar_check_xdf.py`，它会列出所有 LSL 流的 **name / type / 通道数 / 采样率 / 样本量 / 时间跨度**，并对“期望流”逐一 **PASS/WARN/FAIL**。  
常见提醒：

- 只看到 `PB_UDP` 和 `PB_MARKERS` 但看不到数值流：通常是**手机端还未开始采集**；或刚开始就打开 LabRecorder，**PPI 尚未慢启动**。
    
- 采样率异常（比如 PPG ≠ 55 Hz、ACC ≠ 50/52 Hz）：检查设备选择与 PM 的设置日志。
    

**2）CSV 导出：落标准列、带单位与解释**  
运行 `polar_xdf_to_csv.py`，会在同目录产出若干 CSV 与一份文字报告。

- ECG：`time_lsl, uV`
    
- ACC：`time_lsl, x_mG, y_mG, z_mG`
    
- HR：`time_lsl, bpm`
    
- RR（H10）：`time_lsl, ms, te` ← **te 为事件时间（与 LSL local_clock 对齐）**
    
- PPI（Verity）：`time_lsl, ms, quality, blocker, skinContact, skinSupported, te`
    
- PPG：`time_lsl, ch1…ch4`（22-bit 计数；一个为环境光）  
    报告会解释每列含义、单位与基本建议门限。
    

**3）内容体检：图形与自动打分（可选）**  
运行 `polar_data_plot_validity.py`，会针对已导出的 CSV 生成：

- **HR ↔ RR/PPI 叠加**：看 MAE 与偏置；偏差大通常是节律不稳、质量门限过松或事件对齐不足。
    
- **PPG 连续性与通道一致性**：看 completeness 与通道间相关；强光/饱和会让一致性变差。
    
- **ACC 活动指数**：高活动时段标记为 WARN，提示 PPG/RR 可能受伪影影响。
    
- **Poincaré & Tachogram**：节律散点与时域走势，用于直观看 HRV 形态。  
    脚本会给出 **PASS/WARN/FAIL** 及简明理由；“FAIL”通常意味着需要重录或严格清洗。
    

---

## 注意事项

**PPI 的“慢一拍”与延迟出现**  
Verity 的 PPI 流程是**设备端估计 + 批量上报**：开始采集后需要十几秒才会有第一批事件，且相对于 ECG/PPG 有一个“算法与传输延迟”。我们在 iOS 侧已为每个 PPI 事件计算 `te` 并写入报文与 CSV，用它对齐其他流是更稳妥的做法。

**HR 与 RR/PPI 的不一致**  
HR 是设备侧的瞬时估算值，RR/PPI 是实际的间期事件。短时内 HR 与 RR/PPI 推导的 bpm 不完全一致是常见的；若 MAE 较大，优先相信 RR/PPI，并检查 PPI 质量（`quality` 门限、`blocker`、`skinContact`）。

**PPG 的 55 Hz 与 ACC 的固定配置**  
Verity 的 PPG 采样率目前可用档位即约 55 Hz；ACC 为 ~52 Hz（±8 G）；H10 的 ACC 可选 25/50/100/200 Hz（±2/4/8 G），ECG 固定 ~130 Hz。不是“越高越好”，而是“和目标分析匹配最好”。例如 HRV 对 RR/PPI 的采样不敏感，但对事件时间 `te` 的准确性敏感。

**LabRecorder 的“红灯/离线”**  
如果已在 LabRecorder 勾选流，但手机端**尚未产生该流**（例如 PPI 未到），它会报“有离线流”。经验做法：

- 先让手机端开始采集 2–3 秒，等桥接端打印 `[LSL] create PB_...` 后，再回到 LabRecorder 勾选并 Start；
    
- 若出现“离线”残留，关停 LabRecorder 重开即可（它缓存了上一次的流名）。
    

**网络与防火墙**  
手机与电脑必须在**同一网段**。若桥接端长时间没有数据，先检查电脑的 IPv4 是否正确填入 App，macOS 防火墙是否允许 Python 接收 UDP。

**双设备并行**  
H10 与 Verity 可以**同时连接**并各自推流；选择信号时留意“设备前缀”（HHR/HACC、VHR/VACC）。互不影响的逐流开/停是为这个场景设计的。

**数据清洗建议**（最简版）

- PPI：`blocker==1` 直接丢弃；`skinContact==0` 的区段降权或剔除；`quality>30 ms` 丢弃、`20–30 ms` 低权或插值。
    
- PPG：0.3–0.5 Hz 高通去漂移 + 0.5–5 Hz 带通；与 ACC 高活动时段交叉屏蔽。
    
- RR：与 ECG R 峰对齐（若有），以 `te` 为准；大于 20% 的瞬时跳变检查是否为漏搏/伪影。
