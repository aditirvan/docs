# Kubernetes RBAC - Full Access ServiceAccount

Manifest RBAC untuk membuat ServiceAccount dengan akses penuh (setara `cluster-admin`) di dalam cluster Kubernetes. Berisi `ServiceAccount`, `ClusterRole`, `ClusterRoleBinding`, dan `Secret` untuk token autentikasi.

## Isi Manifest

File `rbac-full-access.yaml` berisi 4 resource:

| Resource | Nama | Keterangan |
|---|---|---|
| ServiceAccount | `full-access-sa` | Identitas yang akan diberi akses |
| ClusterRole | `full-access-cluster-role` | Mengizinkan semua verb pada semua resource & API group (`*`) |
| ClusterRoleBinding | `full-access-cluster-role-binding` | Menghubungkan ServiceAccount ke ClusterRole |
| Secret | `full-access-sa-token` | Token statis untuk autentikasi ServiceAccount (K8s 1.24+) |

Namespace default: `kube-system` (bisa diganti sesuai kebutuhan).

## Cara Pakai

### 1. Apply manifest

```bash
kubectl apply -f rbac-full-access.yaml
```

### 2. Ambil token

```bash
kubectl get secret full-access-sa-token -n kube-system -o jsonpath='{.data.token}' | base64 -d
```

### 3. (Opsional) Buat kubeconfig terpisah

```bash
TOKEN=$(kubectl get secret full-access-sa-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_CERT=$(kubectl get secret full-access-sa-token -n kube-system -o jsonpath='{.data.ca\.crt}')

kubectl config set-cluster ${CLUSTER_NAME} \
  --server=${SERVER} \
  --certificate-authority=<(echo ${CA_CERT} | base64 -d) \
  --embed-certs=true \
  --kubeconfig=full-access-kubeconfig.yaml

kubectl config set-credentials full-access-sa \
  --token=${TOKEN} \
  --kubeconfig=full-access-kubeconfig.yaml

kubectl config set-context full-access-context \
  --cluster=${CLUSTER_NAME} \
  --user=full-access-sa \
  --kubeconfig=full-access-kubeconfig.yaml

kubectl config use-context full-access-context --kubeconfig=full-access-kubeconfig.yaml
```

## ⚠️ Peringatan

ClusterRole ini memberikan **akses penuh tanpa batas** (`*/*/*`) ke seluruh cluster — setara akun root. Gunakan hanya untuk:

- Automation/CI-CD yang benar-benar memerlukan akses penuh
- Environment testing/development yang terisolasi
- Situasi darurat/break-glass access

**Jangan** gunakan untuk operasional harian tim atau aplikasi produksi. Pertimbangkan `Role` + `RoleBinding` berskala namespace, atau ClusterRole dengan rules yang lebih spesifik, untuk mengikuti prinsip *least privilege*.

## Struktur Folder

```
k8s-rbac-full-access/
├── README.md
└── rbac-full-access.yaml
```

## Requirement

- Kubernetes v1.24 ke atas (untuk Secret bertipe `kubernetes.io/service-account-token` yang di-bind manual)
- Akses `kubectl` dengan hak `cluster-admin` untuk apply manifest ini

## Lisensi

Bebas digunakan dan dimodifikasi sesuai kebutuhan.
