import sys
import xml.etree.ElementTree as ET
from collections import defaultdict, Counter

path = sys.argv[1] if len(sys.argv) > 1 else 'time-profile.xml'
root = ET.parse(path).getroot()

binaries = {}
for b in root.iter('binary'):
    if 'id' in b.attrib and 'name' in b.attrib:
        binaries[b.attrib['id']] = b.attrib['name']

def bin_name(b):
    if b is None: return '?'
    if 'name' in b.attrib: return b.attrib['name']
    return binaries.get(b.attrib.get('ref'), '?')

frames_map = {}
for f in root.iter('frame'):
    if 'id' in f.attrib and 'name' in f.attrib:
        frames_map[f.attrib['id']] = (f.attrib['name'], bin_name(f.find('binary')))

def resolve(f):
    if 'ref' in f.attrib:
        return frames_map.get(f.attrib['ref'], ('?','?'))
    return (f.attrib.get('name','?'), bin_name(f.find('binary')))

threads = {}
for th in root.iter('thread'):
    if 'id' in th.attrib and 'fmt' in th.attrib:
        threads[th.attrib['id']] = th.attrib['fmt']

self_time = defaultdict(float); incl_time = defaultdict(float)
main_total = 0.0; samples = 0
rows_data = []

for row in root.iter('row'):
    thread = row.find('thread')
    if thread is None: continue
    fmt = thread.attrib.get('fmt','') or threads.get(thread.attrib.get('ref'),'')
    if 'Main Thread' not in fmt: continue
    w = row.find('weight'); w = int(w.text)/1e6 if w is not None and w.text else 1.0
    st = row.find('sample-time'); t = int(st.text)/1e6 if st is not None and st.text else 0
    bt = row.find('tagged-backtrace/backtrace')
    if bt is None: continue
    frames = [resolve(f) for f in bt.findall('frame')]
    samples += 1; main_total += w
    if frames: self_time[frames[0]] += w
    for key in dict.fromkeys(frames): incl_time[key] += w
    rows_data.append((t, w, frames))

print(f'main samples={samples} total_ms={main_total:.0f}')
print('\n== top self ==')
for (b,n),t in sorted(self_time.items(), key=lambda kv:-kv[1])[:20]:
    print(f'{t:7.0f} ms  {b:16} {n[:100]}')
print('\n== app inclusive (PostmanSwift) top 25 ==')
app = [((b,n),t) for (b,n),t in incl_time.items() if b=='PostmanSwift']
for (b,n),t in sorted(app, key=lambda kv:-kv[1])[:25]:
    print(f'{t:7.0f} ms  {n[:110]}')

print('\n== hang windows ==')
for center in (22486.93, 23832.29, 30504.28, 50593.78):
    win = [(t,w,f) for (t,w,f) in rows_data if abs(t-center) <= 400]
    total = sum(w for _,w,_ in win)
    agg = defaultdict(float)
    for _,w,frames in win:
        for key in dict.fromkeys(frames):
            if key[1]=='PostmanSwift': agg[key[0]] += w
    biggest = max(win, key=lambda r:r[1]) if win else None
    print(f'\n-- window {center}ms: samples={len(win)} time={total:.0f}ms')
    for n,t in sorted(agg.items(), key=lambda kv:-kv[1])[:8]:
        print(f'   app {t:6.0f} ms  {n[:100]}')
    if biggest:
        t,w,frames = biggest
        print(f'   heaviest sample {t:.0f}ms w={w:.0f}ms:')
        for (b,n) in frames[:16]:
            if b in ('PostmanSwift','SwiftUI','SwiftUICore','AttributeGraph','AppKit','QuartzCore','CoreFoundation','dyld','HIToolbox'):
                print(f'      {b:14} {n[:90]}')
