#!/bin/bash

set -e

echo Enter your centre wmg, ncc, namrc, mtc, nmis or amrc
read CENTRE

echo Applying teleporter secret...
kubectl apply -f ./teleporter-secrets.plain.yaml

echo Manually running teleporter...
app="teleporter.amrc-factoryplus.shef.ac.uk"
manager="app.kubernetes.io/managed-by"
SOURCE_KUBECONFIG=cl1$CENTRE.kc
TARGET_KUBECONFIG=/etc/rancher/k3s/k3s.yaml
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
echo ">>> Target cluster: $(kc_server "$TARGET_KUBECONFIG")"

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
| maybe kc_run ""$TARGET_KUBECONFIG"" apply -f -

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