#!/bin/bash
source config.env
echo "Creating Application Load Balancer..."
ALB_ARN=$(aws elbv2 create-load-balancer --name ${PROJECT}-alb --subnets $PUB_SUBNET_1 $PUB_SUBNET_2 --security-groups $ALB_SG --region $REGION  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --region $REGION --query 'LoadBalancers[0].DNSName' --output text)

echo "ALB created: $ALB_DNS"

TG_ARN=$(aws elbv2 create-target-group \
    --name ${PROJECT}-tg \
    --protocol HTTP \
    --port 80 \
    --vpc-id $VPC_ID \
    --health-check-path / \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --region $REGION \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)

aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN \
    --region $REGION

echo "Creating launch template..."

cat > user-data.sh << 'EOL'
#!/bin/bash
yum update -y
yum install -y httpd
systemctl start httpd
systemctl enable httpd

# Create a simple web page
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>AWS Demo App</title>
    <style>
        body { font-family: Arial; margin: 20px; }
        .info { background: #f5f5f5; padding: 15px; margin: 10px 0; }
    </style>
</head>
<body>
    <h1>AWS Scalable Web Application Demo</h1>
    <p>This app is running on AWS with Auto Scaling and Load Balancing ya maaaaaaaaaan.</p>
    
    <div class="info">
        <h3>Server Info:</h3>
        <p>Instance ID: <span id="instance-id">Loading...</span></p>
        <p>Availability Zone: <span id="az">Loading...</span></p>
        <p>Local IP: <span id="local-ip">Loading...</span></p>
    </div>
    
    <h3>Features:</h3>
    <ul>
        <li>Application Load Balancer</li>
        <li>Auto Scaling Group</li>
        <li>Multi-AZ deployment</li>
        <li>CloudWatch monitoring</li>
    </ul>
    
    <script>
        // Get instance metadata from AWS
        fetch('http://169.254.169.254/latest/meta-data/instance-id')
            .then(response => response.text())
            .then(data => document.getElementById('instance-id').textContent = data)
            .catch(() => document.getElementById('instance-id').textContent = 'Not available');
            
        fetch('http://169.254.169.254/latest/meta-data/placement/availability-zone')
            .then(response => response.text())
            .then(data => document.getElementById('az').textContent = data)
            .catch(() => document.getElementById('az').textContent = 'Not available');
            
        fetch('http://169.254.169.254/latest/meta-data/local-ipv4')
            .then(response => response.text())
            .then(data => document.getElementById('local-ip').textContent = data)
            .catch(() => document.getElementById('local-ip').textContent = 'Not available');
    </script>
</body>
</html>
EOF

# Health check endpoint
echo "OK" > /var/www/html/health
EOL

USER_DATA=$(base64 -w 0 user-data.sh)

AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text \
    --region $REGION)


aws ec2 create-launch-template \
    --launch-template-name ${PROJECT}-lt \
    --launch-template-data "{
        \"ImageId\":\"$AMI_ID\",
        \"InstanceType\":\"t3.micro\",
        \"SecurityGroupIds\":[\"$WEB_SG\"],
        \"UserData\":\"$USER_DATA\",
        \"IamInstanceProfile\":{\"Name\":\"${PROJECT}-instance-profile\"},
        \"TagSpecifications\":[{
            \"ResourceType\":\"instance\",
            \"Tags\":[{\"Key\":\"Name\",\"Value\":\"${PROJECT}-web-server\"}]
        }]
    }" \
    --region $REGION

cat > trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

aws iam create-role \
    --role-name ${PROJECT}-ec2-role \
    --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
    --role-name ${PROJECT}-ec2-role \
    --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

aws iam create-instance-profile --instance-profile-name ${PROJECT}-instance-profile
aws iam add-role-to-instance-profile \
    --instance-profile-name ${PROJECT}-instance-profile \
    --role-name ${PROJECT}-ec2-role

echo "Waiting for IAM role propagation..."
sleep 30  # Sometimes AWS needs more time, increase if launch template fails

aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name ${PROJECT}-asg \
    --launch-template "LaunchTemplateName=${PROJECT}-lt,Version=\$Latest" \
    --min-size 2 \
    --max-size 6 \
    --desired-capacity 2 \
    --target-group-arns $TG_ARN \
    --vpc-zone-identifier "${PRIV_SUBNET_1},${PRIV_SUBNET_2}" \
    --health-check-type ELB \
    --health-check-grace-period 300 \
    --region $REGION


SCALE_UP_ARN=$(aws autoscaling put-scaling-policy \
    --auto-scaling-group-name ${PROJECT}-asg \
    --policy-name ${PROJECT}-scale-up \
    --policy-type TargetTrackingScaling \
    --target-tracking-configuration "{
        \"TargetValue\": 70.0,
        \"PredefinedMetricSpecification\": {
            \"PredefinedMetricType\": \"ASGAverageCPUUtilization\"
        }
    }" \
    --region $REGION \
    --query 'PolicyARN' \
    --output text)

echo "Auto Scaling setup complete!"

cat >> config.env << EOF
ALB_ARN=$ALB_ARN
ALB_DNS=$ALB_DNS
TG_ARN=$TG_ARN
AMI_ID=$AMI_ID
SCALE_UP_ARN=$SCALE_UP_ARN
EOF

echo "application will be available at: http://$ALB_DNS"

rm -f user-data.sh trust-policy.json
