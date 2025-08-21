from pylsl import StreamInfo, StreamOutlet
import time

# 定义一个文本类型的 Marker 流（1 通道，0Hz，字符串）
info = StreamInfo(name="Markers", type="Markers", channel_count=1,
                  nominal_srate=0, channel_format="string", source_id="marker_demo")
outlet = StreamOutlet(info)

print("sending markers every second...")
i = 0
while True:
    tag = f"MARK_{i}"
    outlet.push_sample([tag], time.time())  # 时间戳用本机时钟
    print("sent", tag)
    i += 1
    time.sleep(1.0)
