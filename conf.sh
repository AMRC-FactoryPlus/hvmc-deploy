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

#echo Applying teleporter CronJob...
#kubectl apply -f ./teleporter-cronjob.yaml
#

echo Manually running teleporter...
app="teleporter.amrc-factoryplus.shef.ac.uk"
manager="app.kubernetes.io/managed-by"
SOURCE_KUBECONFIG=cl1$CENTRE.kc
OBJECT_TYPES=cronjobs,sealedsecrets

dryrun="NO"

while getopts "n" opt
do
    case "$opt" in
    n)  dryrun="YES"
        ;;
    esac
done

txn="$(uuidgen)"
echo ">>> Transaction ID for this run: $txn"
echo ">>> Teleporting namespace fplus-$CENTRE-local"

kc_run () {
    local kc="$1"
    local cmd="$2"
    shift 2

    kubectl "$cmd" ${kc:+--kubeconfig="$kc"} --insecure-skip-tls-verify "$@"
}

kc_server () {
    local kc="$1"
    kc_run "$kc" config view -o json \
    | jq -r '
        ."current-context" as $curr
        | (.contexts[] | select(.name == $curr) | .context.cluster) as $clus
        | .clusters[] | select(.name == $clus) | .cluster.server'
}

maybe () {
    if [ "$dryrun" = "YES" ]
    then
        echo "- $*"
        cat
    else
        echo "+ $*"
        "$@"
    fi
}

echo ">>> Source cluster: $(kc_server "$SOURCE_KUBECONFIG")"
echo ">>> Target cluster: $(kc_server "fplus-$CENTRE-local")"

echo ">>> Fetching resources from source cluster..."
kc_run "$SOURCE_KUBECONFIG" get \
    -o json \
    -n "fplus-$CENTRE-local" \
    "$OBJECT_TYPES" \
| jq --arg app "$app" --arg manager "$manager" --arg txn "$txn" '
    .items[] |= (
        (   .metadata.annotations[$app + "/on-teleport"] // "null"
            | fromjson
            | if type == "object" then . else {} end
        ) as $rewrite
        | del(.status)
        | .metadata |= (
            del(.annotations)
            | del(.creationTimestamp)
            | del(.generation)
            | del(.resourceVersion)
            | del(.uid)
            | .labels |= (
                .[$manager] = $app
                | .[$app + "/txn"] = $txn))
        | . * $rewrite )' \
| maybe kc_run "fplus-$CENTRE-local" apply -f -

if [ "$dryrun" != "YES" ]
then
    echo ">>> Deleting stale resources from target cluster..."
    kubectl delete \
        -n "fplus-$CENTRE-local" \
        -l "$manager==$app,$app/txn!=$txn" \
        "$OBJECT_TYPES"
else
    echo ">>> Dry run, not deleting stale resources."
fi