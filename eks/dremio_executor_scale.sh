#!/bin/bash
#set -x


#### Validate environment
if ! [ -x "$(command -v kubectl)" ]; then
  echo "kubectl is not installed"
  exit 1
fi

if ! [ -x "$(command -v jq)" ]; then
  echo "jq is not installed"
  exit 1
fi


# Configuration
scaleup_wait=30
graceful_shutdown_wait=10
scaledown_wait=30

DREMIO_NS=dremio
DREMIO_URL="http://localhost:9049"
DREMIO_USER=mikhail
DREMIO_PWD=dremio123
DREMIO_STATEFULSET=dremio-executor
REQUESTED_DREMIO_EXECUTOR_REPLICAS=$1
CURRENT_DREMIO_EXECUTOR_REPLICAS=$(kubectl get statefulset ${DREMIO_STATEFULSET} -n ${DREMIO_NS} -o json | jq -Mr '.status.replicas')


####################################################
dremio_api_login() {
  HTTP_REQ_BODY="{\"userName\": \"${DREMIO_USER}\", \"password\": \"${DREMIO_PWD}\"}"
  HTTP_RESPONSE=$(curl -s -w "%{http_code}" --request POST --header "Content-Type: application/json" ${DREMIO_URL}/apiv2/login -d "${HTTP_REQ_BODY}")
  HTTP_RESPONSE_CODE=$(echo $HTTP_RESPONSE | awk 'BEGIN {FS="}"} {print $NF}')
  if [ "$HTTP_RESPONSE_CODE" = "200" ]; then
    DREMIO_TOKEN=_dremio$(echo ${HTTP_RESPONSE::${#HTTP_RESPONSE}-3} | jq -r '.token')
  else
    echo -e "\nCannot login to Dremio: Error Code ${HTTP_RESPONSE_CODE}"
    exit 1
  fi
}

blacklist_replicas() {
  NUMBER_OF_REPLICAS_TO_DRAIN=$1
  if test "$1" -ne 0; then
    BLACKLIST_DREMIO_NODE_LIST="["
    for i in $(seq $(($CURRENT_DREMIO_EXECUTOR_REPLICAS - $NUMBER_OF_REPLICAS_TO_DRAIN)) $(($CURRENT_DREMIO_EXECUTOR_REPLICAS - 1))); do 
      DREMIO_NODE_NAME="${DREMIO_STATEFULSET}-${i}.${DREMIO_NS}-cluster-pod.${DREMIO_NS}.svc.cluster.local"
      BLACKLIST_DREMIO_NODE_LIST="${BLACKLIST_DREMIO_NODE_LIST}\"$DREMIO_NODE_NAME\","
    done
    BLACKLIST_DREMIO_NODE_LIST=$(echo $BLACKLIST_DREMIO_NODE_LIST | sed 's/.$//')
    BLACKLIST_DREMIO_NODE_LIST="$BLACKLIST_DREMIO_NODE_LIST]"
  else
    # Whitelist all nodes
    BLACKLIST_DREMIO_NODE_LIST="[]"
  fi

  HTTP_RESPONSECODE=$(curl -s -w "%{http_code}" -o /dev/null --request POST --header "authorization: ${DREMIO_TOKEN}" --header "Content-Type: application/json" ${DREMIO_URL}/api/v3/nodeCollections/blacklist -d ${BLACKLIST_DREMIO_NODE_LIST})

  if [ $HTTP_RESPONSECODE != "200" ]; then
    echo -e "\nUnexpected error during blacklisting the following Dremio Nodes ${BLACKLIST_DREMIO_NODE_LIST}. HTTP Error code: ${HTTP_RESPONSECODE}"
    exit 1
  fi
}


####################################################
scaleup_dremio_executor_replicas() {
  kubectl scale --replicas=${REQUESTED_DREMIO_EXECUTOR_REPLICAS} statefulset/${DREMIO_STATEFULSET} -n ${DREMIO_NS} 
  sleep $scaleup_wait
  ACTUAL_DREMIO_EXECUTOR_REPLICAS=$(kubectl get statefulset ${DREMIO_STATEFULSET} -n ${DREMIO_NS} -o json | jq -Mr '.status.replicas')
  # White list all nodes
  blacklist_replicas 0
  echo "Stateful set ${DREMIO_STATEFULSET} has been scaled up to $ACTUAL_DREMIO_EXECUTOR_REPLICAS replicas"
}


####################################################
scaledown_dremio_executor_replicas() {
  blacklist_replicas $((${CURRENT_DREMIO_EXECUTOR_REPLICAS} - ${REQUESTED_DREMIO_EXECUTOR_REPLICAS}))
  sleep $graceful_shutdown_wait
  kubectl scale --replicas=${REQUESTED_DREMIO_EXECUTOR_REPLICAS} statefulset/${DREMIO_STATEFULSET} -n ${DREMIO_NS} 
  sleep $scaledown_wait
  ACTUAL_DREMIO_EXECUTOR_REPLICAS=$(kubectl get statefulset ${DREMIO_STATEFULSET} -n ${DREMIO_NS} -o json | jq -Mr '.status.replicas')
  echo "Stateful set ${DREMIO_STATEFULSET} has been scaled down to $ACTUAL_DREMIO_EXECUTOR_REPLICAS replicas"
}


# Validate parameters
if test "$#" -ne 1; then
  echo "Pleas supply only one argument - desired number of replicas for ${DREMIO_STATEFULSET} stateful set as follows:"
  echo "$0 desired_number_of_replicas"
  exit 1
fi

dremio_api_login

# Determine action - scaling up or down
if [ "$REQUESTED_DREMIO_EXECUTOR_REPLICAS" -eq "$CURRENT_DREMIO_EXECUTOR_REPLICAS" ]; then
  echo "Nothing to do. Requested number of ${DREMIO_STATEFULSET} replicas is the same to the current number of replicas."
  exit 0
elif [ "$REQUESTED_DREMIO_EXECUTOR_REPLICAS" -gt "$CURRENT_DREMIO_EXECUTOR_REPLICAS" ]; then
  echo "scaling up ${DREMIO_STATEFULSET} from $CURRENT_DREMIO_EXECUTOR_REPLICAS executor replicas to $REQUESTED_DREMIO_EXECUTOR_REPLICAS"
  scaleup_dremio_executor_replicas
elif [ "$REQUESTED_DREMIO_EXECUTOR_REPLICAS" -lt "$CURRENT_DREMIO_EXECUTOR_REPLICAS" ]; then
  echo "scaling down ${DREMIO_STATEFULSET} from $CURRENT_DREMIO_EXECUTOR_REPLICAS executor replicas to $REQUESTED_DREMIO_EXECUTOR_REPLICAS"
  scaledown_dremio_executor_replicas
fi


exit 0

