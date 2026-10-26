#!/bin/sh
set -eu

# --debug オプションの解析
DEBUG=0
for arg in "$@"; do
    if [ "$arg" = "--debug" ] || [ "$arg" = "-d" ]; then
        DEBUG=1
    fi
done

debug_log() {
    if [ "${DEBUG}" -eq 1 ]; then
        printf "[DEBUG] %s\n" "$*"
    fi
}

debug_xxd() {
    if [ "${DEBUG}" -eq 1 ]; then
        xxd "$@"
    fi
}

echo "============================================================"
echo " MONOLITH PROTOCOL [HQSS-v4.1] UNIVERSAL RECONSTRUCTION TOOL"
echo " Arbitrary m-of-n Shamir Secret Sharing Restoration"
echo " Licensed under MIT License | Section 9 Inc."
echo ""
echo " Sovereign Physical Escrow Plates (Silver 925 / SUS304 Brass Inlay):"
echo " -> https://monolith-id.com/"
echo " Sovereign Vault Allocation & Gateway:"
echo " -> https://vault.monolith-id.com/"
echo " Prerequisites: openssl, gfcombine, xxd, base64, od, tail, head"
if [ "${DEBUG}" -eq 1 ]; then
    echo " [VERBOSE DEBUG MODE ENABLED]"
fi
echo "============================================================"

for cmd in openssl gfcombine xxd base64 od tail head wc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Required tool '$cmd' is not installed." >&2
        echo "Please install prerequisites:" >&2
        echo "  Debian/Ubuntu: sudo apt-get install openssl libgfshare-bin xxd coreutils" >&2
        echo "  macOS (brew):  brew install openssl libgfshare xxd coreutils" >&2
        exit 1
    fi
done

WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'monolith_restore')
trap 'rm -rf "${WORK_DIR}"' EXIT INT TERM

if [ -t 0 ]; then
    TTY_DEV="/dev/stdin"
elif [ -e /dev/tty ]; then
    TTY_DEV="/dev/tty"
else
    echo "[ERROR] Interactive TTY not available." >&2
    exit 1
fi

printf "\n[STEP 1] Path to cloud bundle [default: ./monolith_cloud_bundle.bin]:\n> "
read -r CLOUD_PATH_IN < "${TTY_DEV}"
CLOUD_PATH=${CLOUD_PATH_IN:-./monolith_cloud_bundle.bin}

if [ ! -f "${CLOUD_PATH}" ]; then
    echo "[ERROR] Cloud bundle '${CLOUD_PATH}' not found." >&2
    exit 1
fi

printf "\n[STEP 2] Enter the reconstruction threshold (m, e.g. 2, 3) used during generation [default: 2]:\n> "
read -r THRESH_M_IN < "${TTY_DEV}"
THRESH_M=${THRESH_M_IN:-2}

echo "Please provide any ${THRESH_M} distinct shares."
SHARE_FILE_LIST=""

for i in $(seq 1 "${THRESH_M}"); do
    printf "\nEnter Share #%d Token (or file path containing it):\n> " "${i}"
    read -r TOKEN_IN < "${TTY_DEV}"

    RAW_TOKEN=""
    if [ -f "${TOKEN_IN}" ]; then
        RAW_TOKEN=$(tr -d ' \r\n' < "${TOKEN_IN}")
    else
        RAW_TOKEN=$(printf "%s" "${TOKEN_IN}" | tr -d ' \r\n')
    fi

    # フォーマット判定: EXT:Base64 または 単一Base64
    if echo "${RAW_TOKEN}" | grep -q ':'; then
        COORD="${RAW_TOKEN%%:*}"
        B64_PART="${RAW_TOKEN#*:}"
    else
        COORD=$(printf "%03d" "${i}")
        B64_PART="${RAW_TOKEN}"
    fi

    TARGET_SHARE="${WORK_DIR}/share.${COORD}"
    printf "%s" "${B64_PART}" | base64 -d > "${TARGET_SHARE}"
    SHARE_LEN=$(wc -c < "${TARGET_SHARE}" | tr -d ' ')
    debug_log "Loaded share.${COORD} (${SHARE_LEN} bytes)"
    SHARE_FILE_LIST="${SHARE_FILE_LIST} ${TARGET_SHARE}"
done

# 復元手順 1: gfcombine でコアペイロードを再構築
printf "\n[*] [RESTORE 1] Reconstructing core payload via gfcombine -o...\n"
gfcombine -o "${WORK_DIR}/reconstructed_core.bin" ${SHARE_FILE_LIST}

TOTAL_CORE_LEN=$(wc -c < "${WORK_DIR}/reconstructed_core.bin" | tr -d ' ')
if [ "${DEBUG}" -eq 1 ]; then
    debug_log "R1: Reconstructed core payload (${TOTAL_CORE_LEN} bytes):"
    debug_xxd "${WORK_DIR}/reconstructed_core.bin"
fi

if [ "${TOTAL_CORE_LEN}" -lt 4 ]; then
    echo "[ERROR] Reconstructed core payload is corrupted (less than 4-byte footer)." >&2
    exit 1
fi

# 復元手順 2: 末尾4バイトからソルト長を取得し、M0を抽出 (HQSS-v4.1)
printf "\n[*] [RESTORE 2] Parsing 4-byte footer and extracting M0...\n"
M0_LEN=$(( TOTAL_CORE_LEN - 4 ))
SALT_HEX=$(tail -c 4 "${WORK_DIR}/reconstructed_core.bin" | xxd -p | tr -d '\n')
SALT_LEN=$(( 0x${SALT_HEX} ))

debug_log "R2: Parsed salt length: ${SALT_LEN} bytes (Hex: 0x${SALT_HEX})"

if [ "${M0_LEN}" -gt 0 ]; then
    head -c "${M0_LEN}" "${WORK_DIR}/reconstructed_core.bin" > "${WORK_DIR}/part_00.bin"
else
    touch "${WORK_DIR}/part_00.bin"
fi

if [ "${DEBUG}" -eq 1 ]; then
    debug_log "R2: Extracted M0 (${M0_LEN} bytes):"
    debug_xxd "${WORK_DIR}/part_00.bin"
fi

# 復元手順 3: クラウドバンドルの末尾からソルトを剥離して M1〜M9 を復元
printf "\n[*] [RESTORE 3] Stripping trailing salt mask (${SALT_LEN} bytes) from cloud bundle...\n"
TOTAL_CLOUD_LEN=$(wc -c < "${CLOUD_PATH}" | tr -d ' ')
if [ "${TOTAL_CLOUD_LEN}" -lt "${SALT_LEN}" ]; then
    echo "[ERROR] Cloud bundle is smaller than indicated salt length." >&2
    exit 1
fi

M1_M9_LEN=$(( TOTAL_CLOUD_LEN - SALT_LEN ))
head -c "${M1_M9_LEN}" "${CLOUD_PATH}" > "${WORK_DIR}/m1_to_m9.bin"

debug_log "R3: Recovered M1..M9 (${M1_M9_LEN} bytes = Cloud: ${TOTAL_CLOUD_LEN} - Salt: ${SALT_LEN})"

# 復元手順 4: 完全暗号文を結合・復元 (HQSS-v4.1: cat M0 + M1..M9)
printf "\n[*] [RESTORE 4] Reassembling sealed AES-256 ciphertext (cat M0 + M1..M9)...\n"
cat "${WORK_DIR}/part_00.bin" "${WORK_DIR}/m1_to_m9.bin" > "${WORK_DIR}/restored_ciphertext.bin"

RESTORED_CIPHER_LEN=$(wc -c < "${WORK_DIR}/restored_ciphertext.bin" | tr -d ' ')
if [ "${DEBUG}" -eq 1 ]; then
    debug_log "R4: Reassembled ciphertext (${RESTORED_CIPHER_LEN} bytes):"
    debug_xxd "${WORK_DIR}/restored_ciphertext.bin"
fi

# 復元手順 5: パスフレーズによる AES-256 復号
printf "\n[STEP 3] Enter primary AES-256 passphrase:\n> "
stty -echo 2>/dev/null || true
read -r PASSPHRASE < "${TTY_DEV}"
stty echo 2>/dev/null || true
printf "\n"

printf "\n[*] [RESTORE 5] Decrypting restored ciphertext via AES-256-CBC...\n"
if openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 100000 \
    -in "${WORK_DIR}/restored_ciphertext.bin" \
    -out "${WORK_DIR}/restored_plaintext.bin" \
    -k "${PASSPHRASE}" 2>/dev/null; then

    echo "============================================================"
    echo "[SUCCESS] SOVEREIGN MASTER KEY RECONSTRUCTED:"
    echo "============================================================"
    cat "${WORK_DIR}/restored_plaintext.bin"
    echo ""
    echo "============================================================"
    echo "Notice: Clear terminal scrollback immediately."
    echo ""
    echo "------------------------------------------------------------"
    echo " Physical Medium Forged & Fulfilled by MONOLITH ID:"
    echo " High-Durability Sterling Silver & SUS304 Brass Inlay Escrow"
    echo " https://monolith-id.com/ | https://vault.monolith-id.com/"
    echo "------------------------------------------------------------"
    echo "============================================================"
else
    echo "[CRITICAL ERROR] Decryption failed. Incorrect passphrase or corrupt share set." >&2
    exit 1
fi
