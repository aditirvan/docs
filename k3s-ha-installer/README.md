# k3s-ha-installer

Script bash interaktif untuk install, uninstall, dan upgrade **k3s cluster HA** (3 master embedded etcd + N worker), dengan workload isolation ke worker node (master di-taint `NoSchedule`).

## Fitur

- ✅ Install k3s — mode **master pertama** (cluster-init), **master tambahan** (join server/etcd), atau **worker** (join agent)
- ✅ Ganti hostname otomatis via `hostnamectl`
- ✅ Generate `/etc/rancher/k3s/config.yaml` otomatis sesuai mode node
- ✅ Pilih versi k3s spesifik (contoh: `v1.36.4+k3s1`) atau pakai default stable
- ✅ Sysctl tuning opsional (`inotify`, `file-max`) untuk mencegah error `too many open files`
- ✅ Uninstall k3s dengan konfirmasi eksplisit (deteksi otomatis server/agent)
- ✅ Upgrade k3s dengan:
  - Deteksi otomatis versi saat ini & tipe node
  - **Proteksi skip-version** — menolak/memperingatkan kalau loncat lebih dari 1 minor version (sesuai kebijakan resmi Kubernetes)
  - Cordon & drain otomatis sebelum upgrade, uncordon setelah selesai

## Struktur repo

```
k3s-ha-installer/
├── install-k3s.sh   # script utama (install / uninstall / upgrade)
└── README.md
```

## Prasyarat

- OS Linux (Ubuntu/Debian/RHEL-based) dengan akses root/sudo
- Akses network antar node (port `6443` untuk API server, `8472/UDP` untuk flannel vxlan, `2379-2380` untuk etcd antar master)
- `curl` sudah terpasang
- Koneksi internet ke `get.k3s.io` dan `github.com` (untuk download binary k3s)

## Cara pakai

```bash
git clone <repo-url>
cd k3s-ha-installer
chmod +x install-k3s.sh
sudo ./install-k3s.sh
```

Script akan menampilkan menu:

```
Pilih aksi:
  1) Install k3s
  2) Uninstall k3s
  3) Upgrade k3s
```

### 1) Install

Ikuti alur interaktif:

| Step | Input | Keterangan |
|---|---|---|
| 1 | Hostname baru | Kosongkan jika tidak ingin diganti |
| 2 | Mode | `1` master pertama, `2` master tambahan, `3` worker |
| 3 | Token cluster | Token bersama yang dipakai semua node untuk join |
| 4 | Server URL | Hanya untuk mode join (master tambahan/worker) |
| 5 | Node name | Default ke hostname |
| 6 | Node IP | Script menampilkan daftar IP terdeteksi |
| 7 | Flannel interface | Script menampilkan daftar interface terdeteksi |
| 8 | Versi k3s | Kosongkan untuk versi stable terbaru |
| 9 | TLS SAN | Hanya untuk mode master, daftar IP semua master |
| 10 | Sysctl tuning | Opsional, terapkan `inotify`/`file-max` tuning |

**Urutan instalasi yang disarankan:**

```
1. Master pertama (cluster-init)
2. Master tambahan #2, #3 (join server, satu per satu)
3. Semua worker (join agent)
```

### 2) Uninstall

- Otomatis deteksi apakah node ini server (master) atau agent (worker)
- Wajib ketik `UNINSTALL` (huruf besar) untuk konfirmasi — tidak bisa dibatalkan setelah dieksekusi
- Opsional membersihkan folder `/etc/rancher/k3s`

> ⚠️ Uninstall di node master akan menghapus etcd member node tersebut. Untuk decommission cluster penuh, uninstall worker dulu → master tambahan → master pertama terakhir.

### 3) Upgrade

- Otomatis deteksi versi k3s saat ini dan tipe node
- Minta versi tujuan (contoh: `v1.35.2+k3s1`)
- **Kebijakan skip-version**: Kubernetes/k3s hanya resmi mendukung upgrade **1 minor version** setiap kali. Kalau target loncat >1 minor version, script akan memperingatkan dan meminta konfirmasi eksplisit (`PAKSA`) untuk tetap lanjut
- Menawarkan cordon & drain node sebelum upgrade (disarankan, terutama untuk worker)
- Menjalankan upgrade lewat installer resmi `get.k3s.io` dengan `INSTALL_K3S_VERSION` sesuai target
- Menawarkan uncordon setelah selesai

**Urutan upgrade yang disarankan (untuk cluster HA):**

```
1. Master tambahan #2, #3 (satu per satu)
2. Master pertama (terakhir dari sisi master)
3. Semua worker
```

Kalau versi target lebih dari 1 minor version di depan versi saat ini, upgrade bertahap:

```
v1.34.x -> v1.35.x -> v1.36.x
```

## Konfigurasi default yang di-generate

Beberapa nilai berikut sudah di-hardcode di script sebagai baseline (bisa diedit langsung di `install-k3s.sh` sebelum dijalankan kalau perlu disesuaikan):

```yaml
cluster-cidr: '10.44.0.0/16'
service-cidr: '10.45.0.0/16'
disable:
  - 'traefik'
  - 'servicelb'
  - 'local-storage'
node-taint:
  - 'node-role.kubernetes.io/master=true:NoSchedule'   # hanya untuk master
kubelet-arg:
  - 'volume-stats-agg-period=1m'
  - 'eviction-max-pod-grace-period=60'
  - 'kube-reserved=cpu=200m,memory=512Mi,ephemeral-storage=1Gi'
  - 'system-reserved=cpu=200m,memory=512Mi,ephemeral-storage=1Gi'
  - 'eviction-hard=memory.available<800Mi,nodefs.available<10%,nodefs.inodesFree<5%'
  - 'eviction-soft=memory.available<1.5Gi,nodefs.available<10%,nodefs.inodesFree<10%'
  - 'eviction-soft-grace-period=memory.available=1m,nodefs.available=1m,nodefs.inodesFree=1m'
etcd-snapshot-schedule-cron: '0 */12 * * *'
etcd-snapshot-retention: 60
```

> Traefik, ServiceLB, dan local-storage sengaja di-disable — pastikan sudah punya pengganti (ingress controller, load balancer, storage class) sebelum deploy workload produksi.

## Troubleshooting

**Error `too many open files`**
Jalankan ulang script, pilih Install, dan jawab `y` pada prompt sysctl tuning. Atau terapkan manual:
```bash
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes.conf
fs.inotify.max_user_watches = 2097152
fs.inotify.max_user_instances = 8192
fs.file-max = 2097152
EOF
sudo sysctl --system
```

**Cek status cluster**
```bash
sudo k3s kubectl get nodes -o wide
```

**Ambil token cluster (dari master manapun)**
```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

## Referensi

- [k3s official docs](https://docs.k3s.io/)
- [k3s releases](https://github.com/k3s-io/k3s/releases)
- [Kubernetes version skew policy](https://kubernetes.io/releases/version-skew-policy/)

## Lisensi

Internal use — sesuaikan dengan kebijakan organisasi.
