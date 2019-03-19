#!/bin/bash
# This script will periodically scale the number of replicas
# of a given kubernetes deployment up or down,
# determined by the value of an aws cloudwatch metric.

if [ "${DEBUG}" = true ]; then
    set -x
fi

# The following are required if not using AWS EC2 Roles
# AWS_ACCESS_KEY_ID
# AWS_SECRET_ACCESS_KEY
# AWS_DEFAULT_REGION

# Required and optional environment variables.
# All time/durations must be in seconds, all values must be integers.
KUBE_ENDPOINT="${KUBE_ENDPOINT:?"Required: KUBE_ENDPOINT must be equal to the Kube API scaling endpoint for the deployment, such as: 'apis/apps/v1beta1/namespaces/default/deployments/<MyAppName>/scale'"}"
KUBE_MIN_REPLICAS="${KUBE_MIN_REPLICAS:-1}"
KUBE_MAX_REPLICAS="${KUBE_MAX_REPLICAS:-50}"
KUBE_SCALE_DOWN_COUNT="${KUBE_SCALE_DOWN_COUNT:-1}"
KUBE_SCALE_UP_COUNT="${KUBE_SCALE_UP_COUNT:-1}"
KUBE_SCALE_DOWN_COOLDOWN="${KUBE_SCALE_DOWN_COOLDOWN:-180}"
KUBE_SCALE_UP_COOLDOWN="${KUBE_SCALE_UP_COOLDOWN:-300}"
CW_SCALE_WITH_METRIC="${CW_SCALE_WITH_METRIC:-false}"
CW_SCALE_DOWN_VALUE="${CW_SCALE_DOWN_VALUE:?"Required: CW_SCALE_DOWN_VALUE must be set to the AWS CloudWatch metric value that will trigger scaling down the replicas, such as '300'"}"
CW_SCALE_UP_VALUE="${CW_SCALE_UP_VALUE:?"Required: CW_SCALE_UP_VALUE must be set to the AWS CloudWatch metric value that will trigger scaling up the replicas, such as '900'"}"
CW_NAMESPACE="${CW_NAMESPACE:?"Required: CW_NAMESPACE must be set to the AWS CloudWatch Namespace, such as: 'AWS/SQS'"}"
CW_METRIC_NAME="${CW_METRIC_NAME:?"Required: CW_METRIC_NAME must be set to the AWS CloudWatch MetricName, such as: 'ApproximateAgeOfOldestMessage'"}"
CW_DIMENSIONS="${CW_DIMENSIONS:?"Required: CW_DIMENSIONS must be set to the AWS CloudWatch Dimensions, such as: 'Name=QueueName,Value=my_sqs_queue_name'"}"
CW_STATISTICS="${CW_STATISTICS:-"Average"}"
CW_PERIOD="${CW_PERIOD:-360}"
CW_POLL_PERIOD="${CW_POLL_PERIOD:-30}"

# There can be multiple CloudWatch Dimensions, so split into an array
read -r -a CW_DIMENSIONS_ARRAY <<< "${CW_DIMENSIONS}"

# Create Kubernetes scaling url
KUBE_URL="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_PORT_443_TCP_PORT}/${KUBE_ENDPOINT}"

# Set last scaling event time to be far in the past, so initial comparisons work.
# This format works for both busybox and gnu date commands.
KUBE_LAST_SCALING=$(date -u -I'seconds' -d @$(( $(date -u +%s) - 31536000 )))

printf '%s\n' "$(date -u -I'seconds') Starting autoscaler..."

# Exit immediately on signal
trap 'exit 0' SIGINT SIGTERM EXIT

# Loop forever
while true
do
    # Sleep poll period with wait on trapped signal
    sleep "${CW_POLL_PERIOD}s" & wait "${!}"

    # Get kubernetes service endpoint token
    KUBE_TOKEN=$(</var/run/secrets/kubernetes.io/serviceaccount/token)

    # Query kubernetes pod/deployment current replica count
    KUBE_CURRENT_OUTPUT=$(curl -sS --cacert "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" -H "Authorization: Bearer ${KUBE_TOKEN}" "${KUBE_URL}")
    if [[ "${?}" -ne 0 ]]; then
        printf '%s\n' "$(date -u -I'seconds') Exiting: Unable to query kubernetes service account. URL:${KUBE_URL} Output:${KUBE_CURRENT_OUTPUT}"
        exit 1 # Kube will restart this pod
    fi

    KUBE_CURRENT_REPLICAS=$(printf '%s' "${KUBE_CURRENT_OUTPUT}" | jq 'first(.spec.replicas, .status.replicas | numbers)')
    if [[ -z "${KUBE_CURRENT_REPLICAS}" || "${KUBE_CURRENT_REPLICAS}" == "null" ]]; then
        printf '%s\n' "$(date -u -I'seconds') Exiting: Kubernetes service account not showing .spec.replicas or .status.replicas: ${KUBE_CURRENT_OUTPUT}"
        exit 1 # Kube will restart this pod
    fi
    if [ "${VERBOSE}" = true ]; then
        printf '%s\n' "$(date -u -I'seconds') Kube Replicas: ${KUBE_CURRENT_REPLICAS}"
    fi

    # Query aws cloudwatch metric
    CW_OUTPUT=$(aws cloudwatch get-metric-statistics --namespace "${CW_NAMESPACE}" --metric-name "${CW_METRIC_NAME}" --dimensions "${CW_DIMENSIONS_ARRAY[@]}" --start-time $(date -u -I'seconds' -d @$(( $(date -u +%s) - ${CW_PERIOD} ))) --end-time $(date -u -I'seconds') --statistics "${CW_STATISTICS}" --period "${CW_PERIOD}")
    if [[ "${?}" -ne 0 ]]; then
        printf '%s\n' "$(date -u -I'seconds') Exiting: Unable to query AWS CloudWatch Metric: ${CW_OUTPUT}"
        exit 1 # Kube will restart this pod
    fi

    CW_VALUE=$(printf '%s' "${CW_OUTPUT}" | jq ".Datapoints[0].${CW_STATISTICS} | numbers")
    if [[ -z "${CW_VALUE}" || "${CW_VALUE}" == "null" ]]; then
        printf '%s\n' "$(date -u -I'seconds') AWS CloudWatch Metric returned no datapoints. If metric exists and container has aws auth, then period may be set too low. Namespace:${CW_NAMESPACE} MetricName:${CW_METRIC_NAME} Dimensions:${CW_DIMENSIONS_ARRAY[@]} Statistics:${CW_STATISTICS} Period:${CW_PERIOD} Output:${CW_OUTPUT}"
        continue
    fi
    # CloudWatch metrics can have decimals, but bash doesn't like them, so remove with printf
    CW_VALUE=$(printf '%.0f' "${CW_VALUE}")
    if [ "${VERBOSE}" = true ]; then
        printf '%s\n' "$(date -u -I'seconds') AWS CloudWatch Value: ${CW_VALUE}"
    fi

    NEW_REPLICAS="${KUBE_CURRENT_REPLICAS}"

    if [[ "${CW_SCALE_WITH_METRIC}" = true ]]; then
        NEW_REPLICAS="${CW_VALUE}"
    else
        # If the metric value is <= the scale-down value, and current replica count is > min replicas, and the last time we scaled up or down was at least the cooldown period ago
        if [[ "${CW_VALUE}" -le "${CW_SCALE_DOWN_VALUE}"  &&  "${KUBE_CURRENT_REPLICAS}" -gt "${KUBE_MIN_REPLICAS}"  &&  "${KUBE_LAST_SCALING}" < $(date -u -I'seconds' -d @$(( $(date -u +%s) - ${KUBE_SCALE_DOWN_COOLDOWN} ))) ]]; then
            NEW_REPLICAS=$(( ${KUBE_CURRENT_REPLICAS} - ${KUBE_SCALE_DOWN_COUNT} ))
        fi

        # If the metric value is >= the scale-up value, and current replica count is < max replicas, and the last time we scaled up or down was at least the cooldown period ago
        if [[ "${CW_VALUE}" -ge "${CW_SCALE_UP_VALUE}"  &&  "${KUBE_CURRENT_REPLICAS}" -lt "${KUBE_MAX_REPLICAS}"  &&  "${KUBE_LAST_SCALING}" < $(date -u -I'seconds' -d @$(( $(date -u +%s) - ${KUBE_SCALE_UP_COOLDOWN} ))) ]]; then
            NEW_REPLICAS=$(( ${KUBE_CURRENT_REPLICAS} + ${KUBE_SCALE_UP_COUNT} ))
        fi
    fi

    # Clamp new replicas to the min and max configured values
    NEW_REPLICAS=$(( ${NEW_REPLICAS} > ${KUBE_MIN_REPLICAS} ? ${NEW_REPLICAS} : ${KUBE_MIN_REPLICAS} ))
    NEW_REPLICAS=$(( ${NEW_REPLICAS} < ${KUBE_MAX_REPLICAS} ? ${NEW_REPLICAS} : ${KUBE_MAX_REPLICAS} ))

    # If the scale has changed
    if [[ "${NEW_REPLICAS}" -ne "${KUBE_CURRENT_REPLICAS}"]]; then
        printf '%s\n' "$(date -u -I'seconds') Scaling from ${KUBE_CURRENT_REPLICAS} to ${NEW_REPLICAS}"
        PAYLOAD='[{"op":"replace","path":"/spec/replicas","value":'"${NEW_REPLICAS}"'}]'
        SCALE_OUTPUT=$(curl -sS --cacert "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" -H "Authorization: Bearer ${KUBE_TOKEN}" -X PATCH -H 'Content-Type: application/json-patch+json' --data "${PAYLOAD}" "${KUBE_URL}")
        if [[ "${?}" -ne 0 ]]; then
            printf '%s\n' "$(date -u -I'seconds') Exiting: Unable to patch kubernetes deployment. Payload:${PAYLOAD} OUTPUT:${SCALE_OUTPUT}"
            exit 1 # Kube will restart this pod
        fi
        # Confirm response says correct number of replicas, instead of an error message
        SCALE_REPLICAS=$(printf '%s' "${SCALE_OUTPUT}" | jq '.spec.replicas')
        if [[ "${SCALE_REPLICAS}" -ne "${NEW_REPLICAS}" ]]; then
            printf '%s\n' "$(date -u -I'seconds') Exiting: Unable to patch kubernetes deployment. Payload:${PAYLOAD} OUTPUT:${SCALE_OUTPUT}"
            exit 1 # Kube will restart this pod
        fi
        KUBE_LAST_SCALING=$(date -u -I'seconds')
    fi

done
