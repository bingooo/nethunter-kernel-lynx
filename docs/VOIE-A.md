# VOIE A — Aligner l'ABI wireless sur le device (rt2x00 sans WARN)

> Maj 2026-11-20. Fait suite au diagnostic `probe ... failed -12` /
> `WARN ieee80211_alloc_hw`. **La cause n'etait pas le commit noyau. C'etait la
> config de mac80211/cfg80211.**

## 1. Cause racine (etablie, pas une hypothese)

Le noyau qui boote (`6.1.157-android14-11-gb3d4cdadf339-ab16160610`) et le
`mac80211.ko`/`cfg80211.ko` du device sont **la meme version et le meme KMI**
(`6.1.157-android14-11`, verifie : `vermagic=6.1.157-android14-11-maybe-dirty`,
`intree=Y` dans le .ko extrait du tel). Donc le commit n'est pas le probleme.

Ce qui differe, c'est la **config** avec laquelle mac80211/cfg80211 ont ete
compiles :

- Le `vmlinux` GKI qui boote a `# CONFIG_CFG80211 is not set` et MAC80211 absent
  (verifie dans `configs/device-config.txt`, = `zcat /proc/config.gz`).
- `mac80211.ko`/`cfg80211.ko` ne viennent donc **pas** de ce vmlinux : ils sont
  buildes par le noyau **vendor gs-6.1** (CFG80211=m, MAC80211=m, ...) et charges
  par-dessus le GKI. C'est un *mixed build*.

Le build NetHunter precedent prenait `device-config.txt` (la config GKI, ou
mac80211 est absent) comme base. En activant MAC80211=m/CFG80211=m par-dessus,
`olddefconfig` choisissait des **valeurs par defaut** pour les options qui
conditionnent le layout des struct `ieee80211_ops` / `ieee80211_hw` / `wiphy`.
Ces defauts != gs-6.1 -> layout different -> le CRC genksyms de
`ieee80211_alloc_hw_nm` differe (device = `0xc1e8db04`) -> `mac80211` refuse
d'allouer le hw -> `WARN`. `patch_crcs.py` reecrivait le CRC (chargement OK) mais
**pas le layout** -> le WARN restait.

## 2. Les options qui comptent (ensemble COMPLET)

En scannant **toutes** les struct de `include/net/mac80211.h` et
`include/net/cfg80211.h` (branche `android14-6.1`), les seules options
`CONFIG_*` qui changent le layout de ces struct — donc le CRC des symboles que
rt2x00 importe — sont :

| Option | Valeur device | Source |
|---|---|---|
| `CONFIG_PM` | `y` | device-config.txt |
| `CONFIG_IPV6` | `y` | device-config.txt |
| `CONFIG_MAC80211_DEBUGFS` | `n` | .ko device (debugfs quasi absent) |
| `CONFIG_CFG80211_WEXT` | `n` | **.ko device : AUCUN symbole wext dans cfg80211.ko** |
| `CONFIG_NL80211_TESTMODE` | `y` | .ko device (`ieee80211_testmode_cmd` present) |

**`CONFIG_MAC80211_MESH` n'y figure pas** : le mesh ne touche pas ces struct,
c'etait une fausse piste pour le CRC.

Les 5 valeurs sont **vérifiées sur les .ko réels du device** (présence/absence de
symboles) et posées dans `configs/wireless-abi.config`, appliqué en dernier dans
`build.sh`. 1er essai (2026-11-20) : WEXT mis à `y` par erreur -> 22 mismatches
CRC (un champ en plus dans `struct wiphy`). Corrigé à `n`.

## 3. La porte de verification (remplace le maquillage)

`patch_crcs.py` n'est **plus appele**. A la place, `verify_wireless_abi.py`
compare les CRC des symboles wireless **reellement portes** par les .ko produits
aux CRC **exportes par le device** (`configs/phone_wireless.symvers`, 279
symboles extraits des mac80211.ko/cfg80211.ko du tel).

- Tous les symboles importes par rt2x00/rt2800 == device -> **feu vert** : les
  modules chargeront sans `disagrees about version of symbol` **et** sans WARN.
- Un seul mismatch -> **echec du build**, avec le diff exact (symbole,
  `build=0x...` vs `device=0x...`), **avant** tout flash.

Oracle confirme : `ieee80211_alloc_hw_nm` device = `0xc1e8db04`.

## 4. Procedure

1. `workflow_dispatch` sur la branche (CI = `ubuntu-24.04`, acces googlesource OK).
2. Lire la sortie de l'etape **6bis** :
   - **SUCCES** -> recuperer `output/modules/*.ko`, poser `rt2870.bin`, insmod,
     `iw dev` -> `wlanX` (cf. prompt de continuite §100-102). Plus de
     `patch_crcs`, CRC natifs.
   - **MISMATCH sur `ieee80211_*`/`wiphy_*`** -> basculer
     `CONFIG_NL80211_TESTMODE` (y<->n) dans `configs/wireless-abi.config`,
     recommit, re-dispatch.
   - **MISMATCH residuel** apres les 2 valeurs -> options cachees dans des
     headers tiers : passer a la Voie A *clean* (section 5).

## 5. Voie A "clean" (filet garanti, si la config a 5 options ne converge pas)

Builder contre la **vraie** source + config gs-6.1 (celle meme dont LineageOS
tire les .ko du device). Preuve que LineageOS build bien depuis cette source :
le repo prebuilt `LineageOS/android_device_google_lynx-kernels` (branche
`lineage-24.0`, dossier `6.1/`) ne contient que les listes de chargement ; son
`.gitignore` ignore precisement les SORTIES de build (`*.ko`,
`kernel_aarch64_Module.symvers`, `vendor_dlkm.img`, ...). Le device tree pointe
`TARGET_KERNEL_PLATFORM_SOURCE := google/gs-6.1`.

Source exacte (runner CI uniquement — googlesource bloque dans le conteneur de dev) :

```bash
repo init -u https://android.googlesource.com/kernel/manifest -b android-gs-lynx-6.1-android16
repo sync -c --no-tags
```

Cette branche fournit : l'arbre `aosp/` (= kernel/common ou vivent
`net/mac80211`, `net/wireless`), les fragments de config vendor gs-6.1, **et** le
clang prebuilt exact (fin des soucis clang-17 vs clang-22 / LTO). Ensuite, deux
options :

- **5a (recommandee, legere).** Recuperer dans l'arbre synchro le `.config`
  vendor reel (celui qui build les modules), le poser comme base a la place de
  `device-config.txt`, et garder le `make` classique de `build.sh` pour ne
  compiler que `net/wireless` + `net/mac80211` + rt2x00. La porte de verif
  confirme l'egalite des CRC.
- **5b (kleaf complet).** Build de l'image via le script/target du repo
  (`build_lynx.sh` ou `tools/bazel run //private/devices/google/lynx:...`,
  sortie `out/lynx/dist`), puis rt2x00 en module externe contre le noyau build.

Dans les deux cas, la porte `verify_wireless_abi.py` reste le juge : CRC natifs
== device = feu vert.

## 6. Fichiers touches (branche voie-a)

- `configs/wireless-abi.config` — **nouveau**, les 5 options ABI.
- `verify_wireless_abi.py` — **nouveau**, porte de verif (remplace patch_crcs).
- `build.sh` — merge du fragment ABI ; suppression du seeding wireless et de
  l'appel patch_crcs ; ajout de la porte 6bis.
- `.github/workflows/build.yml` — upload `if: always()` (inspecter les .ko meme
  si la porte echoue).
- `patch_crcs.py` — conserve pour reference, **plus appele**.
