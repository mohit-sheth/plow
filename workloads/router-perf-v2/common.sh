ENGINE=${ENGINE:-podman}
INFRA_TEMPLATE=http-perf.yml.tmpl
INFRA_CONFIG=http-perf.yml
KUBE_BURNER_IMAGE=quay.io/cloud-bulldozer/kube-burner:latest
URL_PATH=${URL_PATH:-"/1024.html"}
TERMINATIONS=${TERMINATIONS:-"http edge passthrough reencrypt mix"}
KEEPALIVE_REQUESTS=${KEEPALIVE_REQUESTS:-"0 1 50"}
SAMPLES=${SAMPLES:-2}
QUIET_PERIOD=${QUIET_PERIOD:-60s}
THROUGHPUT_TOLERANCE=${THROUGHPUT_TOLERANCE:-5}
LATENCY_TOLERANCE=${LATENCY_TOLERANCE:-5}
PREFIX=${PREFIX:-$(oc get clusterversion version -o jsonpath="{.status.desired.version}")}
LARGE_SCALE_THRESHOLD=${LARGE_SCALE_THRESHOLD:-24}


export TLS_REUSE=${TLS_REUSE:-true}
export UUID=$(uuidgen)
export RUNTIME=${RUNTIME:-60}
export ES_SERVER=${ES_SERVER:-https://search-perfscale-dev-chmf5l4sh66lvxbnadi4bznl3a.us-west-2.es.amazonaws.com:443}
export ES_INDEX=${ES_INDEX:-router-test-results}
export HOST_NETWORK=${HOST_NETWORK:-true}
export KUBECONFIG=${KUBECONFIG:-~/.kube/config}
export NODE_SELECTOR=${NODE_SELECTOR:-'{node-role.kubernetes.io/workload: }'}
export NUMBER_OF_ROUTERS=${NUMBER_OF_ROUTERS:-2}
export CERBERUS_URL=${CERBERUS_URL}
export SERVICE_TYPE=${SERVICE_TYPE:-NodePort}

log(){
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") ${@}\033[0m"
}

get_scenario(){
  # We consider a large scale scenario any cluster with more than the given threshold
  if [[ $(oc get node -l node-role.kubernetes.io/worker --no-headers | grep -cw Ready) -ge ${LARGE_SCALE_THRESHOLD} ]]; then
    log "Large scale scenario detected: #workers >= ${LARGE_SCALE_THRESHOLD}"
    export NUMBER_OF_ROUTES=${LARGE_SCALE_ROUTES:-500}
    CLIENTS=${LARGE_SCALE_CLIENTS:-"1 20 80"}
    CLIENTS_MIX=${LARGE_SCALE_CLIENTS_MIX:-"1 10 20"}
    BASELINE_UUID=${LARGE_SCALE_BASELINE_UUID}
    BASELINE_PREFIX=${LARGE_SCALE_BASELINE_PREFIX:-baseline}
  else
    log "Small scale scenario detected: #workers < ${LARGE_SCALE_THRESHOLD}"
    export NUMBER_OF_ROUTES=${SMALL_SCALE_ROUTES:-100}
    CLIENTS=${SMALL_SCALE_CLIENTS:-"1 40 200"}
    CLIENTS_MIX=${SMALL_SCALE_CLIENTS_MIX:-"1 20 80"}
    BASELINE_UUID=${SMALL_SCALE_BASELINE_UUID}
    BASELINE_PREFIX=${SMALL_SCALE_BASELINE_PREFIX:-baseline}
  fi
}

deploy_infra(){
  log "Deploying benchmark infrastructure"
  envsubst < ${INFRA_TEMPLATE} > ${INFRA_CONFIG}
  ${ENGINE} run --rm -v $(pwd)/templates:/templates:z -v ${KUBECONFIG}:/root/.kube/config:z -v $(pwd)/${INFRA_CONFIG}:/http-perf.yml:z ${KUBE_BURNER_IMAGE} init -c http-perf.yml --uuid=${UUID}
  oc create configmap -n http-scale-client workload --from-file=workload.py
  log "Adding workload.py to the client pod"
  oc set volumes -n http-scale-client deploy/http-scale-client --type=configmap --mount-path=/workload --configmap-name=workload --add
  oc rollout status -n http-scale-client deploy/http-scale-client
}

tune_liveness_probe(){
  log "Disabling cluster version and ingress operators"
  oc scale --replicas=0 -n openshift-cluster-version deploy/cluster-version-operator
  oc scale --replicas=0 -n openshift-ingress-operator deploy/ingress-operator
  log "Increasing ingress controller liveness probe period to $((RUNTIME * 2))s"
  oc set probe -n openshift-ingress --liveness --period-seconds=$((RUNTIME * 2)) deploy/router-default
  log "Scaling number of routers to ${NUMBER_OF_ROUTERS}"
  oc scale --replicas=${NUMBER_OF_ROUTERS} -n openshift-ingress deploy/router-default
  oc rollout status -n openshift-ingress deploy/router-default
}

tune_workload_node(){
  TUNED_SELECTOR=$(echo ${NODE_SELECTOR} | tr -d {:})
  log "${1} tuned profile for node labeled with ${TUNED_SELECTOR}"
  sed "s#TUNED_SELECTOR#${TUNED_SELECTOR}#g" tuned-profile.yml | oc ${1} -f -
}

run_mb(){
  if [[ ${termination} == "mix" ]]; then
    gen_mb_mix_config
  else
    gen_mb_config
  fi
  log "Copying mb config http-scale-${termination}.json to pod ${client_pod}"
  oc cp -n http-scale-client http-scale-${termination}.json ${client_pod}:/tmp/http-scale-${termination}.json
  for sample in $(seq ${SAMPLES}); do
    log "Executing sample ${sample}/${SAMPLES} using termination ${termination} with ${clients} clients and ${keepalive_requests} keepalive requests"
    oc exec -n http-scale-client -it ${client_pod} -- python3 /workload/workload.py --mb-config /tmp/http-scale-${termination}.json  --termination ${termination} --runtime ${RUNTIME} --output /tmp/results.csv --sample ${sample}
    log "Sleeping for ${QUIET_PERIOD} before next test"
    sleep ${QUIET_PERIOD}
  done
}

enable_ingress_operator(){
  log "Enabling cluster version and ingress operators"
  oc scale --replicas=1 -n openshift-cluster-version deploy/cluster-version-operator
  oc scale --replicas=1 -n openshift-ingress-operator deploy/ingress-operator
}

cleanup_infra(){
  log "Deleting infrastructure"
  oc delete ns -l kube-burner-uuid=${UUID} --ignore-not-found
}

gen_mb_config(){
  log "Generating config for termination ${termination} with ${clients} clients ${keepalive_requests} keep alive requests and path ${URL_PATH}"
  local first=true
  if [[ ${termination} == "http" ]]; then
    local scheme=http
    local port=80
  else
    local scheme=https
    local port=443
  fi
  (echo "["
  while read n r s p t w; do
    if [[ ${first} == "true" ]]; then
        echo "{"
        first=false
    else
        echo ",{"
    fi
    echo '"scheme": "'${scheme}'",
      "tls-session-reuse": '${TLS_REUSE}',
      "host": "'${n}'",
      "port": '${port}',
      "method": "GET",
      "path": "'${URL_PATH}'",
      "delay": {
        "min": 0,
        "max": 0
      },
      "keep-alive-requests": '${keepalive_requests}',
      "clients": '${clients}'
    }'
  done <<< $(oc get route -n http-scale-${termination} --no-headers | awk '{print $2}')
  echo "]") | python -m json.tool > http-scale-${termination}.json
}

gen_mb_mix_config(){
  log "Generating config for termination ${termination} with ${clients} clients ${keepalive_requests} keep alive requests and path ${URL_PATH}"
  local first=true
  (echo "["
  for mix_termination in http edge passthrough reencrypt; do
    if [[ ${mix_termination} == "http" ]]; then
      local scheme=http
      local port=80
    else
      local scheme=https
      local port=443
    fi
    while read n r s p t w; do
      if [[ ${first} == "true" ]]; then
          echo "{"
          first=false
      else
          echo ",{"
      fi
      echo '"scheme": "'${scheme}'",
        "tls-session-reuse": '${TLS_REUSE}',
        "host": "'${n}'",
        "port": '${port}',
        "method": "GET",
        "path": "'${URL_PATH}'",
        "delay": {
          "min": 0,
          "max": 0
        },
        "keep-alive-requests": '${keepalive_requests}',
        "clients": '${clients}'
      }'
    done <<< $(oc get route -n http-scale-${mix_termination} --no-headers | awk '{print $2}')
  done
  echo "]") | python -m json.tool > http-scale-mix.json
}
