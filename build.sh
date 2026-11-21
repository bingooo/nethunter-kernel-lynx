#!/usr/bin/env bash
# ============================================================================
# build.sh — Kernel Kali NetHunter pour Google Pixel 7a (lynx)
#            GKI android14-6.1 — methode LKM (modules chargeables .ko)
#
# Cible EXACTE (device OLYAHYAI, releve 2026-11-19) :
#   kernel/common  branche android14-6.1, commit b3d4cdadf339
#   noyau 6.1.157-android14 (KMI generation 11), build GKI ab16160610
#   uname -r device : 6.1.157-android14-11-gb3d4cdadf339-ab16160610
#   Rappel MODVERSIONS : le noyau ignore la chaine de version du vermagic
#   (coupe avant le 1er espace) ; seuls les FLAGS + les CRC de symboles
#   comptent. D'ou l'alignement CRC ci-dessous sur ab16160610.
#
# Usage :
#   ./build.sh                  # build complet (noyau + modules + pilotes)
#   JOBS=4 ./build.sh           # limiter le parallelisme (RAM insuffisante)
#   CLANG_DIR=/chemin/clang17 ./build.sh
#
# Prerequis (cf. docs/BUILD.md) :
#   clang 17 (LLVM 17.x) + lld + llvm-ar/nm/objcopy/strip. Le clang 22 d'Arch
#   est TROP recent pour ce noyau 6.1 (-Werror casse libbpf/resolve_btfids).
#   Ce script attend CLANG_DIR pointant sur un clang 17 (tarball LLVM 17.x ou
#   prebuilt AOSP r487747c).
#
# Resultat dans ./output/ :
#   modules/*.ko  (in-tree + out-of-tree)
#   Module.symvers, .config, System.map, Image
# ============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${ROOT_DIR}/kernel/common"
OUT_DIR="${ROOT_DIR}/out"
DRIVERS_DIR="${ROOT_DIR}/drivers"
OUTPUT_DIR="${ROOT_DIR}/output"
CONFIGS_DIR="${ROOT_DIR}/configs"
PATCHES_DIR="${ROOT_DIR}/patches"

BRANCH="${BRANCH:-android14-6.1}"
# Cible device OLYAHYAI : uname -r = 6.1.157-android14-11-gb3d4cdadf339-ab16160610
COMMIT="${COMMIT:-b3d4cdadf339}"
GKI_BUILD="${GKI_BUILD:-16160610}"
KMI_GENERATION="${KMI_GENERATION:-11}"
KERNEL_URL="https://android.googlesource.com/kernel/common"
JOBS="${JOBS:-$(nproc)}"
ARCH="arm64"

# La version du noyau (vermagic) est derivee de BRANCH + KMI_GENERATION + hash
# git (scripts/setlocalversion). Ces variables DOIVENT etre exportees.
export ARCH BRANCH KMI_GENERATION

log() { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[build]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Toolchain clang 17
# ---------------------------------------------------------------------------
CLANG_DIR="${CLANG_DIR:-}"
if [ -n "${CLANG_DIR}" ] && [ -d "${CLANG_DIR}/bin" ]; then
  LLVM="${CLANG_DIR}/bin/"
  LIBS_DIR="${ROOT_DIR}/.toolchain-libs"
  mkdir -p "${LIBS_DIR}"
  if [ ! -e "${LIBS_DIR}/libxml2.so.2" ]; then
    for cand in /usr/lib/libxml2.so.16 /usr/lib64/libxml2.so.16; do
      if [ -e "$cand" ]; then ln -sf "$cand" "${LIBS_DIR}/libxml2.so.2"; break; fi
    done
  fi
  export LD_LIBRARY_PATH="${LIBS_DIR}:${LD_LIBRARY_PATH:-}"
elif command -v clang-17 >/dev/null 2>&1; then
  # SUFFIXE -17 : make construit clang-17/ld.lld-17/llvm-*-17 de facon
  # coherente (cible ET host). Evite le melange clang-18 (compile LTO bitcode)
  # / ld.lld-17 (link) sur ubuntu-24.04 qui donne :
  #   ld.lld: error: Invalid record (Producer LLVM18.1.3 Reader LLVM 17.0.6)
  LLVM="-17"
else
  LLVM=1
  log "Utilisation du LLVM/Clang systeme (LLVM=1)."
fi

# ---------------------------------------------------------------------------
# 1. Sources GKI
# ---------------------------------------------------------------------------
log "1/7 : sources GKI ${BRANCH} @ ${COMMIT}"
mkdir -p "${ROOT_DIR}/kernel"
if [ ! -d "${KERNEL_DIR}/.git" ]; then
  # Partial clone (blob:none) : tout l'historique commits/trees sans les blobs.
  # Permet un checkout par hash COURT (b3d4cdadf339) sans connaitre le SHA
  # complet, reste leger, et telecharge les blobs du commit a la demande.
  git clone --filter=blob:none -b "${BRANCH}" "${KERNEL_URL}" "${KERNEL_DIR}"
  ( cd "${KERNEL_DIR}" && git checkout "${COMMIT}" )
else
  log "  deja clone : ${KERNEL_DIR} (verifier commit = ${COMMIT})"
fi
if grep -q 'cpio_dir=\$outdir/\$tarfile.tmp' "${KERNEL_DIR}/kernel/gen_kheaders.sh" 2>/dev/null; then
  log "  patch gen_kheaders.sh (use /tmp for bind mount stability)"
  sed -i 's|cpio_dir=\$outdir/\$tarfile.tmp|cpio_dir=\$(mktemp -d /tmp/kheaders_tmp.XXXXXX)|' "${KERNEL_DIR}/kernel/gen_kheaders.sh"
fi
# Empecher le suffixe -dirty dans vermagic
git -C "${KERNEL_DIR}" update-index --assume-unchanged kernel/gen_kheaders.sh 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Fragment de config
# ---------------------------------------------------------------------------
log "2/7 : installation du fragment nethunter.config"
mkdir -p "${KERNEL_DIR}/arch/${ARCH}/configs"
cp -f "${CONFIGS_DIR}/nethunter.config" "${KERNEL_DIR}/arch/${ARCH}/configs/"

# Patch source : forcer RT2X00_LIB_LEDS a 'default n'. Ce symbole est SANS prompt
# (auto 'default y' des que LEDS_CLASS=y, et un driver de la config device
# select-e LEDS_CLASS) -> impossible a couper par .config. On change le defaut
# dans le Kconfig pour que rt2x00lib ne compile PAS son code LED, qui refere
# __ieee80211_create_tpt_led_trigger + led_classdev_suspend/resume (err -2,
# absents du device: led_classdev_suspend/resume ont ete retires en 6.0).
RT2X00_KCONFIG="${KERNEL_DIR}/drivers/net/wireless/ralink/rt2x00/Kconfig"
if [ -f "${RT2X00_KCONFIG}" ]; then
  sed -i '/^config RT2X00_LIB_LEDS$/,/^config [A-Z0-9_]/ s/^[[:space:]]*default y/\tdefault n/' "${RT2X00_KCONFIG}"
  log "   RT2X00_LIB_LEDS force a default n :"
  grep -A3 '^config RT2X00_LIB_LEDS$' "${RT2X00_KCONFIG}" | sed 's/^/     /'
fi

# Patch source : retirer le PROMPT de MAC80211_LEDS -> symbole promptless, defaut
# n (rien ne le select-e) -> CONFIG_MAC80211_LEDS=n. Consequence : l'inline
# ieee80211_create_tpt_led_trigger() de include/net/mac80211.h devient le stub
# (#else, retourne NULL) -> rt2x00lib ne refere plus __ieee80211_create_tpt_led_trigger
# (symbole absent du device car son mac80211 est aussi build sans MAC80211_LEDS).
MAC80211_KCONFIG="${KERNEL_DIR}/net/mac80211/Kconfig"
if [ -f "${MAC80211_KCONFIG}" ]; then
  sed -i 's/^\([[:space:]]*\)bool "Enable LED triggers"$/\1bool/' "${MAC80211_KCONFIG}"
  log "   MAC80211_LEDS : prompt retire (-> default n)"
fi

# Patch source : neutraliser clk_get_sys() dans rt2800lib.c. C'est une API
# d'horloge legacy (clkdev) pour les Ralink en SoC embarque, non exportee par
# le noyau arm64 du device (err -2), inutile pour l'USB. On injecte une macro
# APRES le dernier #include (donc apres la declaration de linux/clk.h -> pas de
# collision avec le prototype) qui remplace l'appel par NULL.
RT2800LIB_C="${KERNEL_DIR}/drivers/net/wireless/ralink/rt2x00/rt2800lib.c"
if [ -f "${RT2800LIB_C}" ] && grep -q 'clk_get_sys' "${RT2800LIB_C}"; then
  log "   clk_get_sys trouve dans rt2800lib.c, contexte :"
  grep -n -C2 'clk_get_sys' "${RT2800LIB_C}" | sed 's/^/     /' | head -20
  LASTINC=$(grep -n '^#include' "${RT2800LIB_C}" | tail -1 | cut -d: -f1)
  if [ -n "${LASTINC}" ]; then
    sed -i "${LASTINC}a #define clk_get_sys(a,b) ((struct clk *)0)" "${RT2800LIB_C}"
    log "   macro clk_get_sys->NULL injectee apres la ligne ${LASTINC}"
  fi
else
  log "   (pas de clk_get_sys dans rt2800lib.c ou fichier absent)"
fi

# ---------------------------------------------------------------------------
# 3. Generation .config : base = CONFIG EXACTE DU DEVICE + fragment
# ---------------------------------------------------------------------------
# On part de la config reelle du Pixel 7a (configs/device-config.txt =
# zcat /proc/config.gz). But : que les CRC du coeur (sk_buff, dev_*, ...)
# matchent le device NATIVEMENT (meme config => meme genksyms => memes CRC).
# merge_config applique le fragment par-dessus, olddefconfig resout les deps.
# Les options vendor du device absentes du tree kernel/common sont ignorees.
log "3/7 : generation .config (device-config.txt + nethunter.config + wireless-abi.config)"
mkdir -p "${OUT_DIR}"
cp -f "${CONFIGS_DIR}/device-config.txt" "${OUT_DIR}/.config.base"
# VOIE A : wireless-abi.config aligne les 5 options qui conditionnent le layout
# des struct ieee80211_ops/ieee80211_hw/wiphy (PM, IPV6, MAC80211_DEBUGFS,
# NL80211_TESTMODE, CFG80211_WEXT) sur le mac80211/cfg80211 du device. Sans ca,
# olddefconfig prend des defauts != gs-6.1 -> CRC ieee80211_alloc_hw_nm faux
# -> WARN runtime. Applique EN DERNIER pour primer sur les defauts.
( cd "${KERNEL_DIR}" && ARCH="${ARCH}" scripts/kconfig/merge_config.sh -m \
    -O "${OUT_DIR}" "${OUT_DIR}/.config.base" \
    "${CONFIGS_DIR}/nethunter.config" \
    "${CONFIGS_DIR}/wireless-abi.config" )
make -C "${KERNEL_DIR}" O="${OUT_DIR}" ARCH="${ARCH}" LLVM="${LLVM}" olddefconfig

# Garde-fou rapide : verifier que les LED rt2x00 sont bien coupees (sinon
# rt2x00lib refere __ieee80211_create_tpt_led_trigger / led_classdev_* absents
# du device -> err -2). Echec en ~1 min plutot qu'apres 10 min de compilation.
log "3b : verif config LED (rt2x00)"
grep -E 'CONFIG_(NEW_LEDS|LEDS_CLASS|RT2X00_LIB_LEDS|MAC80211_LEDS)(=| is not set)' "${OUT_DIR}/.config" || true
if grep -qE '^CONFIG_(RT2X00_LIB_LEDS|MAC80211_LEDS)=y' "${OUT_DIR}/.config"; then
  echo "[build][ERREUR] RT2X00_LIB_LEDS ou MAC80211_LEDS encore =y." >&2
  grep -E '^CONFIG_(RT2X00_LIB_LEDS|MAC80211_LEDS)=y' "${OUT_DIR}/.config" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Compilation noyau + modules in-tree
# ---------------------------------------------------------------------------
log "4/7 : compilation (jobs=${JOBS})"
make -C "${KERNEL_DIR}" O="${OUT_DIR}" ARCH="${ARCH}" LLVM="${LLVM}" \
  -j"${JOBS}" KCFLAGS="-D__ANDROID_COMMON_KERNEL__" WERROR=0

# ---------------------------------------------------------------------------
# 4bis. Verification & Alignement de Module.symvers (Google GKI ab16017558)
# ---------------------------------------------------------------------------
OFFICIAL_SYMVERS="${CONFIGS_DIR}/vmlinux.symvers-ab${GKI_BUILD}"
if [ ! -f "${OFFICIAL_SYMVERS}" ]; then
  log "  Telechargement du vmlinux.symvers officiel (ab${GKI_BUILD})..."
  curl -s -L "https://ci.android.com/builds/submitted/${GKI_BUILD}/kernel_aarch64/latest/raw/vmlinux.symvers" -o "${OFFICIAL_SYMVERS}" || true
fi
EXPECTED_CRC=$(grep -w "module_layout" "${OFFICIAL_SYMVERS}" 2>/dev/null | awk '{print $1}')
ACTUAL_CRC=$(grep -w "module_layout" "${OUT_DIR}/Module.symvers" 2>/dev/null | awk '{print $1}')
log "Verification CRC module_layout :"
log "  Attendu (Google GKI ab${GKI_BUILD}) : ${EXPECTED_CRC:-inconnu}"
log "  Actuel (notre build)              : ${ACTUAL_CRC:-introuvable}"

if [ -f "${OFFICIAL_SYMVERS}" ]; then
  log "  Alignement de Module.symvers avec les symboles officiels GKI..."
  awk '$3 != "vmlinux"' "${OUT_DIR}/Module.symvers" > "${OUT_DIR}/Module.symvers.modules"
  cat "${OFFICIAL_SYMVERS}" "${OUT_DIR}/Module.symvers.modules" > "${OUT_DIR}/Module.symvers.aligned"
  mv -f "${OUT_DIR}/Module.symvers.aligned" "${OUT_DIR}/Module.symvers"
  rm -f "${OUT_DIR}/Module.symvers.modules"
  FINAL_CRC=$(grep -w "module_layout" "${OUT_DIR}/Module.symvers" 2>/dev/null | awk '{print $1}')
  log "  CRC module_layout final dans Module.symvers : ${FINAL_CRC}"
fi

# VOIE A : on NE seed PLUS Module.symvers avec phone_wireless.symvers.
# Les CRC wireless (ieee80211_*/wiphy_*) doivent etre ceux que NOTRE mac80211/
# cfg80211 vient de produire NATIVEMENT (avec wireless-abi.config aligne sur le
# device). modpost va stamper les .ko avec ces CRC natifs ; la porte de verif
# (etape 6bis) confirme qu'ils == device. Seeder ici reviendrait a re-masquer le
# mismatch (comme l'ancien patch_crcs.py) et a rendre la verif aveugle.
# NB : on GARDE l'alignement vmlinux/GKI ci-dessus (module_layout & co) : les
# modules se chargent bien contre le vmlinux GKI ab${GKI_BUILD}, c'est correct.

# ---------------------------------------------------------------------------
# 5. Pilotes out-of-tree (RTL8812AU / RTL8188EU)
# ---------------------------------------------------------------------------
log "5/7 : pilotes out-of-tree"
mkdir -p "${DRIVERS_DIR}"
OOT_DRIVERS=(
  "rtl8812au|https://github.com/aircrack-ng/rtl8812au.git"
  "rtl8188eu|https://github.com/aircrack-ng/rtl8188eus.git"
)
for entry in "${OOT_DRIVERS[@]}"; do
  name="${entry%%|*}"
  url="${entry##*|}"
  d="${DRIVERS_DIR}/${name}"
  if [ ! -d "${d}/.git" ]; then
    log "  clonage ${name}"
    git clone --depth 1 "${url}" "${d}"
  fi
  # Patch cfg80211 : les signatures de cfg80211_ch_switch_notify /
  # cfg80211_ch_switch_started_notify ont change (punct_bitmap ajoute en 6.1).
  # Les drivers aircrack-ng ont un seuil faux (6.3 au lieu de 6.1) -> patch.
  for patch_name in "${name}-cfg80211-6.1.patch" "${name}-gki-fileio.patch" "${name}-cfi-tasklet.patch"; do
    patch_file="${PATCHES_DIR}/${patch_name}"
    if [ -f "$patch_file" ]; then
      log "  patch ${name} (${patch_name})"
      git -C "$d" apply --check "$patch_file" 2>/dev/null && git -C "$d" apply "$patch_file" || true
    fi
  done
  make -C "${d}" clean >/dev/null 2>&1 || true
  log "  build ${name} (.ko)"
  # Workaround FORTIFY_SOURCE + clang : drivers legacy utilisant u8 data[0].
  # -D__NO_FORTIFY desactive fortify-string.h ; -Wno-error demote les warnings
  # generiques SANS toucher aux -Werror=implicit-function-declaration /
  # incompatible-pointer-types. CONFIG_PLATFORM_ARM64_RPI=y evite la glue
  # Android legacy (rtw_android.c -> linux/wlan_plat.h, absent du mainline).
  OOT_CFLAGS="-D__NO_FORTIFY -Wno-error -Wno-uninitialized -Wno-unknown-warning-option -Wno-array-bounds -Wno-address-of-packed-member"
  make -C "${d}" ARCH="${ARCH}" LLVM="${LLVM}" \
    CONFIG_PLATFORM_ARM64_RPI=y CONFIG_PLATFORM_I386_PC=n CONFIG_PLATFORM_ANDROID_ARM64=n \
    KSRC="${KERNEL_DIR}" O="${OUT_DIR}" \
    USER_EXTRA_CFLAGS="${OOT_CFLAGS}" \
    modules || err "  echec ${name}"
done

# ---------------------------------------------------------------------------
# 6. Collecte des artefacts
# ---------------------------------------------------------------------------
log "6/7 : collecte des artefacts dans ${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}/modules"

find "${OUT_DIR}" -name '*.ko' -exec cp -f {} "${OUTPUT_DIR}/modules/" \;
for name in rtl8812au rtl8188eu; do
  find "${DRIVERS_DIR}/${name}" -name '*.ko' \
    -exec cp -f {} "${OUTPUT_DIR}/modules/" \; 2>/dev/null || true
done

cp -f "${OUT_DIR}/arch/${ARCH}/boot/Image"    "${OUTPUT_DIR}/" 2>/dev/null || true
cp -f "${OUT_DIR}/arch/${ARCH}/boot/Image.gz" "${OUTPUT_DIR}/" 2>/dev/null || true
cp -f "${OUT_DIR}/Module.symvers"             "${OUTPUT_DIR}/" 2>/dev/null || true
cp -f "${OUT_DIR}/System.map"                 "${OUTPUT_DIR}/" 2>/dev/null || true
cp -f "${OUT_DIR}/.config"                    "${OUTPUT_DIR}/" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6bis. PORTE DE VERIFICATION ABI wireless (remplace patch_crcs.py)
# ---------------------------------------------------------------------------
# VOIE A : on ne MAQUILLE plus les CRC. On VERIFIE que les .ko produits portent
# DEJA, nativement, les CRC exportes par le mac80211/cfg80211 du device
# (configs/phone_wireless.symvers). Si oui -> les modules chargeront sans
# "disagrees about version of symbol" ET sans WARN ieee80211_alloc_hw (le layout
# de struct correspond, grace a wireless-abi.config). Si non -> echec ICI, avec
# le diff exact des symboles divergents, AVANT tout flash. (ancien patch_crcs.py
# conserve dans le repo pour reference, mais plus appele.)
log "6bis : verification ABI wireless (verify_wireless_abi.py)"
python3 -c 'import elftools' 2>/dev/null || pip3 install --quiet --break-system-packages pyelftools 2>/dev/null || pip3 install --quiet pyelftools 2>/dev/null || true
python3 "${ROOT_DIR}/verify_wireless_abi.py" \
    "${CONFIGS_DIR}/phone_wireless.symvers" "${OUTPUT_DIR}/modules"
VERIFY_RC=$?
if [ "${VERIFY_RC}" -ne 0 ]; then
  err "ABI wireless NON conforme au device (voir diff ci-dessus)."
  err "=> NE PAS flasher ces .ko. Ajuster configs/wireless-abi.config"
  err "   (typiquement basculer CONFIG_NL80211_TESTMODE) et relancer,"
  err "   ou passer a la Voie A clean (repo sync). Voir docs/VOIE-A.md."
  exit "${VERIFY_RC}"
fi

# ---------------------------------------------------------------------------
# 7. Resume + verification vermagic
# ---------------------------------------------------------------------------
log "7/7 : termine"
echo ""
echo "Version noyau (vermagic attendu) :"
make -C "${KERNEL_DIR}" O="${OUT_DIR}" ARCH="${ARCH}" LLVM="${LLVM}" -s kernelrelease
echo ""
echo "Modules produits :"
find "${OUTPUT_DIR}/modules" -name '*.ko' -printf '  %f\n' | sort
echo ""
echo "Artefacts dans : ${OUTPUT_DIR}"
