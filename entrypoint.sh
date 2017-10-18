#!/usr/bin/env bash -exu

# TODO: accept the following as env vars or provide defaults

KUBE_ENDPOINT="apis/apps/v1beta1/namespaces/default/deployments/mydeployname/scale"
# Default to 1
KUBE_MIN_REPLICAS=1
# Default to infinity
KUBE_MAX_REPLICAS=5


CW_NAMESPACE="AWS/SQS"
CW_METRIC_NAME="ApproximateAgeOfOldestMessage"
CW_DIMENSIONS="Name=QueueName,Value=sqs_queue_name"
CW_STATISTICS="Average"
CW_PERIOD=600

# Default to 30 seconds
CW_POLL_PERIOD=60

CW_SCALE_DOWN_VALUE=300
CW_SCALE_UP_VALUE=900

# Default to 120 seconds
KUBE_SCALE_DOWN_COOLDOWN=120

# Default to 300 seconds
KUBE_SCALE_UP_COOLDOWN=300

# Default to 1
KUBE_SCALE_DOWN_COUNT=1

# Default to 1
KUBE_SCALE_UP_COUNT=1

# awscli, curl, jq

# AWS_ACCESS_KEY_ID
# AWS_SECRET_ACCESS_KEY
# AWS_DEFAULT_REGION


# Create Kubernetes scaling url
KUBE_URL="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_PORT_443_TCP_PORT}/${KUBE_ENDPOINT}"

# Set last scaling event time to be far in the past, so initial comparisons work
KUBE_LAST_SCALING=$(date --utc --iso-8601="seconds" -d "-1 year")

# Exit immediately on signal
trap 'exit 0' SIGINT SIGTERM EXIT

# Loop forever
while true
do
    # Poll Period with wait on trapped signal
    sleep "${CW_POLL_PERIOD}s" & wait $!

    # Get kubernetes service endpoint token
    KUBE_TOKEN=$(</var/run/secrets/kubernetes.io/serviceaccount/token)

    # Query kubernetes pod/deployment current replica count
    KUBE_CURRENT_REPLICAS=$(curl -sS --cacert "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" -H "Authorization: Bearer ${KUBE_TOKEN}" "${KUBE_URL}" | jq .spec.replicas)
    echo "Kube Replicas: ${KUBE_CURRENT_REPLICAS}"

    # Query aws cloudwatch metric
    CW_VALUE=$(aws cloudwatch get-metric-statistics --namespace "${CW_NAMESPACE}" --metric-name "${CW_METRIC_NAME}" --dimensions "${CW_DIMENSIONS}" --start-time $(date --utc --iso-8601="seconds" -d "-${CW_PERIOD} seconds") --end-time $(date --utc --iso-8601='seconds') --statistics "${CW_STATISTICS}" --period "${CW_PERIOD}" | jq ".Datapoints[0].${CW_STATISTICS}")
    echo "AWS CloudWatch Value: ${CW_VALUE}"

    # If cloudwatch returned no metrics then CW_VALUE will be null, so print an error
    if [[ -z "${CW_VALUE}" || "${CW_VALUE}" == "null" ]]; then
        echo "AWS CloudWatch Metric returned no datapoints. If metric exists, period may be set too low. Namespace:${CW_NAMESPACE} MetricName:${CW_METRIC_NAME} Dimensions:${CW_DIMENSIONS} Statistics:${CW_STATISTICS} Period:${CW_PERIOD}"
        continue
    fi

    # TODO: error handling
    # If the metric value is <= the scale-down value, and current replica count is > min replicas, and the last time we scaled up or down was at least the cooldown period ago
    if [[ "${CW_VALUE}" -le "${CW_SCALE_DOWN_VALUE}"  &&  "${KUBE_CURRENT_REPLICAS}" -gt "${KUBE_MIN_REPLICAS}"  &&  "${KUBE_LAST_SCALING}" < $(date --utc --iso-8601="seconds" -d "-${KUBE_SCALE_DOWN_COOLDOWN} seconds") ]]; then
        NEW_REPLICAS=$(( ${KUBE_CURRENT_REPLICAS} - ${KUBE_SCALE_DOWN_COUNT} ))
        NEW_REPLICAS=$(( ${NEW_REPLICAS} > ${KUBE_MIN_REPLICAS} ? ${NEW_REPLICAS} : ${KUBE_MIN_REPLICAS} ))
        echo "Scaling down from ${KUBE_CURRENT_REPLICAS} to ${NEW_REPLICAS}"
        PAYLOAD='[{"op":"replace","path":"/spec/replicas","value":"'${NEW_REPLICAS}'"}]'
        curl -sS --cacert "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" -H "Authorization: Bearer ${KUBE_TOKEN}" -X PATCH -H 'Content-Type: application/json-patch+json' --data "${PAYLOAD}" "${KUBE_URL}"
        KUBE_LAST_SCALING=$(date --utc --iso-8601="seconds")
    fi

    # If the metric value is >= the scale-up value, and current replica count is < max replicas, and the last time we scaled up or down was at least the cooldown period ago
    if [[ "${CW_VALUE}" -ge "${CW_SCALE_UP_VALUE}"  &&  "${KUBE_CURRENT_REPLICAS}" -lt "${KUBE_MAX_REPLICAS}"  &&  "${KUBE_LAST_SCALING}" < $(date --utc --iso-8601="seconds" -d "-${KUBE_SCALE_UP_COOLDOWN} seconds") ]]; then
        NEW_REPLICAS=$(( ${KUBE_CURRENT_REPLICAS} + ${KUBE_SCALE_UP_COUNT} ))
        NEW_REPLICAS=$(( ${NEW_REPLICAS} < ${KUBE_MAX_REPLICAS} ? ${NEW_REPLICAS} : ${KUBE_MAX_REPLICAS} ))
        echo "Scaling up from ${KUBE_CURRENT_REPLICAS} to ${NEW_REPLICAS}"
        PAYLOAD='[{"op":"replace","path":"/spec/replicas","value":"'${NEW_REPLICAS}'"}]'
        curl -sS --cacert "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" -H "Authorization: Bearer ${KUBE_TOKEN}" -X PATCH -H 'Content-Type: application/json-patch+json' --data "${PAYLOAD}" "${KUBE_URL}"
        KUBE_LAST_SCALING=$(date --utc --iso-8601="seconds")
    fi

done
