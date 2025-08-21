# peek_lsl.py
from pylsl import StreamInlet, resolve_byprop
print("Resolving PB_UDP ...")
streams = resolve_byprop('name','PB_UDP', timeout=5)
if not streams:
    print("PB_UDP not found")
    raise SystemExit(1)
inlet = StreamInlet(streams[0], max_buflen=60)
print("Connected. Reading 10 samples:")
for i in range(10):
    sample, ts = inlet.pull_sample(timeout=2)
    if sample is None:
        print("timeout")
    else:
        print(i+1, ts, sample[0])
