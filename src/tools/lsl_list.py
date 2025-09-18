from pylsl import resolve_streams
for s in resolve_streams(wait_time=2.0):
    print(f"-------------------name={s.name()} ")
    print(f"-------------------type={s.type()} ")
