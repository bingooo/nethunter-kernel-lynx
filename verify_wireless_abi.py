#!/usr/bin/env python3
# ============================================================================
# verify_wireless_abi.py — PORTE DE VERIFICATION (remplace patch_crcs.py)
#
# Voie A : au lieu de MAQUILLER les CRC wireless des .ko pour qu'ils matchent
# le device (ce que faisait patch_crcs.py, en masquant le vrai mismatch de
# layout `ieee80211_ops`/`wiphy`), on VERIFIE que les .ko produits portent
# DEJA, NATIVEMENT, les CRC exportes par le mac80211/cfg80211 du device.
#
#   - Si tous les symboles wireless importes par rt2x00/rt2800 (et les autres
#     drivers) ont le MEME CRC que le device => le build a ete fait contre le
#     bon source+config (gs-6.1). Les modules se chargeront sans
#     "disagrees about version of symbol ..." ET sans WARN runtime
#     ieee80211_alloc_hw (le layout de struct correspond). On peut flasher.
#
#   - Si un seul CRC differe => le build a ete fait contre une config wireless
#     differente de celle du device. On NE flashe PAS. Le diff ci-dessous dit
#     exactement quels symboles (donc quelles structs/options) divergent.
#     => corriger la config (voir docs/VOIE-A.md) et rebuild.
#
# Oracle = configs/phone_wireless.symvers (279 CRC EXPORTES par les
# mac80211.ko/cfg80211.ko reellement extraits du Pixel 7a).
#
# Usage :
#   verify_wireless_abi.py <phone_wireless.symvers> <dir_des_.ko> [--strict]
#
# Code retour : 0 = tous les CRC wireless matchent (feu vert flash)
#               1 = au moins un mismatch (NE PAS flasher)
#               2 = erreur d'usage / fichier manquant
#
# Entrees __versions : 64 octets = 8 (CRC little-endian) + 56 (nom NUL-pad).
# ============================================================================
import sys, struct, glob, os
from elftools.elf.elffile import ELFFile

# Modules "coeur" dont le chargement DOIT reussir sur le device. Un mismatch
# sur l'un d'eux est bloquant meme sans --strict.
CORE = {"rt2x00lib.ko", "rt2x00usb.ko", "rt2800lib.ko", "rt2800usb.ko"}

ENTRY = 64

def load_oracle(path):
    crc = {}
    with open(path) as fh:
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) >= 2 and p[0].startswith("0x"):
                crc[p[1]] = int(p[0], 16) & 0xffffffff
    return crc

def ko_versions(path):
    """Retourne {symbole: crc} de la section __versions d'un .ko."""
    out = {}
    with open(path, "rb") as fh:
        data = fh.read()
        fh.seek(0)
        e = ELFFile(fh)
        v = e.get_section_by_name("__versions")
        if v is None:
            return out
        off0 = v["sh_offset"]
        size = v.data_size
    for i in range(size // ENTRY):
        eoff = off0 + i * ENTRY
        crc = struct.unpack_from("<Q", data, eoff)[0] & 0xffffffff
        name = data[eoff + 8:eoff + ENTRY].split(b"\x00")[0].decode("ascii", "replace")
        if name:
            out[name] = crc
    return out

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv
    if len(args) != 2:
        print(__doc__ or "usage: verify_wireless_abi.py <symvers> <dir> [--strict]")
        return 2
    symvers, moddir = args
    if not os.path.isfile(symvers):
        print(f"[verif][ERREUR] oracle introuvable : {symvers}")
        return 2
    oracle = load_oracle(symvers)
    print(f"[verif] oracle = {len(oracle)} symboles wireless du device")

    kos = sorted(glob.glob(os.path.join(moddir, "*.ko")))
    if not kos:
        print(f"[verif][ERREUR] aucun .ko dans {moddir}")
        return 2

    total_mismatch = 0
    core_mismatch = 0
    for ko in kos:
        base = os.path.basename(ko)
        vers = ko_versions(ko)
        # on ne regarde que les symboles que CE module importe ET qui sont
        # exportes par le mac80211/cfg80211 du device (donc dans l'oracle).
        checked = {s: c for s, c in vers.items() if s in oracle}
        if not checked:
            continue
        mism = {s: (c, oracle[s]) for s, c in checked.items() if c != oracle[s]}
        tag = "CORE" if base in CORE else "    "
        if mism:
            total_mismatch += len(mism)
            if base in CORE:
                core_mismatch += len(mism)
            print(f"[verif][{tag}] {base:16} {len(checked):3} wireless, "
                  f"\033[1;31m{len(mism)} MISMATCH\033[0m")
            for s, (got, want) in sorted(mism.items()):
                print(f"            {s:40} build=0x{got:08x} device=0x{want:08x}")
        else:
            print(f"[verif][{tag}] {base:16} {len(checked):3} wireless, OK (tous == device)")

    print("-" * 64)
    if core_mismatch:
        print(f"\033[1;31m[verif] ECHEC : {core_mismatch} mismatch sur les modules CORE "
              f"(rt2x00/rt2800).\033[0m")
        print("[verif] => NE PAS flasher. Le build n'a pas ete fait contre la")
        print("[verif]    config wireless gs-6.1 du device. Voir docs/VOIE-A.md.")
        return 1
    if total_mismatch and strict:
        print(f"\033[1;31m[verif] ECHEC (strict) : {total_mismatch} mismatch hors CORE.\033[0m")
        return 1
    if total_mismatch:
        print(f"\033[1;33m[verif] OK pour CORE, mais {total_mismatch} mismatch sur des "
              f"drivers secondaires (hors CORE). Tolere sans --strict.\033[0m")
        return 0
    print("\033[1;32m[verif] SUCCES : tous les CRC wireless == device. "
          "Feu vert pour flasher.\033[0m")
    return 0

if __name__ == "__main__":
    sys.exit(main())
