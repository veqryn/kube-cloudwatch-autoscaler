# kube-cloudwatch-autoscaler
Kubernetes pod/replica autoscaling based on any AWS CloudWatch metric (ex: SQS Queue Size or Max Age, ELB Response Time, etc)

Separate multiple CloudWatch dimensions with spaces, such as:
`"Name=TargetGroup,Value=targetgroup/my-tg/abc Name=LoadBalancer,Value=app/my-elb/xyz Name=AvailabilityZone,Value=us-east-1e"`
