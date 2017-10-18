# kube-cloudwatch-autoscaler
This is a Kubernetes deployment that will manage the autoscaling of one other Kubernetes deployment/replica/pod, periodically scaling the number of replicas based on any AWS CloudWatch metric (ex: SQS Queue Size or Max Age, ELB Response Time, etc).
An example would be using it to increase the number of pods when the age of the oldest message on SQS gets too old, and decrease the number of pods when it stabilizes again.

## How to use:
1. Ensure this autoscaler will have the necessary AWS permissions to access CloudWatch.
    * You may either use 'AWS EC2 Roles', or create a user with an access token. 
2. Create the below deployment in your Kubernetes cluster, after changing the variables to suite your needs.

### Kubernetes deployment yaml
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
          image: "veqryn/kube-cloudwatch-autoscaler:1.0"
          env:
            - name: KUBE_ENDPOINT # Required
              value: "apis/apps/v1beta1/namespaces/default/deployments/my-app-name/scale"
            - name: KUBE_MIN_REPLICAS # Optional
              value: "1"
            - name: KUBE_MAX_REPLICAS # Optional
              value: "100"
            - name: KUBE_SCALE_DOWN_COUNT # Optional
              value: "1"
            - name: KUBE_SCALE_UP_COUNT # Optional
              value: "1"
            - name: KUBE_SCALE_DOWN_COOLDOWN # Optional
              value: "120"
            - name: KUBE_SCALE_UP_COOLDOWN # Optional
              value: "300"
            - name: CW_SCALE_DOWN_VALUE # Required
              value: "300"
            - name: CW_SCALE_UP_VALUE # Required
              value: "900"
            - name: CW_NAMESPACE # Required
              value: "AWS/SQS"
            - name: CW_METRIC_NAME # Required
              value: "ApproximateAgeOfOldestMessage"
            - name: CW_DIMENSIONS # Required
              value: "Name=QueueName,Value=my_sqs_queue_name"
              # Separate multiple dimensions with spaces, such as: "Name=TargetGroup,Value=targetgroup/my-tg/abc Name=LoadBalancer,Value=app/my-elb/xyz"
            - name: CW_STATISTICS # Optional
              value: "Average"
            - name: CW_PERIOD # Optional
              value: "360"
            - name: CW_POLL_PERIOD # Optional
              value: "30"
            - name: VERBOSE # Optional
              value: "true"
            - name: AWS_DEFAULT_REGION # Optional only if using AWS EC2 Roles
              value: "us-east-1"
            - name: AWS_ACCESS_KEY_ID # Optional only if using AWS EC2 Roles
              valueFrom:
                secretKeyRef:
                  name: aws-secrets
                  key: aws-access-key-id
            - name: AWS_SECRET_ACCESS_KEY # Optional only if using AWS EC2 Roles
              valueFrom:
                secretKeyRef:
                  name: aws-secrets
                  key: aws-secret-access-key

---
# Optional only if using AWS EC2 Roles
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
