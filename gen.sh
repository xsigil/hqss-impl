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
echo " MONOLITH PROTOCOL [HQSS-v4.1] UNIVERSAL PROVISIONING TOOL"
echo " Arbitrary m-of-n Shamir Secret Sharing over GF(2^8)"
echo " Licensed under MIT License | Section 9 Inc."
echo ""
echo " Sovereign Physical Escrow Plates (Silver 925 / SUS304 Brass Inlay):"
echo " -> https://monolith-id.com/"
echo " Prerequisites: openssl, split, gfsplit, gfcombine, xxd, base64"
if [ "${DEBUG}" -eq 1 ]; then
    echo " [VERBOSE DEBUG MODE ENABLED]"
fi
echo "============================================================"

for cmd in openssl split gfsplit gfcombine xxd base64 od tail head wc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Required tool '$cmd' is not installed." >&2
        echo "Please install prerequisites:" >&2
        echo "  Debian/Ubuntu: sudo apt-get install openssl libgfshare-bin xxd coreutils" >&2
        echo "  macOS (brew):  brew install openssl libgfshare xxd coreutils" >&2
        exit 1
    fi
done

WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'monolith_hqss4')
trap 'rm -rf "${WORK_DIR}"' EXIT INT TERM

if [ -t 0 ]; then
    TTY_DEV="/dev/stdin"
elif [ -e /dev/tty ]; then
    TTY_DEV="/dev/tty"
else
    echo "[ERROR] Interactive TTY not available." >&2
    exit 1
fi

# 1. 秘密ファイルパスの入力 (ファイルパス入力・1回のエンターで即時確定)
printf "\n[STEP 1] Enter file path to master secret:\n"
printf "(e.g. ./secret.key, ./k, ~/.gnupg/secring.gpg)\n> "

read -r TARGET_FILE_PATH < "${TTY_DEV}"

# チルダ(~)展開のサポート
EXPANDED_PATH="${TARGET_FILE_PATH}"
case "${EXPANDED_PATH}" in
    "~"/*)
        EXPANDED_PATH="${HOME}/${EXPANDED_PATH#\~/}"
        ;;
    "~")
        EXPANDED_PATH="${HOME}"
        ;;
esac

if [ -z "${EXPANDED_PATH}" ]; then
    echo "[ERROR] File path cannot be empty." >&2
    exit 1
fi

if [ ! -f "${EXPANDED_PATH}" ]; then
    echo "[ERROR] File not found: '${TARGET_FILE_PATH}'" >&2
    exit 1
fi

if [ ! -s "${EXPANDED_PATH}" ]; then
    echo "[ERROR] File is empty (0 bytes): '${TARGET_FILE_PATH}'" >&2
    exit 1
fi

SECRET_FILE="${WORK_DIR}/plaintext.bin"
cp -f "${EXPANDED_PATH}" "${SECRET_FILE}"
echo "[✓] Loaded master secret from file: ${TARGET_FILE_PATH} ($(wc -c < "${SECRET_FILE}" | tr -d ' ') bytes)"

# 2. 基本暗号化 (AES-256-CBC, PBKDF2)
printf "\n[STEP 2] Enter primary AES-256 passphrase:\n"
printf "(This passphrase remains strictly in your memory; MONOLITH can NEVER decrypt without it)\n> "
stty -echo 2>/dev/null || true
read -r PASSPHRASE < "${TTY_DEV}"
stty echo 2>/dev/null || true
printf "\n"

if [ -z "${PASSPHRASE}" ]; then
    echo "[ERROR] Passphrase cannot be empty." >&2
    exit 1
fi

# 3. m-of-n パラメータの設定
printf "[STEP 3] Configure Shamir Threshold Parameters:\n"
printf "Enter TOTAL physical plates to fabricate (n, e.g. 3, 5, 7) [default: 5]:\n> "
read -r TOTAL_N_IN < "${TTY_DEV}"
TOTAL_N=${TOTAL_N_IN:-5}

printf "Enter RECONSTRUCTION THRESHOLD (m, e.g. 2, 3) [default: 2]:\n> "
read -r THRESH_M_IN < "${TTY_DEV}"
THRESH_M=${THRESH_M_IN:-2}

if [ "${THRESH_M}" -lt 2 ] || [ "${THRESH_M}" -gt "${TOTAL_N}" ]; then
    echo "[ERROR] Invalid threshold parameters. Must satisfy 2 <= m <= n." >&2
    exit 1
fi

# 4. 手順 1: 暗号化
printf "\n[*] [STEP 1] Encrypting secret via AES-256-CBC (PBKDF2 100,000 iter)...\n"
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
    -in "${WORK_DIR}/plaintext.bin" \
    -out "${WORK_DIR}/ciphertext.bin" \
    -k "${PASSPHRASE}"

CIPHER_SIZE=$(wc -c < "${WORK_DIR}/ciphertext.bin" | tr -d ' ')
debug_log "1: Ciphertext created (${CIPHER_SIZE} bytes)"
if [ "${DEBUG}" -eq 1 ]; then
    head -c 32 "${WORK_DIR}/ciphertext.bin" | debug_xxd
fi

# 5. 手順 2: split -n 10 による均等10スライス
# HQSS-v4.1: part_00 (M0) を物理プレート(コアペイロード)に隔離し、
# part_01..part_09 (M1..M9) をクラウドバンドルへ配置
printf "\n[*] [STEP 2] Slicing ciphertext into 10 partitions via split -n 10...\n"
split -n 10 -d "${WORK_DIR}/ciphertext.bin" "${WORK_DIR}/part_"

cat "${WORK_DIR}/part_01" \
    "${WORK_DIR}/part_02" \
    "${WORK_DIR}/part_03" \
    "${WORK_DIR}/part_04" \
    "${WORK_DIR}/part_05" \
    "${WORK_DIR}/part_06" \
    "${WORK_DIR}/part_07" \
    "${WORK_DIR}/part_08" \
    "${WORK_DIR}/part_09" > "${WORK_DIR}/m1_to_m9.bin"

M1_M9_SIZE=$(wc -c < "${WORK_DIR}/m1_to_m9.bin" | tr -d ' ')
M0_SIZE=$(wc -c < "${WORK_DIR}/part_00" | tr -d ' ')
M0_HEX=$(head -c 16 "${WORK_DIR}/part_00" | xxd -p | tr -d '\n')
debug_log "2: Part M1..M9 concatenated: ${M1_M9_SIZE} bytes"
debug_log "2: Part M0 isolated: ${M0_SIZE} bytes (Header prefix: ${M0_HEX})"

# 6. 手順 3: 可変長ランダムソルト (0..4095バイト) 生成と M1..M9 結合
printf "\n[*] [STEP 3] Synthesizing CSPRNG salt mask (0..4095 bytes) & appending to M1..M9...\n"
RAND_HEX=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')
SALT_LEN=$(( 0x${RAND_HEX} % 4096 ))

if [ "${SALT_LEN}" -gt 0 ]; then
    head -c "${SALT_LEN}" /dev/urandom > "${WORK_DIR}/rand_salt.bin"
else
    touch "${WORK_DIR}/rand_salt.bin"
fi

cat "${WORK_DIR}/m1_to_m9.bin" "${WORK_DIR}/rand_salt.bin" > "monolith_cloud_bundle.bin"
chmod 644 "monolith_cloud_bundle.bin"

CLOUD_SIZE=$(wc -c < "monolith_cloud_bundle.bin" | tr -d ' ')
debug_log "3: Salt length: ${SALT_LEN} bytes (Hex: $(printf '0x%08x' ${SALT_LEN}))"
debug_log "3: Cloud bundle created: ${CLOUD_SIZE} bytes (M1..M9: ${M1_M9_SIZE} + Salt: ${SALT_LEN})"
if [ "${DEBUG}" -eq 1 ]; then
    debug_log "3: Cloud bundle tail (last 16 bytes):"
    tail -c 16 "monolith_cloud_bundle.bin" | debug_xxd
fi

# 7. 手順 4: コアペイロードの作成 (M0 + 4byte uint32 ビッグエンディアン)
printf "\n[*] [STEP 4] Assembling core payload (M0 + 4-byte big-endian uint32 footer)...\n"
printf "%08x" "${SALT_LEN}" | xxd -r -p > "${WORK_DIR}/len_footer.bin"
cat "${WORK_DIR}/part_00" "${WORK_DIR}/len_footer.bin" > "${WORK_DIR}/core_payload.bin"

CORE_SIZE=$(wc -c < "${WORK_DIR}/core_payload.bin" | tr -d ' ')
debug_log "4: Core payload assembled (${CORE_SIZE} bytes):"
if [ "${DEBUG}" -eq 1 ]; then
    debug_xxd "${WORK_DIR}/core_payload.bin"
fi

# 8. 手順 5: gfsplit による m-of-n シャミア秘密分散
printf "\n[*] [STEP 5] Dispersing core payload via gfsplit over GF(2^8) (${THRESH_M}-of-${TOTAL_N})...\n"
gfsplit -n "${THRESH_M}" -m "${TOTAL_N}" "${WORK_DIR}/core_payload.bin" "${WORK_DIR}/share"

if [ "${DEBUG}" -eq 1 ]; then
    debug_log "5: Generated share files by gfsplit:"
    ls -l "${WORK_DIR}"/share.*
fi

# 9. 手順 6: gfcombine によるローカル復元自己テスト
printf "\n[*] [STEP 6] Executing local round-trip test via gfcombine (combining first %s shares)...\n" "${THRESH_M}"
TEST_SHARES=$(ls -1 "${WORK_DIR}"/share.* 2>/dev/null | grep -v '\.000$' | grep -v '\.0$' | head -n "${THRESH_M}" | tr '\n' ' ')

debug_log "6: Selected shares: ${TEST_SHARES}"

gfcombine -o "${WORK_DIR}/test_reconstructed_core.bin" ${TEST_SHARES}

ORIGINAL_HASH=$(openssl dgst -sha256 "${WORK_DIR}/core_payload.bin" | awk '{print $NF}')
VERIFIED_HASH=$(openssl dgst -sha256 "${WORK_DIR}/test_reconstructed_core.bin" | awk '{print $NF}')

if [ "${DEBUG}" -eq 1 ]; then
    debug_log "6: Reconstructed core payload hex dump:"
    debug_xxd "${WORK_DIR}/test_reconstructed_core.bin"
    debug_log "6: Original Core SHA256: ${ORIGINAL_HASH}"
    debug_log "6: Verified Core SHA256: ${VERIFIED_HASH}"
fi

if [ "${ORIGINAL_HASH}" != "${VERIFIED_HASH}" ]; then
    echo "[CRITICAL FAILURE] gfcombine round-trip verification failed." >&2
    exit 1
fi

echo "[✓] Core payload mathematically verified across threshold ${THRESH_M}."

# 10. 各シェアを Base64 化し、インデックス紐付きでファイル保存
SUBMISSION_FILE="monolith_order_submission.txt"
cat << EOF > "${SUBMISSION_FILE}"
============================================================
 MONOLITH ID | HQSS-v4.1 SOVEREIGN ORDER SUBMISSION
 Master Secret Sealing Specification (M0 Isolated Architecture)
 Target: Suite of ${TOTAL_N} Physical Plates (Threshold: ${THRESH_M}-of-${TOTAL_N})
 Timestamp: $(date -u '+%Y-%m-%d %H:%M:%SZ')
 Cloud Bundle Salt Length: ${SALT_LEN} bytes
============================================================

[MATHEMATICAL GUARANTEE]
All shares below represent only the sealed core payload (P_core containing M0).
Even with possession of all ${TOTAL_N} physical shares and the cloud bundle,
the master secret CANNOT be recovered without the client's AES-256 passphrase.
Furthermore, the cloud bundle alone contains zero PBKDF2 salt or IV, mathematically
blocking offline dictionary attacks and known-plaintext validation.

--- BEGIN MONOLITH DISPERSION MATRIX ---
EOF

idx=1
for raw_file in $(ls -1 "${WORK_DIR}"/share.* 2>/dev/null | grep -v '\.000$' | grep -v '\.0$'); do
    EXT="${raw_file##*.}"
    B64_DATA=$(base64 < "${raw_file}" | tr -d '\r\n')
    PAYLOAD_TOKEN="${EXT}:${B64_DATA}"

    OUT_FILE="monolith_share_${idx}.txt"
    echo "${PAYLOAD_TOKEN}" > "${OUT_FILE}"
    chmod 600 "${OUT_FILE}"

    echo "SHARE_ID: ${idx}" >> "${SUBMISSION_FILE}"
    echo "GF_X_COORDINATE: ${EXT}" >> "${SUBMISSION_FILE}"
    echo "PAYLOAD_TOKEN: ${PAYLOAD_TOKEN}" >> "${SUBMISSION_FILE}"
    echo "" >> "${SUBMISSION_FILE}"

    idx=$(( idx + 1 ))
done

echo "--- END MONOLITH DISPERSION MATRIX ---" >> "${SUBMISSION_FILE}"
chmod 600 "${SUBMISSION_FILE}"

echo ""
echo "------------------------------------------------------------"
echo "[SUCCESS] HQSS-v4.1 PROVISIONING COMPLETE (${THRESH_M}-of-${TOTAL_N} CONFIGURATION)"
echo "------------------------------------------------------------"
echo ""
echo "[A] CLOUD BUNDLE (Deploy to personal S3 / Google Drive / Public host):"
echo "    -> ./monolith_cloud_bundle.bin"
echo ""
echo "[B] INDIVIDUAL PHYSICAL SHARE BACKUPS:"
for i in $(seq 1 "${TOTAL_N}"); do
    echo "    - ./monolith_share_${i}.txt (Plate #${i})"
done
echo ""
echo "[C] COMPLETE MONOLITH SUITE ORDER DISPATCH FILE:"
echo "    -> ./${SUBMISSION_FILE}"
echo ""
echo "============================================================"
echo "[ACTION REQUIRED] DISPATCH TO MONOLITH FORGING STUDIO:"
echo "Encrypt the submission file using MONOLITH Public GnuPG Key and send to:"
echo "Recipient: office@section-9.sh"
echo ""
echo "Example GPG Encryption Command:"
echo "$ gpg --armor --encrypt --recipient office@section-9.sh ${SUBMISSION_FILE}"
echo "Then transmit ${SUBMISSION_FILE}.asc via your preferred secure channel."
echo ""
echo "------------------------------------------------------------"
echo " Physical Medium Forged & Fulfilled by MONOLITH ID:"
echo " High-Durability Sterling Silver & SUS304 Brass Inlay Escrow"
echo " https://monolith-id.com/"
echo "------------------------------------------------------------"
echo "============================================================"