#!/usr/bin/env bash
# ============================================================================
# build.sh — Kernel Kali NetHunter pour Google Pixel 7a (lynx)
#            GKI android14-6.1 — methode LKM (modules chargeables .ko)
#
# Cible EXACTE :
#   kernel/common  branche android14-6.1, commit edaaac4d5c85
#   noyau 6.1.145-android14 (KMI generation 11)
#   vermagic : 6.1.145-android14-11-gedaaac4d5c85 SMP preempt mod_unload
#              modversions aarch64
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
COMMIT="${COMMIT:-edaaac4d5c85cb9fb220767a9e5f859cb730fb27}"
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
  LLVM=""
  export CC=clang-17
  export LD=ld.lld-17
  export AR=llvm-ar-17
  export NM=llvm-nm-17
  export OBJCOPY=llvm-objcopy-17
  export OBJDUMP=llvm-objdump-17
  export READELF=llvm-readelf-17
  export STRIP=llvm-strip-17
  LLVM=1
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
  git clone --depth 1 -b "${BRANCH}" "${KERNEL_URL}" "${KERNEL_DIR}"
  ( cd "${KERNEL_DIR}" && git fetch --depth 1 origin "${COMMIT}" && git checkout "${COMMIT}" )
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

# ---------------------------------------------------------------------------
# 3. Generation .config (gki_defconfig + fragment)
# ---------------------------------------------------------------------------
log "3/7 : generation .config (gki_defconfig + nethunter.config)"
make -C "${KERNEL_DIR}" O="${OUT_DIR}" ARCH="${ARCH}" LLVM="${LLVM}" \
  gki_defconfig nethunter.config

# ---------------------------------------------------------------------------
# 4. Compilation noyau + modules in-tree
# ---------------------------------------------------------------------------
log "4/7 : compilation (jobs=${JOBS})"
make -C "${KERNEL_DIR}" O="${OUT_DIR}" ARCH="${ARCH}" LLVM="${LLVM}" \
  -j"${JOBS}" KCFLAGS="-D__ANDROID_COMMON_KERNEL__" WERROR=0

# ---------------------------------------------------------------------------
# 4bis. Verification & Alignement de Module.symvers (Google GKI ab16017558)
# ---------------------------------------------------------------------------
EXPECTED_CRC="0xea759d7f"
ACTUAL_CRC=$(grep -w "module_layout" "${OUT_DIR}/Module.symvers" 2>/dev/null | awk '{print $1}')
log "Verification CRC module_layout :"
log "  Attendu (Google GKI ab16017558) : ${EXPECTED_CRC}"
log "  Actuel (notre build)            : ${ACTUAL_CRC:-introuvable}"

OFFICIAL_SYMVERS="${CONFIGS_DIR}/vmlinux.symvers-ab16017558"
if [ ! -f "${OFFICIAL_SYMVERS}" ]; then
  log "  Telechargement du vmlinux.symvers officiel (ab16017558)..."
  curl -s -L "https://ci.android.com/builds/submitted/16017558/kernel_aarch64/latest/raw/vmlinux.symvers" -o "${OFFICIAL_SYMVERS}" || true
fi

if [ -f "${OFFICIAL_SYMVERS}" ]; then
  log "  Alignement de Module.symvers avec les symboles officiels GKI..."
  awk '$3 != "vmlinux"' "${OUT_DIR}/Module.symvers" > "${OUT_DIR}/Module.symvers.modules"
  cat "${OFFICIAL_SYMVERS}" "${OUT_DIR}/Module.symvers.modules" > "${OUT_DIR}/Module.symvers.aligned"
  mv -f "${OUT_DIR}/Module.symvers.aligned" "${OUT_DIR}/Module.symvers"
  rm -f "${OUT_DIR}/Module.symvers.modules"
  FINAL_CRC=$(grep -w "module_layout" "${OUT_DIR}/Module.symvers" 2>/dev/null | awk '{print $1}')
  log "  CRC module_layout final dans Module.symvers : ${FINAL_CRC}"
fi

WIRELESS_SYMVERS="${CONFIGS_DIR}/phone_wireless.symvers"
if [ -f "${WIRELESS_SYMVERS}" ]; then
  log "  Alignement de Module.symvers avec les symboles wireless du device..."
  awk '$3 !~ /^net\/(wireless|mac80211)/' "${OUT_DIR}/Module.symvers" > "${OUT_DIR}/Module.symvers.nowireless"
  cat "${OUT_DIR}/Module.symvers.nowireless" "${WIRELESS_SYMVERS}" > "${OUT_DIR}/Module.symvers.aligned"
  mv -f "${OUT_DIR}/Module.symvers.aligned" "${OUT_DIR}/Module.symvers"
  rm -f "${OUT_DIR}/Module.symvers.nowireless"
  WIPHY_CRC=$(grep -w "wiphy_register" "${OUT_DIR}/Module.symvers" 2>/dev/null | awk '{print $1}')
  log "  CRC wiphy_register final dans Module.symvers : ${WIPHY_CRC}"
fi

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
  for patch_name in "${name}-cfg80211-6.1.patch" "${name}-gki-fileio.patch"; do
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
