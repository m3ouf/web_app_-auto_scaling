#!/bin/bash

REGION="us-east-1"
PROJECT="scalable-web-app-test1"

echo "Starting infrastructure deployment for $PROJECT in $REGION..."

VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --region $REGION --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$PROJECT-vpc --region $REGION
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames --region $REGION

IGW_ID=$(aws ec2 create-internet-gateway --region $REGION --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 create-tags --resources $IGW_ID --tags Key=Name,Value=$PROJECT-igw --region $REGION
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION

PUB_SUBNET_1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone ${REGION}a --region $REGION --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $PUB_SUBNET_1 --tags Key=Name,Value=$PROJECT-public-1a --region $REGION
PUB_SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 --availability-zone ${REGION}b --region $REGION --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $PUB_SUBNET_2 --tags Key=Name,Value=$PROJECT-public-1b --region $REGION
PRIV_SUBNET_1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.3.0/24 --availability-zone ${REGION}a --region $REGION --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $PRIV_SUBNET_1 --tags Key=Name,Value=$PROJECT-private-1a --region $REGION
PRIV_SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.4.0/24 --availability-zone ${REGION}b --region $REGION --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $PRIV_SUBNET_2 --tags Key=Name,Value=$PROJECT-private-1b --region $REGION

echo "Subnets created in both AZs"
EIP_1=$(aws ec2 allocate-address --domain vpc --region $REGION --query 'AllocationId' --output text)
EIP_2=$(aws ec2 allocate-address --domain vpc --region $REGION --query 'AllocationId' --output text)
NAT_1=$(aws ec2 create-nat-gateway --subnet-id $PUB_SUBNET_1 --allocation-id $EIP_1 --region $REGION --query 'NatGateway.NatGatewayId' --output text)
NAT_2=$(aws ec2 create-nat-gateway --subnet-id $PUB_SUBNET_2 --allocation-id $EIP_2 --region $REGION --query 'NatGateway.NatGatewayId' --output text)
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_1 --region $REGION
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_2 --region $REGION
PUB_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID --region $REGION --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-tags --resources $PUB_RT --tags Key=Name,Value=$PROJECT-public-rt --region $REGION
aws ec2 create-route --route-table-id $PUB_RT --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID --region $REGION
aws ec2 associate-route-table --subnet-id $PUB_SUBNET_1 --route-table-id $PUB_RT --region $REGION
aws ec2 associate-route-table --subnet-id $PUB_SUBNET_2 --route-table-id $PUB_RT --region $REGION
PRIV_RT_1=$(aws ec2 create-route-table --vpc-id $VPC_ID --region $REGION --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-tags --resources $PRIV_RT_1 --tags Key=Name,Value=$PROJECT-private-rt-1a --region $REGION
aws ec2 create-route --route-table-id $PRIV_RT_1 --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_1 --region $REGION
aws ec2 associate-route-table --subnet-id $PRIV_SUBNET_1 --route-table-id $PRIV_RT_1 --region $REGION
PRIV_RT_2=$(aws ec2 create-route-table --vpc-id $VPC_ID --region $REGION --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-tags --resources $PRIV_RT_2 --tags Key=Name,Value=$PROJECT-private-rt-1b --region $REGION
aws ec2 create-route --route-table-id $PRIV_RT_2 --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_2 --region $REGION
aws ec2 associate-route-table --subnet-id $PRIV_SUBNET_2 --route-table-id $PRIV_RT_2 --region $REGION
ALB_SG=$(aws ec2 create-security-group --group-name ${PROJECT}-alb-sg --description "ALB security group" --vpc-id $VPC_ID --region $REGION --query 'GroupId' --output text)
aws ec2 create-tags --resources $ALB_SG --tags Key=Name,Value=$PROJECT-alb-sg --region $REGION
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 443 --cidr 0.0.0.0/0 --region $REGION
WEB_SG=$(aws ec2 create-security-group --group-name ${PROJECT}-web-sg --description "Web servers security group" --vpc-id $VPC_ID --region $REGION --query 'GroupId' --output text)
aws ec2 create-tags --resources $WEB_SG --tags Key=Name,Value=$PROJECT-web-sg --region $REGION
aws ec2 authorize-security-group-ingress --group-id $WEB_SG --protocol tcp --port 80 --source-group $ALB_SG --region $REGION
aws ec2 authorize-security-group-ingress --group-id $WEB_SG --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION

# Save the configuration
cat > config.env << EOF
VPC_ID=$VPC_ID
PUB_SUBNET_1=$PUB_SUBNET_1
PUB_SUBNET_2=$PUB_SUBNET_2
PRIV_SUBNET_1=$PRIV_SUBNET_1
PRIV_SUBNET_2=$PRIV_SUBNET_2
ALB_SG=$ALB_SG
WEB_SG=$WEB_SG
REGION=$REGION
EOF
