## Polar Bridge

在单一实验环境下，将 Polar H10 等生理传感器的实时数据通过手机端（iOS）采集，经局域网 UDP（User Datagram Protocol，用户数据报协议）发送至上位机，即电脑端，由桥接器（以py脚本的方式实现）转换为 LSL（Lab Streaming Layer，实验室流层）数据流，最终用 LabRecorder 录制为 XDF（Extensible Data Format，可扩展数据格式）文件，供后续统计分析与可视化使用。

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
Polar H10 (BLE)
      │
      │  PolarBleSdk (iOS, Rx)
      ▼
iOS App (PolarManager / AppStore)
  ├─ 选择订阅 HR / RR / ECG / ACC
  ├─ 生成 JSON 包
  └─ UDP 发送至上位机（Host:Port）
      │
      ▼
Python: udp_to_lsl.py
  ├─ 监听 UDP 文本
  ├─ 解析 JSON / 基本容错
  ├─ 输出 LSL 数据流（udp_text）
  └─ 输出 LSL 标记流（Markers）
      │
      ▼
LabRecorder → XDF
      │
      ▼
分析脚本：qa_check.py, plot_check_csv_validity.py
  ├─ 质量核查
  ├─ CSV 导出
  └─ 可视化与标记叠加
```

### IOS 部分

采集工作包含两个不同性质的数据采集流程。第一是采集生理数据本身，即“数据流”。第二是研究者根据实验阶段对数据的标记，如基线、诱导和干预的时间点，用于后续分析中的”锁时“，这个流程定义为“控制流”。两个采集都会执行向UDP发送数据并在UDP所在的局域网进行广播，并由LSL接受广播并记录广播内容（即数据）的流程。只不过“数据流”的广播内容是生理信号，“控制流”的广播内容是时间标记。

### 系统机制

最高层的命令的来自用户，用户选择要连接的Polar设备、需要的数据、对数据进行标注等操作，这些行为涉及了各种系统功能，所有这些功能都由`AppStore.swift`（简称 AS）进行调度和管理。在数据采集方面，获取Polar 设备探测的生理数据主要依赖 Polar SDK。在 IOS 系统中使用`PolarManager.swift`（简称 PM）管理和执行与此相关的任务，包括：扫描(`startScan`)，连接(`connect`) polar 设备，探测可订阅数据(`describeSettings`)，订阅数据(`startHr`)等核心任务流程。发送数据的工作则主要由`UDPSenderService`（简称 UDPSS) 执行，具有使用`recreateConnection()`连接目标地址，使用`send()`来发送数据等功能。整个App主要包含两个界面：主界面`HomeView`，采集页面`CollectView` 。它们负责接受用户的输入，将用户需求转达AS (或其他功能模块)，以及向用户显示交互反馈。

App ~={green}首页`HomeView` （简称 HV ）打开后，立即告诉 PM 扫描设备=~。~={cyan}AS 则在初始化时=~就检测 PM 是否扫描到可用设备，以及与可用设备的连接状态。如果连接上，立即把连接状态记录到系统中，供其他功能或页面在需要时查阅。根据 AS 的记录 HV 将可用的设备显示在界面上，等待用户确认连接。用户点击后，AS 命令 PM 启动连接 (`connect()`) 设备，PM 随后通过 Polar SDK 进行连接，并获得设备 ID。AS 根据 PM 的 设备ID 信息的变化来识别连接状态，一旦确认连接后，立即更新连接记录数据。

设备连接为后续一系列任务铺平道路。首先，HV 可以在界面上向用户报告设备已经连接就绪，暗示用户可以进行下一步操作了。其次，AS 可以明确哪些生理信号可以获取了。比如连接到 H10，可以获取 ecg, hr, rr 等数据，连接到 Verity 则可以获取 ppi, ppg, hr 等数据。这是依靠 PM 的 `probeCapabilities()` 来实现的。PM 会将识别到的可以订阅的数据类型信息保存在 `availableSignals`变量中。再次，`CollectView`（简称 CV） 根据 `availableSignals` 是否有数据，以及有什么数据，可以把这些数据呈现在自己界面的"选择数据"卡片中，让用户进行下一步选择操作。

考虑到实验的灵活性，App允许用户可以从 Polar 设备所提供的数据中自主选择想要的数据。这标表示系统要识别出用户在`availableSignals`选择了哪个数据。CV 把用户的选择结果报告给 AS ，AS 使用 `selectedSignals` 来记录用户感兴趣的数据。同时把`selectedSignals`的信息传递给 PM，让它使用 `applySelection()` 根据用户选择**分别**启动或停止各条 Polar 流（ECG/ACC/HR/RR），每条流独立封装为对应的 JSON 类型（如 `"type":"ecg"` / `"acc"` / `"hr"` / `"rr"`），并启动 `start()`开始订阅数据。以获取 ecg 信息为例，PM 的 `start()` 首先开启 Polar SDK 的 `startEcgStreaming`服务，然后将 SDK 给的数据打包 `sendPacket`，并传给 UDPSS。在技术细节上，由于 SDK 给的 hr, rr 在一个数据，单独建立一个 `startHR()` 方法来获取这些数据，处理方法与ecg 有些不同，但也是在`start()`中来执行。

除了Polar 的生理信号，记录促发这些生理信号的事件“时间点”也非常重要，这体现为用户（也就是实验员）的为数据“打时间标记”操作上，即“控制流”数据。该流程从 CV 发起。AS 接收到 CV 消息后开始执行向 UDP 发送标记信息任务（`emitMarker`）。这个任务要经过三道手。首先是 `MarkerBus` 第一手，它把Mark建构为一个结构化的数据（叫做 marker event ），为Marker添加各中必要的属性。第二道手是 `UDPMarkerBridge`，它进一步对marker数据封装，把数据封装为始于UDP渠道流通的样式（为了让 `UDPMarkerBridge` 始终在线，AS 开始的时候就要初始化 `UDPMarkerBridge`）。接下来才是由UDPSS 负责把信息发送到UDP目标地址。而第一、二两道手还依赖一个IOS提供的底层机制`PassthroughSubject` ，它是那个“事件总线--bus ”或“广播喇叭”的实体。

接下来的环节就是要通过UDP协议把数据传输到电脑端了。UDP需要一系列的任务环节，包括定位UDP发送地址、连接目标地址、向地址发送信号等工作。首先是UDP地址的定位。这个位置实际上是电脑的网络IP。技术上是可以让App自动获取处于同一网络下电脑的位置的，但是这个过程并没有那么容易实现（我没做出来）。因此，退而求其次，目前的方法是让用户自己查找电脑端的IP地址与端口，并通过 HV 界面输入到App中。AS 告诉 UDPSS UDP的目标地址和端口是什么，UDPSS 根据 AS 的消息来更新（`update(host)`）所要发送的目的地信息。总体上，UDP 任务在 AS 的统一指挥下执行，例如指挥 PM 使用 UDPSS 来向UDP发送生理数据，或者指挥打标记工具(`UdpMarkerBridge`)调用 UDPSS 向 UDP 发送打标记信息。

以上是对app的系统机制的综合描述。

## 数据与时间同步

- 手机端每条消息携带 `t_device`（iPhone 当前 `Date().timeIntervalSince1970` 近似）。这一字段**不参与** LSL 锁时，仅用于排查与回放。
    
- 真实的跨设备锁时由 LSL 负责：每条流在 Outlet 端被赋予统一的 LSL 时间戳，Inlet/Recorder 端对时并做缓冲对齐。当有多个设备或多台主机参与时，**尽量让所有数据源都以 LSL 流进入 LabRecorder**，可获得最稳健的时钟对齐。关于 LSL 的 Outlet/Inlet、时间基准与 `push_sample/pull_sample` 可参考官方用户向导与教程。

## 支持的设备与数据流

  
当前已在 iOS 端实现对 **Polar H10** 的连接与订阅：

- HR（heart rate，单位 bpm）与 RR（R-R interval，单位 ms）
    
- ECG（心电图，单位 µV，采样率 130 Hz）
    
- ACC（三轴加速度，单位 mG，常用 25/50/100/200 Hz，量程 2/4/8G）
    

采样特性与可用设置以 Polar 官方 SDK 说明与公开讨论为准：H10 ECG 130 Hz、ACC 多档采样与量程。 [GitHub+1](https://github.com/polarofficial/polar-ble-sdk?utm_source=chatgpt.com)[Apple Developer](https://developer.apple.com/forums/thread/762033?utm_source=chatgpt.com)

> 说明：Verity Sense 等其他设备可按相同框架扩展，建议在 `Telemetry/` 中增加其数据定义，并在 `PolarManager` 中按设备能力探测与开启。

  

## 代码结构与职责

  
- **Core/**
    
    - `PolarManager.swift`：封装 PolarBleSdk 连接、特性探测与各流的启动/停止。将批量数据转成约定 JSON，并通过 `UDPSenderService` 发送。
        
    - `AppStore.swift`：全局状态与 UI 交互协调（所选数据集、采集状态、UDP 目标、受试者信息、标记派发等）。
        
    - `UDPSenderService.swift` / `UdpSender.swift`：面向 UI 的 UDP 发送服务与底层发送器。
        
    - `UdpMarkerBridge.swift` / `MarkerBus.swift`：实验标记事件在 App 内的统一入口，并通过 UDP 发往上位机。
        
    - `DeviceState.swift`：设备连接状态与 UI 映射。
        
    - `Config.swift`：默认 UDP 主机与端口的 AppStorage 键、读写与应用。
        
    - `Telemetry/`：数据定义与统一编码器（例如 `Telemetry.swift`、`TelemetryCodec.swift`）。
        
- **UI/**
    
    - `HomeView.swift`：首页，包含设备卡片、UDP 目标设置弹窗、受试者信息弹窗、任务入口。
        
    - `CollectView.swift`：采集页面，选择数据种类与开始/停止采集，显示订阅状态。
        
    - `DebugView.swift`：调试工具页（可选）。
        
    - `TaskRow.swift`、`DataPill.swift`、`SectionCard.swift` 等 UI 组件。
        
- **UDP2LSL/**
    
    - `udp_to_lsl.py`：UDP 文本 → LSL 数据与标记流。
        
    - `qa_check.py`：XDF 基本质量核查。
        
    - `plot_check_csv_validity.py`：XDF→CSV 导出与图形化快速检查。

## 构建与运行

### iOS 端（Xcode）

- Xcode 15+，iOS 17+（建议）
    
- 通过 SPM 引入 Polar 官方 iOS SDK（已集成，当前测试版本为 6.5.0）。 [GitHub](https://github.com/polarofficial/polar-ble-sdk?utm_source=chatgpt.com)
    
- Info.plist 权限说明建议：
    
    - `NSBluetoothAlwaysUsageDescription`（蓝牙）
        
    - 若启用 mDNS/Bonjour 自动发现，还需 `NSLocalNetworkUsageDescription`（本地网络）。
        
- 真机运行：在 **首页顶部的“设置 UDP”** 中手动填写上位机的 IP 与端口（例如 `192.168.1.104:9001`），确保手机与上位机处于同一局域网。
    

### 上位机（macOS / Windows / Linux）

- Python 3.10+
    
- 依赖：`pip install pylsl numpy pandas matplotlib zeroconf`
    
    - 若不使用自动发现，可不安装 `zeroconf`。
        
- 启动桥接：
```bash
python UDP2LSL/udp_to_lsl.py
```
终端应显示监听地址与 LSL outlet 名称。随后在 **LabRecorder** 中勾选 `PB_UDP_TEST` 与 `PB_MARKERS_TEST` 两路流，点击 `Start` 开始录制，完成后 `Stop` 写出 XDF。
## 采集流程

- **佩戴与连接**：佩戴 Polar H10，打开 App 首页，等待扫描到设备后点击连接。
    
- **设置 UDP**：在首页顶部设置上位机的 `Host:Port`。
    
- **受试者信息**：填写 `PID`（参与者编号）与 `SESSIONID`（测试编号），生效后会广播到 LSL 标记流（用于后续分段与追溯）。
    
- **进入采集页**：在 CollectView 勾选需要的信号（HR / RR / ECG / ACC）。
    
- **上位机就绪**：运行 `udp_to_lsl.py`，打开 LabRecorder 勾选两路流后 `Start`。
    
- **开始采集**：点击“开始采集”，在对应阶段点击“基线开始 / 诱导开始 / 诱导结束 / 干预开始 / 干预结束”以产生实验标记。
    
- **结束与保存**：采集完成后停止 LabRecorder，得到 XDF 文件。
    
- **质量核查**：用 `qa_check.py` 与 `plot_check_csv_validity.py` 检查与导出。
## UDP 文本格式与 LSL 映射

  所有 UDP 负载均为**单行 JSON 文本**；Python 端按 `type` 字段分流到数据 Outlet 或标记 Outlet。字段含义如下：

### HR（心率）

```json
{"type":"hr","bpm":61,"t_device":1756006511.3267,"device":"H10"}
```
- `bpm`：心率，beats per minute
    
- `t_device`：手机本地时间（秒，双精度）
    
- `device`：设备名（如 "H10"）
    

### RR（心搏间期）
```json
`{"type":"rr","ms":997,"t_device":1756006511.3267,"device":"H10"}`
```
- `ms`：相邻 R 波间期，毫秒
    

### ECG（心电图，批量）
```json
{   "type":"ecg",   "fs":130,   "uV":[369,364,362,...,147],   "n":73,   "seq":6,   "t_device":1756013680.9701,   "device":"H10" }
```

- `fs`：采样率（Hz，H10 为 130）
    
- `uV`：当前批次的微伏序列
    
- `n`：批次样本数（冗余字段）
    
- `seq`：批次序号，单调递增，便于完整性检查
    

### ACC（三轴加速度，批量）
```json
{   "type":"acc",   "fs":50,   "range_g":4,   "mG":[[x,y,z], ...],   "n":36,   "seq":3,   "t_device":1756006515.4698,   "device":"H10" }
```

- `mG`：毫重力单位的三轴序列
    
- `range_g`：量程（±2/4/8G）
    

### 标记（Markers）

标记在 Python 端以 LSL Markers 专用流输出，记录事件名称与到达时刻；在 App 内通过 `UdpMarkerBridge` 统一发送。

> 说明：“心跳保活”类内部消息不会导入分析，桥接脚本已屏蔽或单独统计。
## 质量核查与可视化

仓库提供两类下游工具：

- **`qa_check.py`**
    
    - 快速汇总 XDF 文件中数据与标记流的样本数与时间跨度，校验标记条数与命名是否达标。
        
- **`plot_check_csv_validity.py`**
    
    - 从 XDF 提取 HR/RR/ECG/Markers，导出 CSV，并绘制 HR/RR/ECG 三张曲线图；
        
    - 进行采样完整性（ECG 样本数与采样率的一致性）、时间一致性（ECG Δt 与 1/fs 的偏差）、HR 与 RR 的一致性（60000/RR 与 HR 的误差）等检查，输出 `qa_report.txt`。
        

两者均可在 IDE 内直接运行，或命令行运行（支持图形选择器选择文件/目录）。
## 已知限制

- **采样率与分辨率**：H10 的 ECG 固定 130 Hz，ACC 提供多档采样率与量程。HR/RR 为设备内部检测与统计结果，不等同于对 ECG 的后验计算。 [GitHub](https://github.com/polarofficial/polar-ble-sdk/issues/169?utm_source=chatgpt.com)[Apple Developer](https://developer.apple.com/forums/thread/762033?utm_source=chatgpt.com)
    
- **mDNS/Bonjour 自动发现**：目前默认关闭，建议在多网络环境明确手动设置 `Host:Port`，避免被链路本地地址污染（169.254.x.x）。
    
- **iOS 后台限制**：当前采集流程设计为前台操作；若需长时间后台采集，需要评估系统限制与功耗表现。
    
- **UDP 丢包**：ECG/ACC 采用批量发送以降低包数，下游按批写入 LSL，如需进一步丢包鲁棒，应考虑重试与次序校验策略。
## 后续计划

1. **Windows 迁移与多设备同步**
    
    - 上位机脚本与 LabRecorder 本身跨平台，无需改动即可在 Windows 上使用。
        
    - 对将来的**呼吸传感器**（Windows 专用软件）建议开发一个独立的 UDP→LSL 适配器，将该软件的串口/Socket 输出转报文，映射到 LSL。所有流在 Recorder 汇合，LSL 统一锁时。
        
    - 标记来源统一：建议用**上位机“标记面板”**发 LSL Markers，或保持手机端为唯一标记源，并在其他上位机上只读入 Marker 流。这样可避免多端并发发标记带来的偏移。
        
2. **数据定义稳定化与文档化**
    
    - 将本 README 中的数据定义拆分为 `docs/data-format.md`，补充字段取值范围与边界情形（缺包、断连恢复）。
        
    - 为 `Telemetry/` 中的编码器增加版本号与兼容策略，便于将来扩展 Verity Sense 等设备。
        
3. **质量核查增强**
    
    - 在 `plot_check_csv_validity.py` 中加入更多异常检测：大幅运动伪迹时段自动标注、ACC 导出的能量阈值筛查、ECG 峰值饱和检测等。
        
    - 生成一页式 HTML 报告（图+表），与 CSV 同目录输出。
        
4. **实验范式模板**
    
    - 在 App 端预置“基线/诱导/干预”时长与顺序模板；
        
    - 录制结束自动写入一份 JSON 元数据（PID、SESSIONID、所选流、采样设置、UDP 目标、录制时长与标记日志摘要），与 XDF 同名保存。

## 参考资料

- Polar 官方 BLE SDK（含 iOS）与 H10 说明、采样特性。 [GitHub+1](https://github.com/polarofficial/polar-ble-sdk?utm_source=chatgpt.com)
    
- LSL 用户向导与低层 API（Outlet/Inlet、push/pull、时钟）。 [labstreaminglayer.readthedocs.io](https://labstreaminglayer.readthedocs.io/info/user_guide.html?utm_source=chatgpt.com)[mne.tools+1](https://mne.tools/mne-lsl/stable/generated/tutorials/10_low_level_API.html?utm_source=chatgpt.com)
    
- 关于 H10 ECG 分帧与 130 Hz 采样的开发者讨论。 [Apple Developer](https://developer.apple.com/forums/thread/762033?utm_source=chatgpt.com)

## 贡献与许可

- 本仓库为研究用途原型。欢迎 issue 反馈与 PR。许可与致谢请见 `LICENSE`（若未添加，可根据需要选用 MIT/BSD-3-Clause 等宽松协议）。

### 附：典型运行要点清单

- iOS 端
    
    - 首页确认“设置 UDP”为目标上位机 IP 与端口。
        
    - 连接 H10 后进入采集页，勾选 HR/RR/ECG/ACC，按需打标记。
        
- 上位机
    
    - 先运行 `udp_to_lsl.py`，再在 LabRecorder 里勾选 `PB_UDP_TEST` 与 `PB_MARKERS_TEST`；录制期间保持两路为 “green”。
        
    - 录制完成后，使用 `qa_check.py` 与 `plot_check_csv_validity.py` 做快速检查。
        

---

> 注：上文对 LSL 的简述与术语解释引用了公开文档与教程；Polar H10 的采样特征与能力以 Polar 官方 SDK 与开发者讨论为依据。请以设备固件与 SDK 版本最新说明为准。 [labstreaminglayer.readthedocs.io](https://labstreaminglayer.readthedocs.io/info/user_guide.html?utm_source=chatgpt.com)[mne.tools](https://mne.tools/mne-lsl/stable/generated/tutorials/10_low_level_API.html?utm_source=chatgpt.com)[GitHub+1](https://github.com/polarofficial/polar-ble-sdk?utm_source=chatgpt.com)[Apple Developer](https://developer.apple.com/forums/thread/762033?utm_source=chatgpt.com)
