#!/usr/bin/env python3
"""Copy a supplied .nds ROM into an installed Wooper, without rebuilding it."""
import argparse, pathlib, struct, subprocess
p = argparse.ArgumentParser()
p.add_argument('rom', type=pathlib.Path)
p.add_argument('--device', default='00008160-0015455A11680036')
a = p.parse_args()
f = a.rom.expanduser().resolve()
if f.suffix.lower() != '.nds' or not 512 <= f.stat().st_size <= 512 * 1024 * 1024:
    p.error('Expected an uncompressed .nds ROM (512 bytes–512 MiB).')
with f.open('rb') as stream: header = stream.read(512)
for base in (0x20, 0x30):
    offset, _, _, size = struct.unpack_from('<4I', header, base)
    if offset < 512 or size == 0 or offset + size > f.stat().st_size:
        p.error('Invalid or incomplete DS ROM header.')
subprocess.run(['xcrun','devicectl','device','copy','to','--device',a.device,
               '--source',str(f),'--destination','Documents/DS/ROMs/'+f.name,
               '--domain-type','appDataContainer','--domain-identifier','com.neelr.Wooper'], check=True)
print('Open the DS tab (or pull to refresh the library). Saves are kept separately.')
