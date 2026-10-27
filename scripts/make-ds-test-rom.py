#!/usr/bin/env python3
"""Build our own tiny DS homebrew: red upper screen, blue lower; A turns upper green."""
import pathlib, subprocess, struct, tempfile, sys
asm = r'''
.syntax unified
.arm
.global _start
_start:
 ldr r0, =0x04000304
 ldr r1, =0x8203
 strh r1, [r0]
 ldr r0, =0x04000240
 mov r1, #0x80
 strb r1, [r0]
 mov r1, #0x84
 strb r1, [r0, #2]
 ldr r0, =0x04000000
 mov r1, #0x20000
 str r1, [r0]
 ldr r0, =0x04001000
 ldr r1, =0x10405
 str r1, [r0]
 ldr r1, =0x4084
 strh r1, [r0, #12]
 mov r1, #256
 strh r1, [r0, #32]
 strh r1, [r0, #38]
 ldr r0, =0x06200000
 ldr r1, =0xfc00
 ldr r2, =49152
fill_bottom:
 strh r1, [r0], #2
 subs r2, r2, #1
 bne fill_bottom
frame:
 ldr r0, =0x04000130
 ldrh r1, [r0]
 tst r1, #1
 ldreq r3, =0x83e0
 ldrne r3, =0x801f
 ldr r0, =0x06800000
 ldr r2, =49152
fill_top:
 strh r3, [r0], #2
 subs r2, r2, #1
 bne fill_top
 b frame
.ltorg
'''
with tempfile.TemporaryDirectory() as td:
 p=pathlib.Path(td);(p/'test.s').write_text(asm)
 subprocess.run(['clang','-target','armv5te-none-eabi','-c',str(p/'test.s'),'-o',str(p/'test.o')],check=True)
 e=(p/'test.o').read_bytes(); off=struct.unpack_from('<I',e,32)[0]; n=struct.unpack_from('<H',e,48)[0]; si=struct.unpack_from('<H',e,50)[0]
 sections=[struct.unpack_from('<10I',e,off+i*40) for i in range(n)]; names=sections[si]; st=e[names[4]:names[4]+names[5]]
 sec=next(s for s in sections if st[s[0]:].split(b'\0')[0]==b'.text'); code=e[sec[4]:sec[4]+sec[5]]
 rom=bytearray(0x1000);rom[:12]=b'WOOPER TEST\0';rom[12:16]=b'####';rom[16:18]=b'00'
 struct.pack_into('<4I',rom,0x20,0x200,0x02000000,0x02000000,len(code));struct.pack_into('<4I',rom,0x30,0x400,0x03800000,0x03800000,4)
 struct.pack_into('<I',rom,0x80,len(rom));struct.pack_into('<I',rom,0x84,0x200)
 rom[0x200:0x200+len(code)]=code;struct.pack_into('<I',rom,0x400,0xeafffffe)
 out=pathlib.Path(sys.argv[1] if len(sys.argv)>1 else '/tmp/Wooper Input Test.nds');out.write_bytes(rom);print(out)
