#!/usr/bin/env python3
# Patch les CRC des symboles wireless dans la section __versions des .ko,
# avec les CRC EXPORTES par le mac80211/cfg80211 du device (phone_wireless.symvers).
# Sur-ecrit en place. Entrees __versions = 64 octets (8 crc LE + 56 nom).
import sys, struct, glob, os
from elftools.elf.elffile import ELFFile

symvers, moddir = sys.argv[1], sys.argv[2]
crc={}
for line in open(symvers):
    p=line.rstrip('\n').split('\t')
    if len(p)>=2 and p[0].startswith('0x'):
        crc[p[1]] = int(p[0],16) & 0xffffffff
ENTRY=64
for ko in sorted(glob.glob(os.path.join(moddir,'*.ko'))):
    with open(ko,'rb') as fh: data=bytearray(fh.read())
    with open(ko,'rb') as fh: e=ELFFile(fh); v=e.get_section_by_name('__versions'); 
    if v is None:
        continue
    off0=v['sh_offset']; size=v.data_size
    patched=0; total=size//ENTRY
    for i in range(total):
        eoff=off0+i*ENTRY
        name=bytes(data[eoff+8:eoff+ENTRY]).split(b'\x00')[0].decode('ascii','replace')
        if name in crc:
            cur=struct.unpack_from('<Q',data,eoff)[0]
            if cur!=crc[name]:
                struct.pack_into('<Q',data,eoff,crc[name]); patched+=1
    if patched:
        with open(ko,'wb') as fh: fh.write(data)
    print(f"  {os.path.basename(ko):16} {total} symbols, {patched} wireless CRC patched")
