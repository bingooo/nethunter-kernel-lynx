# Procédure de build détaillée

## Contexte technique

Le Pixel 7a (`lynx`, SoC Tensor G2 `gs201`) sous Android 14 utilise le noyau
GKI Google `kernel/common`, branche `android14-6.1` (version 6.1.145). Le fork
historique `android_kernel_google_gs201` est arrêté à Android 14.

Contrainte GKI : le noyau est « gelé » (ABI stable). Toute modification
vendor/OEM est un **module chargeable** (`.ko`), pas une modification du
`boot.img`. On ne patche pas le noyau, on construit des modules.

## Cible exacte

- Branche : `android14-6.1` de `https://android.googlesource.com/kernel/common`
- Commit : `edaaac4d5c85cb9fb220767a9e5f859cb730fb27` (= build GKI `ab16017558`)
- Noyau : `6.1.145-android14-11-gedaaac4d5c85` (KMI generation 11)
- Vermagic produit :
  `6.1.145-android14-11-gedaaac4d5c85 SMP preempt mod_unload modversions aarch64`

Le vermagic est déterministe : `scripts/setlocalversion` reçoit `BRANCH` +
`KMI_GENERATION` (définis dans `build.config.constants`/`build.config.common`)
et calcule `-android14-11-gedaaac4d5c85`. Ces deux variables **doivent** être
exportées pendant le `make` (le script `build.sh` le fait).

## Prérequis hôte (Arch Linux)

```bash
sudo pacman -S --needed base-devel git python clang llvm lld bc cpio \
  libelf pahole dtc zip unzip libxml2
```

### Toolchain clang 17 (obligatoire)

Le clang 22 livré par Arch est **trop récent** pour ce noyau 6.1 : il durcit
`-Wincompatible-pointer-types-discards-qualifiers` et casse
`tools/bpf/resolve_btfids` (libbpf embarquée). Google a buildé ce noyau avec
clang 17 (`r487747c`, clang 17.0.2).

Télécharger le tarball LLVM 17.0.6 officiel :

```bash
mkdir -p ~/toolchain && cd ~/toolchain
curl -L -o clang-17.0.6.tar.xz \
  https://github.com/llvm/llvm-project/releases/download/llvmorg-17.0.6/clang+llvm-17.0.6-x86_64-linux-gnu-ubuntu-22.04.tar.xz
tar -xf clang-17.0.6.tar.xz
```

Le `ld.lld` du tarball (build Ubuntu) dépend de `libxml2.so.2`. Arch fournit
`libxml2.so.16` : créer un symlink local et l'exposer via `LD_LIBRARY_PATH`
(le warning « no version information available » est inoffensif) :

```bash
mkdir -p ~/toolchain/libs
ln -sf /usr/lib/libxml2.so.16 ~/toolchain/libs/libxml2.so.2
export LD_LIBRARY_PATH=~/toolchain/libs
```

`build.sh` fait ce symlink automatiquement dans `.toolchain-libs/`.

## BTF activé (obligatoire pour GKI & module_layout CRC)

Dans `include/linux/module.h`, `struct module` embarque `btf_data` et `btf_data_size`
conditionnés par `CONFIG_DEBUG_INFO_BTF_MODULES`. Si désactivé, `struct module`
change de structure en mémoire et le CRC de `module_layout` diverge de celui du
noyau officiel Google (`0xea759d7f`), provoquant un rejet immédiat (`disagrees about version of symbol module_layout`).
Pour éviter l'erreur de build historique sous clang 16+ dans `resolve_btfids`,
`build.sh` passe les flags `HOSTCFLAGS="-Wno-error=discarded-qualifiers -Wno-error=incompatible-pointer-types-discards-qualifiers"`.

## LTO thin (obligatoire pour GKI)

Le noyau GKI Google (`android14-6.1`) est compilé **avec LTO thin**
(`CONFIG_LTO_CLANG_THIN=y`) via le build system officiel. `gki_defconfig`
n'active PAS LTO à lui seul. Un module compilé sans LTO ne charge pas sur un
noyau LTO : le module loader le rejette avec `invalid module format` (ENOEXEC).
Le fragment force donc `CONFIG_LTO_CLANG_THIN=y` (cf. `configs/nethunter.config`).

Vérifier après build :

```sh
grep -E 'CONFIG_LTO_CLANG' out/.config
# => CONFIG_LTO_CLANG=y + CONFIG_LTO_CLANG_THIN=y
```

## Build (Docker ou Hôte Linux)

### Option A : Via Docker (Recommandé sur macOS / Linux)

```bash
./docker-build.sh
```

### Option B : Directement sur l'hôte (Linux avec clang 17)

```bash
./build.sh
./build-magisk.sh 6.1.145
```

Déroulé :

1. Clone `kernel/common` (`android14-6.1`) dans `kernel/common`, puis
   `git fetch --depth 1 origin <commit>` + `git checkout <commit>`
   (commit précis `edaaac4d5c85`, PAS le HEAD de la branche qui a avancé
   jusqu'à 6.1.177).
2. Copie `configs/nethunter.config` dans `arch/arm64/configs/`.
3. `make gki_defconfig nethunter.config` (fragment merge via merge_config.sh).
4. `make -j$(nproc) KCFLAGS=-D__ANDROID_COMMON_KERNEL__` : noyau + modules
   in-tree.
5. Build des pilotes out-of-tree (recette FORTIFY, voir `drivers/README.md`).
6. Collecte des `.ko` + artefacts dans `output/`.

### Module Magisk

```bash
./build-magisk.sh 6.1.145    # output/nethunter-lynx-magisk-6.1.145.zip
```

## Vérification du vermagic

```bash
modinfo output/modules/cfg80211.ko | grep vermagic
# => 6.1.145-android14-11-gedaaac4d5c85 SMP preempt mod_unload modversions aarch64
```

## Contenu de `output/`

```
output/
├── modules/
│   ├── cfg80211.ko, mac80211.ko
│   ├── rt2x00lib.ko, rt2x00usb.ko, rt2800lib.ko, rt2800usb.ko
│   ├── ath.ko, ath9k_hw.ko, ath9k_common.ko, ath9k_htc.ko
│   ├── rtl8xxxu.ko, btusb.ko, hci_uart.ko
│   ├── 88XXau.ko  (rtl8812au out-of-tree)
│   └── 8188eu.ko  (rtl8188eu out-of-tree)
├── Module.symvers, .config, System.map, Image
```

## Déploiement (contraintes)

`CONFIG_MODVERSIONS=y` + `CONFIG_MODULE_SIG=y` : un `.ko` ne se charge que sur
un noyau de version exactement identique (vermagic + CRC + signature). Voir
`docs/VERMAGIC.md`. Magisk/KernelSU avec `insmod` au boot est la voie la plus
pratique.

## Étapes restantes (hors scope de ce dépôt)

- Fourniture du rootfs NetHunter (séparé, côté Kali).
- Validation matérielle (monitor mode, injection, HID) sur un lynx déverrouillé.
