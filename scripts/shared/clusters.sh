#!/usr/bin/env bash

## Kubernetes version mapping, as supported by kind ##
# See the release notes of the kind version in use
DEFAULT_K8S_VERSION=1.20
declare -A kind_k8s_versions
kind_k8s_versions[1.17]=1.17.17@sha256:66f1d0d91a88b8a001811e2f1054af60eef3b669a9a74f9b6db871f2f1eeed00
kind_k8s_versions[1.18]=1.18.19@sha256:7af1492e19b3192a79f606e43c35fb741e520d195f96399284515f077b3b622c
kind_k8s_versions[1.19]=1.19.11@sha256:07db187ae84b4b7de440a73886f008cf903fcf5764ba8106a9fd5243d6f32729
kind_k8s_versions[1.20]=1.20.7@sha256:cbeaf907fc78ac97ce7b625e4bf0de16e3ea725daf6b04f930bd14c67c671ff9
kind_k8s_versions[1.21]=1.21.1@sha256:69860bda5563ac81e3c0057d654b5253219618a22ec3a346306239bba8cfa1a6
kind_k8s_versions[1.22]=1.22.0@sha256:b8bda84bb3a190e6e028b1760d277454a72267a5454b57db34437c34a588d047
kind_k8s_versions[1.23]=1.23.0@sha256:49824ab1727c04e56a21a5d8372a402fcd32ea51ac96a2706a12af38934f81ac

## Process command line flags ##

source ${SCRIPTS_DIR}/lib/shflags
DEFINE_string 'k8s_version' "${DEFAULT_K8S_VERSION}" 'Version of K8s to use'
DEFINE_string 'olm_version' 'v0.18.3' 'Version of OLM to use'
DEFINE_boolean 'olm' false 'Deploy OLM'
DEFINE_boolean 'prometheus' false 'Deploy Prometheus'
DEFINE_boolean 'globalnet' false "Deploy with operlapping CIDRs (set to 'true' to enable)"
DEFINE_boolean 'registry_inmemory' true "Run local registry in memory to speed up the image loading."
DEFINE_string 'settings' '' "Settings YAML file to customize cluster deployments"
DEFINE_string 'timeout' '5m' "Timeout flag to pass to kubectl when waiting (e.g. 30s)"
FLAGS "$@" || exit $?
eval set -- "${FLAGS_ARGV}"

k8s_version="${FLAGS_k8s_version}"
olm_version="${FLAGS_olm_version}"
[[ -z "${k8s_version}" ]] && k8s_version="${DEFAULT_K8S_VERSION}"
[[ -n "${kind_k8s_versions[$k8s_version]}" ]] && k8s_version="${kind_k8s_versions[$k8s_version]}"
[[ "${FLAGS_olm}" = "${FLAGS_TRUE}" ]] && olm=true || olm=false
[[ "${FLAGS_prometheus}" = "${FLAGS_TRUE}" ]] && prometheus=true || prometheus=false
[[ "${FLAGS_globalnet}" = "${FLAGS_TRUE}" ]] && globalnet=true || globalnet=false
[[ "${FLAGS_registry_inmemory}" = "${FLAGS_TRUE}" ]] && registry_inmemory=true || registry_inmemory=false
settings="${FLAGS_settings}"
timeout="${FLAGS_timeout}"

echo "Running with: k8s_version=${k8s_version}, olm_version=${olm_version}, olm=${olm}, globalnet=${globalnet}, prometheus=${prometheus}, registry_inmemory=${registry_inmemory}, settings=${settings}, timeout=${timeout}"

set -em

source ${SCRIPTS_DIR}/lib/debug_functions
source ${SCRIPTS_DIR}/lib/utils

### Functions ###

function generate_cluster_yaml() {
    local pod_cidr="${cluster_CIDRs[${cluster}]}"
    local service_cidr="${service_CIDRs[${cluster}]}"
    local dns_domain="${cluster}.local"
    local disable_cni="false"
    [[ -z "${cluster_cni[$cluster]}" ]] || disable_cni="true"

    local nodes
    for node in ${cluster_nodes[${cluster}]}; do nodes="${nodes}"$'\n'"- role: $node"; done

    render_template ${RESOURCES_DIR}/kind-cluster-config.yaml > ${RESOURCES_DIR}/${cluster}-config.yaml
}

function kind_fixup_config() {
    local master_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${cluster}-control-plane | head -n 1)
    sed -i -- "s/server: .*/server: https:\/\/$master_ip:6443/g" $KUBECONFIG
    sed -i -- "s/user: kind-.*/user: ${cluster}/g" $KUBECONFIG
    sed -i -- "s/name: kind-.*/name: ${cluster}/g" $KUBECONFIG
    sed -i -- "s/cluster: kind-.*/cluster: ${cluster}/g" $KUBECONFIG
    sed -i -- "s/current-context: .*/current-context: ${cluster}/g" $KUBECONFIG
    chmod a+r $KUBECONFIG
}

function create_kind_cluster() {
    export KUBECONFIG=${KUBECONFIGS_DIR}/kind-config-${cluster}
    rm -f "$KUBECONFIG"

    if kind get clusters | grep -q "^${cluster}$"; then
        echo "KIND cluster already exists, skipping its creation..."
        kind export kubeconfig --name=${cluster}
        kind_fixup_config
        return
    fi

    echo "Creating KIND cluster..."
    if [[ "${cluster_cni[$cluster]}" == "ovn" ]]; then
        deploy_kind_ovn
        return
    fi

    generate_cluster_yaml
    local image_flag=''
    if [[ -n ${k8s_version} ]]; then
        image_flag="--image=kindest/node:v${k8s_version}"
    fi

    kind version
    cat ${RESOURCES_DIR}/${cluster}-config.yaml
    kind create cluster $image_flag --name=${cluster} --config=${RESOURCES_DIR}/${cluster}-config.yaml
    kind_fixup_config

    ( deploy_cluster_capabilities; ) &
    if ! wait $! ; then
        echo "Failed to deploy cluster capabilities, removing the cluster"
        kubectl cluster-info dump 1>&2
        kind delete cluster --name=${cluster}
        return 1
    fi
}

function deploy_cni() {
    [[ -n "${cluster_cni[$cluster]}" ]] || return 0

    eval "deploy_${cluster_cni[$cluster]}_cni"
}

function deploy_weave_cni(){
    echo "Applying weave network..."
    curl -sL "https://cloud.weave.works/k8s/net?k8s-version=v$k8s_version&env.IPALLOC_RANGE=${cluster_CIDRs[${cluster}]}" | sed 's!ghcr.io/weaveworks/launcher!weaveworks!' | kubectl apply -f -
    echo "Waiting for weave-net pods to be ready..."
    kubectl wait --for=condition=Ready pods -l name=weave-net -n kube-system --timeout="${timeout}"
    echo "Waiting for core-dns deployment to be ready..."
    kubectl -n kube-system rollout status deploy/coredns --timeout="${timeout}"
}

function deploy_ovn_cni(){
    echo "OVN CNI deployed."
}

function deploy_kind_ovn(){
    local OVN_SRC_IMAGE="quay.io/vthapar/ovn-daemonset-f:latest"
    export K8s_VERSION="${k8s_version}"
    export NET_CIDR_IPV4="${cluster_CIDRs[${cluster}]}"
    export SVC_CIDR_IPV4="${service_CIDRs[${cluster}]}"
    export KIND_CLUSTER_NAME="${cluster}"

    export OVN_IMAGE="localhost:5000/ovn-daemonset-f:latest"
    export REGISTRY_IP="kind-registry"
    docker pull "${OVN_SRC_IMAGE}"
    docker tag "${OVN_SRC_IMAGE}" "${OVN_IMAGE}"
    docker push "${OVN_IMAGE}"
    sed -i 's/^kind load/#kind load/g' $OVN_DIR/contrib/kind.sh

    (  cd ${OVN_DIR}/contrib; ./kind.sh; ) &
    if ! wait $! ; then
        echo "Failed to install kind with OVN"
        kind delete cluster --name=${cluster}
        return 1
    fi

    ( deploy_cluster_capabilities; ) &
    if ! wait $! ; then
        echo "Failed to deploy cluster capabilities, removing the cluster"
        kind delete cluster --name=${cluster}
        return 1
    fi
}

function run_local_registry() {
    # Run a local registry to avoid loading images manually to kind
    if registry_running; then
        echo "Local registry $KIND_REGISTRY already running."
    else
        echo "Deploying local registry $KIND_REGISTRY to serve images centrally."
        local volume_flag
        if [[ $registry_inmemory = true ]]; then
            volume_flag="-v /dev/shm/${KIND_REGISTRY}:/var/lib/registry"
            selinuxenabled && volume_flag="${volume_flag}:z" 2>/dev/null
        fi
        docker run -d $volume_flag -p 127.0.0.1:5000:5000 --restart=always --name $KIND_REGISTRY registry:2
        docker network connect kind $KIND_REGISTRY || true
    fi
}

function deploy_olm() {
    echo "Applying OLM CRDs..."
    kubectl apply -f "https://github.com/operator-framework/operator-lifecycle-manager/releases/download/${olm_version}/crds.yaml" --validate=false
    kubectl wait --for=condition=Established -f "https://github.com/operator-framework/operator-lifecycle-manager/releases/download/${olm_version}/crds.yaml"
    echo "Applying OLM resources..."
    kubectl apply -f "https://github.com/operator-framework/operator-lifecycle-manager/releases/download/${olm_version}/olm.yaml"

    echo "Waiting for olm-operator deployment to be ready..."
    kubectl rollout status deployment/olm-operator --namespace=olm --timeout="${timeout}"
    echo "Waiting for catalog-operator deployment to be ready..."
    kubectl rollout status deployment/catalog-operator --namespace=olm --timeout="${timeout}"
    echo "Waiting for packageserver deployment to be ready..."
    kubectl rollout status deployment/packageserver --namespace=olm --timeout="${timeout}"
}

function deploy_prometheus() {
    echo "Deploying Prometheus..."
    # TODO Install in a separate namespace
    kubectl create ns submariner-operator
    # Bundle from prometheus-operator, namespace changed to submariner-operator
    kubectl apply -f ${SCRIPTS_DIR}/resources/prometheus/bundle.yaml
    kubectl apply -f ${SCRIPTS_DIR}/resources/prometheus/serviceaccount.yaml
    kubectl apply -f ${SCRIPTS_DIR}/resources/prometheus/clusterrole.yaml
    kubectl apply -f ${SCRIPTS_DIR}/resources/prometheus/clusterrolebinding.yaml
    kubectl apply -f ${SCRIPTS_DIR}/resources/prometheus/prometheus.yaml
}

function deploy_cluster_capabilities() {
    deploy_cni
    [[ $olm != "true" ]] || deploy_olm
    [[ $prometheus != "true" ]] || deploy_prometheus
}

function warn_inotify() {
    if [[ "$(cat /proc/sys/fs/inotify/max_user_instances)" -lt 512 ]]; then
        echo "Please increase your inotify settings (currently $(cat /proc/sys/fs/inotify/max_user_watches) and $(cat /proc/sys/fs/inotify/max_user_instances)):"
        echo sudo sysctl fs.inotify.max_user_watches=524288
        echo sudo sysctl fs.inotify.max_user_instances=512
        echo 'See https://kind.sigs.k8s.io/docs/user/known-issues/#pod-errors-due-to-too-many-open-files'
    fi
}

### Main ###

rm -rf ${KUBECONFIGS_DIR}
mkdir -p ${KUBECONFIGS_DIR}

load_settings
run_local_registry
declare_cidrs

# Run in subshell to check response, otherwise `set -e` is not honored
( run_all_clusters with_retries 3 create_kind_cluster; ) &
if ! wait $!; then
    warn_inotify
    exit 1
fi

print_clusters_message
