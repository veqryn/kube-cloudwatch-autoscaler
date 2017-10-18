#!/usr/bin/env bash -exu

KUBE_ENDPOINT="/apis/apps/v1beta1/namespaces/default/deployments/mydeployment"
# Default to 1
KUBE_MIN_REPLICAS=2
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


# awscli, curl, jq

# AWS_ACCESS_KEY_ID
# AWS_SECRET_ACCESS_KEY
# AWS_DEFAULT_REGION


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
    CURRENT_REPLICAS=$(curl -sS --cacert "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" -H "Authorization: Bearer ${KUBE_TOKEN}" "https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_PORT_443_TCP_PORT}${KUBE_ENDPOINT}" | jq .spec.replicas)

    # Query aws cloudwatch metric
    CW_VALUE=$(aws cloudwatch get-metric-statistics --namespace "${CW_NAMESPACE}" --metric-name "${CW_METRIC_NAME}" --dimensions "${CW_DIMENSIONS}" --start-time $(date --utc --iso-8601="seconds" -d "-${CW_PERIOD} seconds") --end-time $(date --utc --iso-8601='seconds') --statistics "${CW_STATISTICS}" --period "${CW_PERIOD}" | jq ".Datapoints[0].${CW_STATISTICS}")

    # If cloudwatch returned no metrics then CW_VALUE will be null, so print an error
    if [[ -z "${CW_VALUE}" || "${CW_VALUE}" == "null" ]]; then
        echo "AWS CloudWatch Metric returned no datapoints. If metric exists, period may be set too low. Namespace:${CW_NAMESPACE} MetricName:${CW_METRIC_NAME} Dimensions:${CW_DIMENSIONS} Statistics:${CW_STATISTICS} Period:${CW_PERIOD}"
        continue
    fi

done
