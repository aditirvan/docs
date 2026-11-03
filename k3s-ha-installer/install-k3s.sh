#!/usr/bin/env bash
#
# install-k3s.sh
# Interactive installer untuk k3s cluster (3 master HA + N worker)
#
# Usage: sudo bash install-k3s.sh
#

set -euo pipefail

# ---------- helper ----------
c_green() { echo -e "\033[0;32m$1\033[0m"; }
c_yellow() { echo -e "\033[1;33m$1\033[0m"; }
c_red() { echo -e "\033[0;31m$1\033[0m"; }

die() {
  c_red "ERROR: $1"
  exit 1
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Script ini harus dijalankan sebagai root (pakai sudo)."
  fi
}

require_root

echo "=================================================="
echo "   K3S INTERACTIVE INSTALLER"
echo "=================================================="
echo

# ---------- 0. Aksi: install, uninstall, atau upgrade ----------
echo "Pilih aksi:"
echo "  1) Install k3s"
echo "  2) Uninstall k3s"
echo "  3) Upgrade k3s"
read -rp "Pilihan [1/2/3]: " ACTION_CHOICE
echo

if [[ "${ACTION_CHOICE}" == "2" ]]; then
  # ---------- UNINSTALL FLOW ----------
  SERVER_UNINSTALL="/usr/local/bin/k3s-uninstall.sh"
  AGENT_UNINSTALL="/usr/local/bin/k3s-agent-uninstall.sh"

  if [[ -x "${SERVER_UNINSTALL}" ]]; then
    FOUND_SCRIPT="${SERVER_UNINSTALL}"
    FOUND_TYPE="server (master)"
  elif [[ -x "${AGENT_UNINSTALL}" ]]; then
    FOUND_SCRIPT="${AGENT_UNINSTALL}"
    FOUND_TYPE="agent (worker)"
  else
    die "Tidak ditemukan instalasi k3s di node ini (script uninstall tidak ada)."
  fi

  c_yellow "Terdeteksi instalasi k3s tipe: ${FOUND_TYPE}"
  c_red "PERINGATAN: Uninstall akan menghapus k3s beserta SEMUA data cluster di node ini,"
  c_red "termasuk etcd (jika node ini master) dan semua pod/config lokal. Tindakan ini TIDAK BISA dibatalkan."
  echo
  read -rp "Ketik 'UNINSTALL' (huruf besar) untuk konfirmasi: " CONFIRM_UNINSTALL

  if [[ "${CONFIRM_UNINSTALL}" != "UNINSTALL" ]]; then
    c_yellow "Uninstall dibatalkan."
    exit 0
  fi

  c_yellow "Menjalankan ${FOUND_SCRIPT} ..."
  bash "${FOUND_SCRIPT}"

  # Bersihkan sisa config jika masih ada
  if [[ -d /etc/rancher/k3s ]]; then
    read -rp "Hapus juga folder config /etc/rancher/k3s? [y/N]: " CLEAN_CONFIG
    if [[ "${CLEAN_CONFIG}" =~ ^[Yy]$ ]]; then
      rm -rf /etc/rancher/k3s
      c_green "Folder /etc/rancher/k3s dihapus."
    fi
  fi

  c_green "Uninstall selesai."
  exit 0
fi

if [[ "${ACTION_CHOICE}" == "3" ]]; then
  # ---------- UPGRADE FLOW ----------
  SERVER_UNINSTALL="/usr/local/bin/k3s-uninstall.sh"
  AGENT_UNINSTALL="/usr/local/bin/k3s-agent-uninstall.sh"

  if [[ -x "${SERVER_UNINSTALL}" ]]; then
    NODE_ROLE="server"
    FOUND_TYPE="server (master)"
  elif [[ -x "${AGENT_UNINSTALL}" ]]; then
    NODE_ROLE="agent"
    FOUND_TYPE="agent (worker)"
  else
    die "Tidak ditemukan instalasi k3s di node ini. Gunakan menu Install dulu."
  fi

  if ! command -v k3s >/dev/null 2>&1; then
    die "Binary k3s tidak ditemukan di PATH."
  fi

  CURRENT_VERSION=$(k3s --version | head -n1 | awk '{print $3}')
  c_yellow "Terdeteksi node tipe: ${FOUND_TYPE}"
  c_yellow "Versi k3s saat ini  : ${CURRENT_VERSION}"
  echo

  c_yellow "Contoh format versi tujuan: v1.35.2+k3s1"
  c_yellow "Lihat daftar versi lengkap di: https://github.com/k3s-io/k3s/releases"
  read -rp "Masukkan versi k3s tujuan upgrade: " TARGET_VERSION
  [[ -z "${TARGET_VERSION}" ]] && die "Versi tujuan wajib diisi."
  echo

  # ---------- Parsing minor version untuk cek skip-version ----------
  extract_minor() {
    # v1.34.1+k3s1 -> 34
    echo "$1" | sed -E 's/^v?1\.([0-9]+)\..*/\1/'
  }

  CURRENT_MINOR=$(extract_minor "${CURRENT_VERSION}")
  TARGET_MINOR=$(extract_minor "${TARGET_VERSION}")

  if [[ "${CURRENT_MINOR}" =~ ^[0-9]+$ && "${TARGET_MINOR}" =~ ^[0-9]+$ ]]; then
    MINOR_DIFF=$(( TARGET_MINOR - CURRENT_MINOR ))

    if (( MINOR_DIFF < 0 )); then
      die "Versi tujuan (1.${TARGET_MINOR}) lebih rendah dari versi saat ini (1.${CURRENT_MINOR}). Downgrade tidak didukung script ini."
    elif (( MINOR_DIFF > 1 )); then
      c_red "PERINGATAN: Kamu mencoba loncat dari 1.${CURRENT_MINOR} ke 1.${TARGET_MINOR} (lompat ${MINOR_DIFF} minor version)."
      c_red "Kubernetes/k3s hanya resmi mendukung upgrade 1 minor version setiap kali."
      c_red "Rekomendasi: upgrade bertahap, misal 1.${CURRENT_MINOR} -> 1.$((CURRENT_MINOR + 1)) -> ... -> 1.${TARGET_MINOR}."
      echo
      read -rp "Tetap paksakan upgrade langsung? Ketik 'PAKSA' untuk lanjut, selain itu akan dibatalkan: " FORCE_UPGRADE
      if [[ "${FORCE_UPGRADE}" != "PAKSA" ]]; then
        c_yellow "Upgrade dibatalkan. Silakan upgrade bertahap satu minor version dulu."
        exit 0
      fi
      c_red "Melanjutkan upgrade langsung atas permintaan sendiri. Risiko ditanggung sendiri."
    else
      c_green "Upgrade 1 minor version (1.${CURRENT_MINOR} -> 1.${TARGET_MINOR}), sesuai rekomendasi resmi."
    fi
  else
    c_yellow "Tidak bisa parsing minor version otomatis, lanjut tanpa pengecekan skip-version."
  fi
  echo

  # ---------- Cordon & drain (opsional, terutama untuk worker) ----------
  DRAIN_DONE=false
  if command -v kubectl >/dev/null 2>&1 || [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    read -rp "Cordon & drain node ini dulu sebelum upgrade? (disarankan, terutama worker) [Y/n]: " DO_DRAIN
    if [[ ! "${DO_DRAIN}" =~ ^[Nn]$ ]]; then
      NODE_HOSTNAME=$(hostname)
      c_yellow "Cordon & drain node ${NODE_HOSTNAME} ..."
      if k3s kubectl cordon "${NODE_HOSTNAME}" 2>/dev/null; then
        k3s kubectl drain "${NODE_HOSTNAME}" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s || \
          c_yellow "Drain tidak sepenuhnya sukses (mungkin ada pod yang tidak bisa dipindah). Lanjut tetap upgrade."
        DRAIN_DONE=true
      else
        c_yellow "Tidak bisa cordon (mungkin node-name di cluster beda dengan hostname). Lanjut tanpa drain."
      fi
    fi
  fi
  echo

  read -rp "Lanjutkan upgrade ke ${TARGET_VERSION}? [y/N]: " CONFIRM_UPGRADE
  if [[ ! "${CONFIRM_UPGRADE}" =~ ^[Yy]$ ]]; then
    c_yellow "Upgrade dibatalkan."
    if [[ "${DRAIN_DONE}" == true ]]; then
      k3s kubectl uncordon "$(hostname)" || true
    fi
    exit 0
  fi

  export INSTALL_K3S_VERSION="${TARGET_VERSION}"

  c_yellow "Menjalankan upgrade k3s ke ${TARGET_VERSION} ..."
  if [[ "${NODE_ROLE}" == "server" ]]; then
    curl -sfL https://get.k3s.io | sh -
  else
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent" sh -
  fi

  echo
  c_yellow "Menunggu service restart..."
  sleep 10

  NEW_VERSION=$(k3s --version | head -n1 | awk '{print $3}')
  c_green "Upgrade selesai. Versi sekarang: ${NEW_VERSION}"

  if [[ "${DRAIN_DONE}" == true ]]; then
    echo
    read -rp "Uncordon node ini sekarang? [Y/n]: " DO_UNCORDON
    if [[ ! "${DO_UNCORDON}" =~ ^[Nn]$ ]]; then
      k3s kubectl uncordon "$(hostname)" || true
      c_green "Node di-uncordon, pod bisa dijadwalkan lagi ke sini."
    else
      c_yellow "Node masih cordoned. Jalankan manual: kubectl uncordon $(hostname)"
    fi
  fi

  if [[ "${NODE_ROLE}" == "server" ]]; then
    echo
    c_yellow "Status node cluster:"
    k3s kubectl get nodes -o wide || true
  fi

  echo
  c_green "Selesai."
  exit 0
fi

# ---------- INSTALL FLOW (lanjut ke bawah) ----------

# ---------- 1. Hostname ----------
CURRENT_HOSTNAME=$(hostname)
c_yellow "Hostname saat ini: ${CURRENT_HOSTNAME}"
read -rp "Masukkan hostname baru (kosongkan jika tidak ingin diganti): " NEW_HOSTNAME

if [[ -n "${NEW_HOSTNAME}" ]]; then
  hostnamectl set-hostname "${NEW_HOSTNAME}"
  c_green "Hostname diganti menjadi: ${NEW_HOSTNAME}"
  CURRENT_HOSTNAME="${NEW_HOSTNAME}"
else
  c_yellow "Hostname tidak diubah."
fi
echo

# ---------- 2. Mode instalasi ----------
echo "Pilih mode instalasi node ini:"
echo "  1) Master pertama (cluster-init, HA etcd)"
echo "  2) Master tambahan (join sebagai server/etcd member)"
echo "  3) Worker (join sebagai agent)"
read -rp "Pilihan [1/2/3]: " MODE_CHOICE

case "${MODE_CHOICE}" in
  1) MODE="init" ;;
  2) MODE="server-join" ;;
  3) MODE="agent-join" ;;
  *) die "Pilihan tidak valid." ;;
esac
echo

# ---------- Token & server (untuk join) ----------
if [[ "${MODE}" == "server-join" || "${MODE}" == "agent-join" ]]; then
  read -rp "Masukkan URL server master pertama (contoh: https://172.22.81.10:6443): " SERVER_URL
  [[ -z "${SERVER_URL}" ]] && die "Server URL wajib diisi."

  read -rsp "Masukkan token cluster: " TOKEN
  echo
  [[ -z "${TOKEN}" ]] && die "Token wajib diisi."
else
  read -rsp "Masukkan token cluster (akan dipakai node lain untuk join): " TOKEN
  echo
  [[ -z "${TOKEN}" ]] && die "Token wajib diisi."
fi
echo

# ---------- 3. Node name ----------
read -rp "Masukkan node-name [default: ${CURRENT_HOSTNAME}]: " NODE_NAME
NODE_NAME="${NODE_NAME:-${CURRENT_HOSTNAME}}"
echo

# ---------- 4. Node IP ----------
c_yellow "IP address yang terdeteksi di server ini:"
ip -4 -o addr show | awk '{print "  - "$2": "$4}' | grep -v ' lo:'
read -rp "Masukkan node-ip: " NODE_IP
[[ -z "${NODE_IP}" ]] && die "node-ip wajib diisi."
echo

# ---------- 5. Flannel interface ----------
c_yellow "Interface network yang tersedia:"
ip -o link show | awk -F': ' '{print $2}' | grep -v lo
read -rp "Masukkan flannel-iface: " FLANNEL_IFACE
[[ -z "${FLANNEL_IFACE}" ]] && die "flannel-iface wajib diisi."
echo

# ---------- 6. Versi k3s ----------
c_yellow "Contoh format versi: v1.37.1+k3s1"
c_yellow "Lihat daftar versi lengkap di: https://github.com/k3s-io/k3s/releases"
read -rp "Masukkan versi k3s yang ingin diinstall (kosongkan untuk versi latest/stable): " K3S_VERSION

if [[ -n "${K3S_VERSION}" ]]; then
  c_green "Akan menginstall k3s versi: ${K3S_VERSION}"
else
  c_yellow "Akan menginstall k3s versi latest/stable (default)."
fi
echo

# ---------- TLS SAN (khusus master) ----------
TLS_SAN_YAML=""
if [[ "${MODE}" == "init" || "${MODE}" == "server-join" ]]; then
  echo "Masukkan semua IP master untuk tls-san (pisahkan koma, contoh: 172.22.81.10,172.22.81.12,172.22.81.13)"
  read -rp "tls-san: " TLS_SAN_INPUT
  [[ -z "${TLS_SAN_INPUT}" ]] && die "tls-san wajib diisi untuk node master."

  TLS_SAN_YAML="tls-san:\n"
  IFS=',' read -ra SAN_ARR <<< "${TLS_SAN_INPUT}"
  for san in "${SAN_ARR[@]}"; do
    san_trimmed=$(echo "${san}" | xargs)
    TLS_SAN_YAML+="  - '${san_trimmed}'\n"
  done
  TLS_SAN_YAML+="  - '127.0.0.1'\n"
  echo
fi

# ---------- Konfirmasi ----------
echo "=================================================="
echo "Ringkasan konfigurasi:"
echo "  Mode        : ${MODE}"
echo "  Hostname    : ${CURRENT_HOSTNAME}"
echo "  Node Name   : ${NODE_NAME}"
echo "  Node IP     : ${NODE_IP}"
echo "  Flannel If  : ${FLANNEL_IFACE}
  K3s Version : ${K3S_VERSION:-latest/stable}"
[[ "${MODE}" != "init" ]] && echo "  Server URL  : ${SERVER_URL}"
echo "=================================================="
read -rp "Lanjutkan instalasi? [y/N]: " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  c_yellow "Instalasi dibatalkan."
  exit 0
fi
echo

# ---------- Buat direktori config ----------
mkdir -p /etc/rancher/k3s

# ---------- Kubelet-arg umum (dipakai semua mode) ----------
KUBELET_ARGS="kubelet-arg:
  - 'volume-stats-agg-period=1m'
  - 'eviction-max-pod-grace-period=60'
  - 'kube-reserved=cpu=200m,memory=512Mi,ephemeral-storage=1Gi'
  - 'system-reserved=cpu=200m,memory=512Mi,ephemeral-storage=1Gi'
  - 'eviction-hard=memory.available<800Mi,nodefs.available<10%,nodefs.inodesFree<5%'
  - 'eviction-soft=memory.available<1.5Gi,nodefs.available<10%,nodefs.inodesFree<10%'
  - 'eviction-soft-grace-period=memory.available=1m,nodefs.available=1m,nodefs.inodesFree=1m'"

# ---------- Generate config.yaml ----------
CONFIG_FILE="/etc/rancher/k3s/config.yaml"

if [[ "${MODE}" == "init" ]]; then
  cat > "${CONFIG_FILE}" <<EOF
token: '${TOKEN}'
node-name: '${NODE_NAME}'
node-ip: '${NODE_IP}'
cluster-init: true
$(echo -e "${TLS_SAN_YAML}")
cluster-cidr: '10.44.0.0/16'
service-cidr: '10.45.0.0/16'
flannel-iface: '${FLANNEL_IFACE}'
disable:
  - 'traefik'
  - 'servicelb'
  - 'local-storage'
node-taint:
  - 'node-role.kubernetes.io/master=true:NoSchedule'
kube-controller-manager-arg:
  - bind-address=0.0.0.0
kube-scheduler-arg:
  - bind-address=0.0.0.0
kube-proxy-arg:
  - metrics-bind-address=0.0.0.0
${KUBELET_ARGS}
etcd-snapshot-name: etcd-snapshot-obs-tbs
etcd-snapshot-schedule-cron: '0 */12 * * *'
etcd-snapshot-retention: 60
EOF

elif [[ "${MODE}" == "server-join" ]]; then
  cat > "${CONFIG_FILE}" <<EOF
token: '${TOKEN}'
node-name: '${NODE_NAME}'
node-ip: '${NODE_IP}'
server: '${SERVER_URL}'
$(echo -e "${TLS_SAN_YAML}")
cluster-cidr: '10.44.0.0/16'
service-cidr: '10.45.0.0/16'
flannel-iface: '${FLANNEL_IFACE}'
disable:
  - 'traefik'
  - 'servicelb'
  - 'local-storage'
node-taint:
  - 'node-role.kubernetes.io/master=true:NoSchedule'
kube-controller-manager-arg:
  - bind-address=0.0.0.0
kube-scheduler-arg:
  - bind-address=0.0.0.0
kube-proxy-arg:
  - metrics-bind-address=0.0.0.0
${KUBELET_ARGS}
etcd-snapshot-name: etcd-snapshot-obs-tbs
etcd-snapshot-schedule-cron: '0 */12 * * *'
etcd-snapshot-retention: 60
EOF

else # agent-join (worker)
  cat > "${CONFIG_FILE}" <<EOF
token: '${TOKEN}'
node-name: '${NODE_NAME}'
node-ip: '${NODE_IP}'
server: '${SERVER_URL}'
flannel-iface: '${FLANNEL_IFACE}'
${KUBELET_ARGS}
EOF
fi

c_green "Config berhasil dibuat di ${CONFIG_FILE}"
echo
cat "${CONFIG_FILE}"
echo

# ---------- Sysctl tuning (inotify, file-max) ----------
c_yellow "K3s/containerd sering butuh limit file descriptor & inotify watcher yang lebih besar"
c_yellow "dari default OS, untuk menghindari error 'too many open files'."
echo "Ini akan membuat/menimpa file: /etc/sysctl.d/99-kubernetes.conf berisi:"
echo "  fs.inotify.max_user_watches = 2097152"
echo "  fs.inotify.max_user_instances = 8192"
echo "  fs.file-max = 2097152"
read -rp "Terapkan sysctl tuning ini sekarang? [y/N]: " APPLY_SYSCTL

if [[ "${APPLY_SYSCTL}" =~ ^[Yy]$ ]]; then
  SYSCTL_FILE="/etc/sysctl.d/99-kubernetes.conf"

  if [[ -f "${SYSCTL_FILE}" ]]; then
    cp "${SYSCTL_FILE}" "${SYSCTL_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    c_yellow "File sysctl lama sudah ada, dibackup ke ${SYSCTL_FILE}.bak.*"
  fi

  cat > "${SYSCTL_FILE}" <<EOF
fs.inotify.max_user_watches = 2097152
fs.inotify.max_user_instances = 8192
fs.file-max = 2097152
EOF

  sysctl --system > /dev/null
  c_green "Sysctl tuning diterapkan (${SYSCTL_FILE})."
else
  c_yellow "Sysctl tuning dilewati. Bisa diterapkan manual nanti kalau perlu."
fi
echo

# ---------- Install k3s ----------
c_yellow "Menginstall k3s..."

if [[ -n "${K3S_VERSION}" ]]; then
  export INSTALL_K3S_VERSION="${K3S_VERSION}"
fi

if [[ "${MODE}" == "init" || "${MODE}" == "server-join" ]]; then
  curl -sfL https://get.k3s.io | sh -
else
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent" sh -
fi

echo
c_green "Instalasi selesai!"

if [[ "${MODE}" == "init" || "${MODE}" == "server-join" ]]; then
  echo
  c_yellow "Cek status node (tunggu beberapa detik jika baru saja start):"
  sleep 5
  k3s kubectl get nodes -o wide || true
  echo
  c_yellow "Token untuk join node lain:"
  cat /var/lib/rancher/k3s/server/node-token
else
  echo
  c_yellow "Cek status agent:"
  systemctl status k3s-agent --no-pager | head -n 10
fi

echo
c_green "Selesai."
