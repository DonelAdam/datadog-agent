#!/usr/bin/env bash

printf '=%.0s' {0..79} ; echo
set -ex

cd "$(dirname $0)"
ssh-keygen -b 4096 -t rsa -C "datadog" -N "" -f "id_rsa"
SSH_RSA=$(cat id_rsa.pub)

case "$(uname)" in
    Linux)  fcct="fcct-$(uname -m)-unknown-linux-gnu";;
    Darwin) fcct="fcct-$(uname -m)-apple-darwin";;
esac
curl -LOC - "https://github.com/coreos/fcct/releases/download/v0.6.0/${fcct}"
curl -LO    "https://github.com/coreos/fcct/releases/download/v0.6.0/${fcct}.asc"
curl https://getfedora.org/static/fedora.gpg | gpg --import
gpg --verify "${fcct}.asc" "$fcct"
chmod +x "$fcct"

./$fcct --pretty --strict <<EOF | tee ignition.json
variant: fcos
version: 1.1.0
passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - "${SSH_RSA}"
systemd:
  units:
    - name: zincati.service
      mask: true
    - name: setup-pupernetes.service
      enabled: true
      contents: |
        [Unit]
        Description=Setup pupernetes
        Wants=network-online.target
        After=network-online.target

        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/setup-pupernetes
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
    - name: install-pupernetes-dependencies.service
      enabled: true
      contents: |
        [Unit]
        Description=Install pupernetes dependencies
        Wants=network-online.target
        After=network-online.target

        [Service]
        Type=oneshot
        ExecStart=/usr/bin/rpm-ostree install --idempotent --reboot unzip
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
    - name: pupernetes.service
      enabled: true
      contents: |
        [Unit]
        Description=Run pupernetes
        Requires=setup-pupernetes.service install-pupernetes-dependencies.service docker.service
        After=setup-pupernetes.service install-pupernetes-dependencies.service docker.service

        [Service]
        Environment=SUDO_USER=core
        WorkingDirectory=/home/core
        ExecStartPre=/usr/bin/mkdir -p /opt/bin
        ExecStartPre=/usr/sbin/setenforce 0
        ExecStartPre=-/usr/bin/rpm-ostree usroverlay
        ExecStart=/usr/local/bin/pupernetes daemon run /opt/sandbox --kubectl-link /opt/bin/kubectl -v 5 --hyperkube-version 1.10.1 --run-timeout 6h
        Restart=on-failure
        RestartSec=5
        Type=notify
        TimeoutStartSec=600
        TimeoutStopSec=120

        [Install]
        WantedBy=multi-user.target
    - name: docker.service
      dropins:
        - name: cgroupfs.conf
          contents: |
            [Service]
            ExecStart=
            ExecStart=/usr/bin/dockerd \
                      --host=fd:// \
                      $OPTIONS
    - name: p8s-kubelet.service
      dropins:
        - name: cgroupfs.conf
          contents: |
            [Service]
            ExecStart=
            ExecStart=/opt/sandbox/bin/hyperkube kubelet \
                    --v=4 \
                    --allow-privileged \
                    --fail-swap-on=false \
                    --hairpin-mode=none \
                    --pod-manifest-path=/opt/sandbox/manifest-static-pod \
                    --hostname-override=ip-172-29-137-195 \
                    --root-dir=/var/lib/p8s-kubelet \
                    --healthz-port=10248 \
                    --kubeconfig=/opt/sandbox/manifest-config/kubeconfig-insecure.yaml \
                    --resolv-conf=/opt/sandbox/net.d/resolv-conf \
                    --cluster-dns=192.168.254.2 \
                    --cluster-domain=cluster.local \
                    --cert-dir=/opt/sandbox/secrets \
                    --client-ca-file=/opt/sandbox/secrets/kubernetes.issuing_ca \
                    --tls-cert-file=/opt/sandbox/secrets/kubernetes.certificate \
                    --tls-private-key-file=/opt/sandbox/secrets/kubernetes.private_key \
                    --read-only-port=0 \
                    --anonymous-auth=false \
                    --authentication-token-webhook \
                    --authentication-token-webhook-cache-ttl=5s \
                    --authorization-mode=Webhook  \
                    --cadvisor-port=0 \
                    --cgroups-per-qos=true \
                    --cgroup-driver=cgroupfs \
                    --max-pods=60 \
                    --node-ip=172.29.137.195 \
                    --node-labels=p8s=mononode \
                    --application-metrics-count-limit=50 \
                    --network-plugin=cni \
                    --cni-conf-dir=/opt/sandbox/net.d \
                    --cni-bin-dir=/opt/sandbox/bin \
                    --container-runtime=docker \
                    --runtime-request-timeout=15m \
                    --container-runtime-endpoint=unix:///var/run/dockershim.sock \
                    --feature-gates=PodShareProcessNamespace=true
    - name: terminate.service
      contents: |
        [Unit]
        Description=Trigger a poweroff

        [Service]
        ExecStart=/bin/systemctl poweroff
        Restart=no
    - name: terminate.timer
      enabled: true
      contents: |
        [Timer]
        OnBootSec=7200

        [Install]
        WantedBy=multi-user.target
storage:
  files:
    - path: /usr/local/bin/setup-pupernetes
      mode: 0500
      contents:
        source: "data:,%23%21%2Fbin%2Fbash%20-ex%0Acurl%20-Lf%20--retry%207%20--retry-connrefused%20https%3A%2F%2Fgithub.com%2FDataDog%2Fpupernetes%2Freleases%2Fdownload%2Fv0.11.0%2Fpupernetes%20-o%20%2Fusr%2Flocal%2Fbin%2Fpupernetes%0Asha512sum%20-c%20%2Fusr%2Flocal%2Fshare%2Fpupernetes.sha512sum%0Achmod%20%2Bx%20%2Fusr%2Flocal%2Fbin%2Fpupernetes%0A"
    - path: /usr/local/share/pupernetes.sha512sum
      mode: 0400
      contents:
        source: "data:,fcbf42316b9fbfbf6966b2f010f1bbc5006f7c882fc856d36b5e9f67a323d6b02361a45b88a4b4f7c64ac733078d9fd7d0cf72ef1229697f191b740c9fc95e61%20%2Fusr%2Flocal%2Fbin%2Fpupernetes%0A"
EOF
