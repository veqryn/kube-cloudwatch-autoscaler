# kube-cloudwatch-autoscaler
This is a Kubernetes deployment that will manage the autoscaling of one other Kubernetes deployment/replica/pod, periodically scaling the number of replicas based on any AWS CloudWatch metric (ex: SQS Queue Size or Max Age, ELB Response Time, etc).
An example would be using it to increase the number of pods when the age of the oldest message on SQS gets too old, and decrease the number of pods when it stabilizes again.

Docker image can be found on Docker Hub (https://hub.docker.com/r/veqryn/kube-cloudwatch-autoscaler/) and Docker Cloud (https://cloud.docker.com/swarm/veqryn/repository/docker/veqryn/kube-cloudwatch-autoscaler).

## How to use:
1. Ensure this autoscaler will have the necessary AWS permissions to access CloudWatch.
    * You may either use 'AWS EC2 Roles', or create a user with an access token. 
2. Create the below deployment in your Kubernetes cluster, after changing the variables to suite your needs.

### Kubernetes deployment yaml (with default values for optional variables)
```yaml
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: kube-cloudwatch-autoscaler
  labels:
    app: kube-cloudwatch-autoscaler
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kube-cloudwatch-autoscaler
  template:
    metadata:
      labels:
        app: kube-cloudwatch-autoscaler
    spec:
      containers:
        - name: kube-cloudwatch-autoscaler
          image: "veqryn/kube-cloudwatch-autoscaler:1.4"
          env:
            - name: KUBE_ENDPOINT # Required, the app's api endpoint in kube (this example will cause us to scale a deployment named "my-app-name")
              value: "apis/apps/v1beta1/namespaces/default/deployments/my-app-name/scale"
            - name: KUBE_MIN_REPLICAS # Optional
              value: "1"
            - name: KUBE_MAX_REPLICAS # Optional
              value: "50"
            - name: KUBE_SCALE_DOWN_COUNT # Optional, how many replicas to reduce by when scaling down
              value: "1"
            - name: KUBE_SCALE_UP_COUNT # Optional, how many replicas to increase by when scaling up
              value: "1"
            - name: KUBE_SCALE_DOWN_COOLDOWN # Optional, cooldown in seconds after scaling down
              value: "180"
            - name: KUBE_SCALE_UP_COOLDOWN # Optional, cooldown in seconds after scaling up
              value: "300"
            - name: CW_SCALE_DOWN_VALUE # Required, cloudwatch metric value that will trigger scaling down
              value: "300"
            - name: CW_SCALE_UP_VALUE # Required, cloudwatch metric value that will trigger scaling up
              value: "900"
            - name: CW_NAMESPACE # Required (see https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch_concepts.html)
              value: "AWS/SQS"
            - name: CW_METRIC_NAME # Required
              value: "ApproximateAgeOfOldestMessage"
            - name: CW_DIMENSIONS # Required (Separate multiple dimensions with spaces, such as: "Name=TargetGroup,Value=targetgroup/my-tg/abc Name=LoadBalancer,Value=app/my-elb/xyz")
              value: "Name=QueueName,Value=my_sqs_queue_name"
            - name: CW_DIMENSIONS_DELIMITER # Optional, sets the delimiter for multiple CW_DIMENSIONS. Defaults to a space.
              value: " "
            - name: CW_STATISTICS # Optional, how to aggregate data if there are multiple within a period (Average, Sum, Minimum, Maximum, SampleCount, or pNN.NN)
              value: "Average"
            - name: CW_PERIOD # Optional, the length of time in seconds to search for and aggregate datapoints (should be longer than how often cloudwatch is populated with new datapoints)
              value: "360"
            - name: CW_POLL_PERIOD # Optional, how often to poll cloudwatch for new data, and possibly scale up or down
              value: "30"
            - name: LOG_LEVEL # Optional, defaults to "INFO". Allowable values: "DEBUG" (will log kube and cloudwatch statistics), "INFO" (will log scaling activity), "ERROR" (will log errors only), "OFF" (nothing)
              value: "INFO"
            - name: AWS_DEFAULT_REGION # Optional, Needed only if not using AWS EC2 Roles
              value: "us-east-1"
            - name: AWS_ACCESS_KEY_ID # Optional, Needed only if not using AWS EC2 Roles
              valueFrom:
                secretKeyRef:
                  name: aws-secrets
                  key: aws-access-key-id
            - name: AWS_SECRET_ACCESS_KEY # Optional, Needed only if not using AWS EC2 Roles
              valueFrom:
                secretKeyRef:
                  name: aws-secrets
                  key: aws-secret-access-key
          resources:
            requests:
              memory: 24Mi
              cpu: 10m
            limits:
              memory: 48Mi
              cpu: 50m

---
# Optional, Needed only if not using AWS EC2 Roles
kind: Secret
metadata:
  name: aws-secrets
  labels:
    app: aws-secrets
type: Opaque
data:
  aws-access-key-id: "YXdzLWtleQ=="
  aws-secret-access-key: "YXdzLXNlY3JldA=="
```

### AWS Permissions
Create the following policy (or just use `CloudWatchReadOnlyAccess`) and attach to the role or user.
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "cloudwatch:GetMetricStatistics",
            "Resource": "*"
        }
    ]
}
```
