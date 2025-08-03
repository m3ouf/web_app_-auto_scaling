#!/bin/bash

# Set up CloudWatch monitoring and SNS notifications

source config.env

echo "Setting up monitoring and alerting..."

SNS_TOPIC_ARN=$(aws sns create-topic --name ${PROJECT}-alerts --region $REGION --query 'TopicArn' --output text)


aws cloudwatch put-metric-alarm \
    --alarm-name "${PROJECT}-high-cpu" \
    --alarm-description "High CPU utilization" \
    --metric-name CPUUtilization \
    --namespace AWS/EC2 \
    --statistic Average \
    --period 300 \
    --threshold 80 \
    --comparison-operator GreaterThanThreshold \
    --evaluation-periods 2 \
    --alarm-actions $SNS_TOPIC_ARN \
    --dimensions Name=AutoScalingGroupName,Value=${PROJECT}-asg \
    --region $REGION

aws cloudwatch put-metric-alarm \
    --alarm-name "${PROJECT}-unhealthy-targets" \
    --alarm-description "Unhealthy target count is high" \
    --metric-name UnHealthyHostCount \
    --namespace AWS/ApplicationELB \
    --statistic Average \
    --period 60 \
    --threshold 1 \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --evaluation-periods 2 \
    --alarm-actions $SNS_TOPIC_ARN \
    --dimensions Name=LoadBalancer,Value=$(echo $ALB_ARN | cut -d'/' -f2-) \
    --region $REGION

aws cloudwatch put-metric-alarm \
    --alarm-name "${PROJECT}-high-response-time" \
    --alarm-description "High response time" \
    --metric-name TargetResponseTime \
    --namespace AWS/ApplicationELB \
    --statistic Average \
    --period 300 \
    --threshold 2.0 \
    --comparison-operator GreaterThanThreshold \
    --evaluation-periods 2 \
    --alarm-actions $SNS_TOPIC_ARN \
    --dimensions Name=LoadBalancer,Value=$(echo $ALB_ARN | cut -d'/' -f2-) \
    --region $REGION

cat > dashboard.json << EOF
{
    "widgets": [
        {
            "type": "metric",
            "x": 0,
            "y": 0,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/EC2", "CPUUtilization", "AutoScalingGroupName", "${PROJECT}-asg" ]
                ],
                "period": 300,
                "stat": "Average",
                "region": "$REGION",
                "title": "EC2 CPU Utilization"
            }
        },
        {
            "type": "metric",
            "x": 12,
            "y": 0,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/ApplicationELB", "RequestCount", "LoadBalancer", "$(echo $ALB_ARN | cut -d'/' -f2-)" ]
                ],
                "period": 300,
                "stat": "Sum",
                "region": "$REGION",
                "title": "ALB Request Count"
            }
        },
        {
            "type": "metric",
            "x": 0,
            "y": 6,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "$(echo $ALB_ARN | cut -d'/' -f2-)" ]
                ],
                "period": 300,
                "stat": "Average",
                "region": "$REGION",
                "title": "Response Time"
            }
        },
        {
            "type": "metric",
            "x": 12,
            "y": 6,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", "$(echo $ALB_ARN | cut -d'/' -f2-)" ],
                    [ ".", "UnHealthyHostCount", ".", "." ]
                ],
                "period": 300,
                "stat": "Average",
                "region": "$REGION",
                "title": "Target Health"
            }
        }
    ]
}
EOF

aws cloudwatch put-dashboard \
    --dashboard-name "${PROJECT}-dashboard" \
    --dashboard-body file://dashboard.json \
    --region $REGION

cat >> config.env << EOF
SNS_TOPIC_ARN=$SNS_TOPIC_ARN
EOF

echo "Monitoring setup complete!"
echo ""
echo "CloudWatch Dashboard: https://$REGION.console.aws.amazon.com/cloudwatch/home?region=$REGION#dashboards:name=${PROJECT}-dashboard"
echo "SNS Topic ARN: $SNS_TOPIC_ARN"
echo ""
echo "Don't forget to subscribe to the SNS topic to receive alerts!"
echo "Note: Check your spam folder for the subscription confirmation email"

rm -f dashboard.json
