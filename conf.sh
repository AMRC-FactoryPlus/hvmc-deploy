#!/bin/bash

set -e

echo Enter your centre wmg, ncc, namrc, mtc, nmis or amrc
read CENTRE

echo Reinstalling K3s...
/usr/local/bin/k3s-uninstall.sh
curl -sfL https://get.k3s.io | sh -s - --cluster-init --disable=traefik,local-storage --secrets-encryption --flannel-backend=wireguard

echo Configuring Sealed Secrets...
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || true
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets || true
helm install --kubeconfig=/etc/rancher/k3s/k3s.yaml -n kube-system sealed-secrets sealed-secrets/sealed-secrets || true

echo Configuring Logging...
kubectl create namespace monitoring || true
helm repo add grafana https://grafana.github.io/helm-charts || true
helm install --kubeconfig=/etc/rancher/k3s/k3s.yaml -n monitoring promtail grafana/promtail --values promtail-values.yaml || true

echo Configuring Namespace...
kubectl create namespace fplus-$CENTRE-local || true

echo Configuring Image Registry...
echo Enter the token password:
read spp
kubectl create secret docker-registry regcreds \
    --namespace fplus-$CENTRE-local \
    --docker-server=fplus.azurecr.io \
    --docker-username=fplus-$CENTRE-local \
    --docker-password=$spp

echo Configuring Service account...
kubectl create serviceaccount -n fplus-$CENTRE-local teleporter
kubectl create clusterrolebinding teleporter --clusterrole=cluster-admin --serviceaccount=fplus-$CENTRE-local:teleporter

echo Applying teleporter secret...
kubectl apply -f ./teleporter-secrets.plain.yaml
echo Applying teleporter CronJob...
kubectl apply -f ./teleporter-cronjob.yaml
