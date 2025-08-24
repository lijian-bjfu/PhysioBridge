## 1. 总览

- 在线链路：Polar SDK（iOS） → JSON over UDP → Python 网关 → LSL → LabRecorder

- 最终Lab Recorder数据格式：XDF（由 LabRecorder 生成）

- 未来进行统计分析时：用 Python 从 XDF 导出为 CSV（每个流一份），再做统计（t 检验、ANOVA、非参数检验等）

## 2. 公共字段

| 字段         | 类型      | 单位 | 含义                                       | 备注                            |
| ---------- | ------- | -- | ---------------------------------------- | ----------------------------- |
| `type`     | string  | —  | 数据类型，固定集合：`hr`/`rr`/`ecg`/`acc`/`marker` | 小写                            |
| `device`   | string  | —  | 设备或逻辑源名称                                 | 当前为 `"H10"`                   |
| `t_device` | float64 | s  | 设备侧时间戳（Unix 秒）                           | MVP 为 iPhone 本机时钟，后续可切换极化设备时钟 |
| `seq`      | uint64  | —  | 流内自增序号                                   | 可选；用于丢包与乱序检测                  |


## 3. 各流定义
### 3.1 HR（每秒心率）

- 语义：按 Polar HR 批中最后一个样本代表该时刻的瞬时心率

- 采样率：约 1 Hz（由设备回调节奏决定）

- 单位：bpm

- JSON 结构：

``` json
{
  "type": "hr",
  "device": "H10",
  "t_device": 1756016501.123,
  "seq": 101,
  "bpm": 61
}
```


- 取值范围：通常 40–200（依据被试状态）

- QA 建议：与 RR 转换的一致性检查（见附录）

### 3.2 RR（相邻心搏间期）

- 语义：Polar HR 批次中附带的 rrsMs 序列，逐条展开

- 采样率：不定率（心搏驱动）

- 单位：ms

JSON 结构：
```json
{
  "type": "rr",
  "device": "H10",
  "t_device": 1756016501.123,
  "seq": 55,
  "ms": 1020
}
```

- 取值范围：通常 300–3000 ms

- QA 建议：使用 Kubios 或自编脚本检查 RR 分布的合理性，去除异常高低值与不生理伪差

### 3.3 ECG（心电图）

- 语义：H10 在线 ECG，批量发送

- 采样率：fs = 130 Hz

- 单位：uV（整数微伏）

JSON 结构：
```json
{
  "type": "ecg",
  "device": "H10",
  "t_device": 1756016504.567,
  "seq": 12,
  "fs": 130,
  "uV": [369, 364, 362, ...],
  "n": 73
}
```

- 取值范围：典型 R 波尖峰数千 μV（个体差异、佩戴与皮肤电阻影响较大）。

- QA 建议：绘制时域波形识别 QRS 波群；与 Kubios 的滤波与 R 峰检测结果做趋势一致性核验。

### 3.4 ACC（三轴加速度）

- 语义：H10 三轴体动，加速度计批量输出

- 采样率：fs = 25/50/100/200 Hz（当前采用 50 Hz）

- 单位：mG（毫重力）

JSON 结构：
``` json
{
  "type": "acc",
  "device": "H10",
  "t_device": 1756016504.749,
  "seq": 87,
  "fs": 50,
  "mG": [[x,y,z], [x,y,z], ...],
  "n": 36,
  "range_g": 4
}
```

- 典型范围：静息状态下接近重力方向 ~ ±1000 mG，横向/前后小幅波动 10–100 mG；大幅运动时可接近量程边界。

- QA 建议：计算幅度向量 sqrt(x^2+y^2+z^2) 并观察活动段与静息段差异；用于 ECG 伪迹标记参考。

### 3.5 MARKER（实验事件）

- 语义：实验阶段标记、按钮事件等

- JSON 结构（如启用）：
```json
{
  "type": "marker",
  "device": "app",
  "t_device": 1756016506.001,
  "seq": 12,
  "label": "stim_start"
}
```
## 4. LSL/XDF 映射建议
| 流名（LSL）      | 类型      | 通道数 | 采样率 | 单位  | 说明       |
| ------------ | ------- | --- | --- | --- | -------- |
| `PB_HR`      | float32 | 1   | 不定率 | bpm | 每秒心率     |
| `PB_RR`      | float32 | 1   | 不定率 | ms  | IBI/RR   |
| `PB_ECG`     | int32   | 1   | 130 | uV  | 心电原始波形   |
| `PB_ACC`     | int16   | 3   | 50  | mG  | X/Y/Z 三轴 |
| `PB_MARKERS` | string  | 1   | 不定率 | —   | 事件标注     |


- 元数据建议（由 Python 网关写入）：manufacturer, device, range_g, resolution_bits, fs, json_schema_version, etc.

## 5. 时间与对齐

- t_device 为手机时钟。

- 后续：ECG/ACC 使用 Polar 的 timeStamp，在 Python 端将设备时间映射到 LSL 时钟，以减小多设备间的偏移与漂移。

- 多流对齐：建议在导出 CSV 时统一用 LSL 的 time_stamps 作为时间轴；必要时对不定率流插值或做事件对齐。

## 6. QA 检查清单

- 链路：App 采集开始后 ≤2–3 秒内应出现对应流；UDP 丢包率用 seq 递增性评估。

- HR vs RR 一致性：对 10–30 秒窗口，用 HR_est = 60 / (RR_ms / 1000) 的中位数对 HR 的中位数做比较，偏差应在可解释范围内（非同步窗口会有差异）。

- ECG 可视化：130 Hz 还原波形，识别 QRS；与 Kubios 的趋势一致。

- ACC 与伪迹：活动段 ACC 幅度显著高于静息段，能用于标记 ECG 伪迹区间。

- 记录完整性：LabRecorder 产生单一 XDF 文件，包含上述各流；试验后用导出脚本生成 CSV 以便统计。

## 7. 导出建议（XDF → CSV）

- Python 读取 XDF 后，为每个流各出一份 CSV：

- HR：t, bpm, seq

- RR：t, rr_ms, seq

- ECG：t, uV（逐样本一行）

- ACC：t, x_mG, y_mG, z_mG, seq

- 统计时以 CSV 为输入更便利，但XDF 是唯一权威原始记录。