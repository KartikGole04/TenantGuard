# TenantGuard on AWS — Production Deployment Guide

This guide walks through deploying TenantGuard on AWS using managed services for high availability, scalability, and minimal operational overhead.

## Architecture Overview

```
CloudFront (CDN)
    ↓
ALB (Application Load Balancer)
    ├→ ECS Fargate (API Service)
    ├→ ECS Fargate (Predictor Service)
    └→ ECS Fargate (Dashboard)
        ↓
    RDS (PostgreSQL)
    ElastiCache (Redis)
    CloudWatch (Metrics & Logs)
    SNS/SQS (Alerts & Queues)
    S3 (Backups & Logs)
```

## AWS Services Used

| Service | Purpose | Why Managed |
|---------|---------|-------------|
| **ECS Fargate** | Run API, predictor, dashboard containers | No EC2 management, auto-scaling |
| **RDS PostgreSQL** | Multi-tenant policy storage | Automated backups, failover, monitoring |
| **ElastiCache Redis** | Rate-limit & quota counters | Sub-millisecond access, auto-failover |
| **Application Load Balancer (ALB)** | Route traffic to services | Auto health checks, SSL termination |
| **CloudWatch** | Logs, metrics, dashboards | Centralized observability |
| **IAM** | Service authentication & authorization | Fine-grained permissions |
| **Secrets Manager** | Store DB passwords & API keys | Automatic rotation |
| **CloudFormation** | Infrastructure as Code | Reproducible deployments |
| **SNS/SQS** | Notifications & workload queues | Decoupled async processing |
| **S3** | Backup storage & access logs | Durable, cheap archival |

---

## Prerequisites

1. **AWS Account** with admin access
2. **AWS CLI** installed and configured:
   ```bash
   aws configure
   # Enter: Access Key ID, Secret Access Key, Region (e.g., us-east-1), Output format (json)
   ```
3. **Docker** installed locally (for pushing images)
4. **jq** installed (for JSON parsing):
   ```bash
   # macOS
   brew install jq
   
   # Linux
   sudo apt-get install jq
   ```

---

## Step 1: Set Up Environment Variables

Create a `.env.aws` file:

```bash
cat > .env.aws << 'EOF'
# AWS Configuration
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export PROJECT_NAME=tenantguard
export ENVIRONMENT=prod

# ECS Configuration
export ECR_REPO_NAME=tenantguard
export CLUSTER_NAME=tenantguard-cluster
export CONTAINER_PORT=8080
export CONTAINER_MEMORY=512
export CONTAINER_CPU=256

# RDS Configuration
export DB_INSTANCE_CLASS=db.t4g.micro
export DB_ALLOCATED_STORAGE=20
export DB_NAME=tenantguard_db
export DB_USER=tenantguard_admin
export DB_PASSWORD=$(openssl rand -base64 32)

# Redis Configuration
export REDIS_NODE_TYPE=cache.t4g.micro
export REDIS_ENGINE_VERSION=7.0

# ALB Configuration
export ALB_NAME=tenantguard-alb
export VPC_CIDR=10.0.0.0/16
export SUBNET_1_CIDR=10.0.1.0/24
export SUBNET_2_CIDR=10.0.2.0/24

# Secrets
export API_SECRET_KEY=$(openssl rand -base64 32)
EOF

source .env.aws
```

---

## Step 2: Push Docker Images to ECR

### 2.1 Create ECR Repository

```bash
aws ecr create-repository \
  --repository-name $PROJECT_NAME-api \
  --region $AWS_REGION 2>/dev/null || echo "Repo already exists"

aws ecr create-repository \
  --repository-name $PROJECT_NAME-predictor \
  --region $AWS_REGION 2>/dev/null || echo "Repo already exists"

aws ecr create-repository \
  --repository-name $PROJECT_NAME-dashboard \
  --region $AWS_REGION 2>/dev/null || echo "Repo already exists"
```

### 2.2 Get ECR Login Token

```bash
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
```

### 2.3 Build and Push Images

```bash
# Build API image
docker build -f Dockerfile.api -t $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT_NAME-api:latest .
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT_NAME-api:latest

# Build Predictor image
docker build -f predictor/Dockerfile -t $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT_NAME-predictor:latest ./predictor
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT_NAME-predictor:latest

# Build Dashboard image
docker build -f dashboard/Dockerfile -t $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT_NAME-dashboard:latest ./dashboard
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT_NAME-dashboard:latest
```

---

## Step 3: Create Secrets in AWS Secrets Manager

```bash
# Store DB password
aws secretsmanager create-secret \
  --name tenantguard/db-password \
  --secret-string $DB_PASSWORD \
  --region $AWS_REGION 2>/dev/null || echo "Secret already exists"

# Store API secret key
aws secretsmanager create-secret \
  --name tenantguard/api-secret-key \
  --secret-string $API_SECRET_KEY \
  --region $AWS_REGION 2>/dev/null || echo "Secret already exists"
```

---

## Step 4: Create VPC, Subnets, and Security Groups

```bash
# Create VPC
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block $VPC_CIDR \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=tenantguard-vpc}]" \
  --region $AWS_REGION \
  --query 'Vpc.VpcId' \
  --output text)

echo "VPC ID: $VPC_ID"

# Enable DNS
aws ec2 modify-vpc-attribute \
  --vpc-id $VPC_ID \
  --enable-dns-hostnames \
  --region $AWS_REGION

# Create Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=tenantguard-igw}]" \
  --region $AWS_REGION \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

aws ec2 attach-internet-gateway \
  --vpc-id $VPC_ID \
  --internet-gateway-id $IGW_ID \
  --region $AWS_REGION

# Create Subnets (multi-AZ)
SUBNET_1=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block $SUBNET_1_CIDR \
  --availability-zone ${AWS_REGION}a \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=tenantguard-subnet-1}]" \
  --region $AWS_REGION \
  --query 'Subnet.SubnetId' \
  --output text)

SUBNET_2=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block $SUBNET_2_CIDR \
  --availability-zone ${AWS_REGION}b \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=tenantguard-subnet-2}]" \
  --region $AWS_REGION \
  --query 'Subnet.SubnetId' \
  --output text)

echo "Subnet 1: $SUBNET_1"
echo "Subnet 2: $SUBNET_2"

# Create Route Table
ROUTE_TABLE=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=tenantguard-rt}]" \
  --region $AWS_REGION \
  --query 'RouteTable.RouteTableId' \
  --output text)

# Add route to Internet Gateway
aws ec2 create-route \
  --route-table-id $ROUTE_TABLE \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID \
  --region $AWS_REGION

# Associate Route Table with Subnets
aws ec2 associate-route-table \
  --subnet-id $SUBNET_1 \
  --route-table-id $ROUTE_TABLE \
  --region $AWS_REGION

aws ec2 associate-route-table \
  --subnet-id $SUBNET_2 \
  --route-table-id $ROUTE_TABLE \
  --region $AWS_REGION

# Create Security Group for ALB
ALB_SG=$(aws ec2 create-security-group \
  --group-name tenantguard-alb-sg \
  --description "ALB Security Group for TenantGuard" \
  --vpc-id $VPC_ID \
  --region $AWS_REGION \
  --query 'GroupId' \
  --output text)

# Allow HTTP and HTTPS to ALB
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG \
  --protocol tcp --port 80 \
  --cidr 0.0.0.0/0 \
  --region $AWS_REGION

aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG \
  --protocol tcp --port 443 \
  --cidr 0.0.0.0/0 \
  --region $AWS_REGION

# Create Security Group for ECS Tasks
ECS_SG=$(aws ec2 create-security-group \
  --group-name tenantguard-ecs-sg \
  --description "ECS Security Group for TenantGuard" \
  --vpc-id $VPC_ID \
  --region $AWS_REGION \
  --query 'GroupId' \
  --output text)

# Allow ECS tasks to receive traffic from ALB
aws ec2 authorize-security-group-ingress \
  --group-id $ECS_SG \
  --protocol tcp --port $CONTAINER_PORT \
  --source-security-group-id $ALB_SG \
  --region $AWS_REGION

# Allow ECS tasks to communicate with each other
aws ec2 authorize-security-group-ingress \
  --group-id $ECS_SG \
  --protocol tcp --port 0-65535 \
  --source-security-group-id $ECS_SG \
  --region $AWS_REGION

# Create Security Group for RDS
RDS_SG=$(aws ec2 create-security-group \
  --group-name tenantguard-rds-sg \
  --description "RDS Security Group for TenantGuard" \
  --vpc-id $VPC_ID \
  --region $AWS_REGION \
  --query 'GroupId' \
  --output text)

# Allow ECS to connect to RDS on port 5432
aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG \
  --protocol tcp --port 5432 \
  --source-security-group-id $ECS_SG \
  --region $AWS_REGION

# Create Security Group for Redis
REDIS_SG=$(aws ec2 create-security-group \
  --group-name tenantguard-redis-sg \
  --description "Redis Security Group for TenantGuard" \
  --vpc-id $VPC_ID \
  --region $AWS_REGION \
  --query 'GroupId' \
  --output text)

# Allow ECS to connect to Redis on port 6379
aws ec2 authorize-security-group-ingress \
  --group-id $REDIS_SG \
  --protocol tcp --port 6379 \
  --source-security-group-id $ECS_SG \
  --region $AWS_REGION

echo "Security Groups created:"
echo "  ALB SG: $ALB_SG"
echo "  ECS SG: $ECS_SG"
echo "  RDS SG: $RDS_SG"
echo "  Redis SG: $REDIS_SG"
```

---

## Step 5: Create RDS PostgreSQL Database

```bash
RDS_ENDPOINT=$(aws rds create-db-instance \
  --db-instance-identifier tenantguard-db \
  --db-instance-class $DB_INSTANCE_CLASS \
  --engine postgres \
  --engine-version 15.3 \
  --master-username $DB_USER \
  --master-user-password $DB_PASSWORD \
  --allocated-storage $DB_ALLOCATED_STORAGE \
  --vpc-security-group-ids $RDS_SG \
  --db-subnet-group-name tenantguard-db-subnet \
  --multi-az \
  --backup-retention-period 7 \
  --storage-type gp3 \
  --no-publicly-accessible \
  --enable-iam-database-authentication \
  --enable-cloudwatch-logs-exports postgresql \
  --region $AWS_REGION 2>/dev/null | \
  jq -r '.DBInstance.Endpoint.Address' || \
  aws rds describe-db-instances \
    --db-instance-identifier tenantguard-db \
    --region $AWS_REGION \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text)

echo "RDS Endpoint: $RDS_ENDPOINT"
echo "Waiting for RDS to be available (5-10 minutes)..."

aws rds wait db-instance-available \
  --db-instance-identifier tenantguard-db \
  --region $AWS_REGION

echo "RDS is ready!"
```

---

## Step 6: Create ElastiCache Redis Cluster

```bash
REDIS_ENDPOINT=$(aws elasticache create-cache-cluster \
  --cache-cluster-id tenantguard-redis \
  --cache-node-type $REDIS_NODE_TYPE \
  --engine redis \
  --engine-version $REDIS_ENGINE_VERSION \
  --num-cache-nodes 1 \
  --vpc-security-group-ids $REDIS_SG \
  --cache-subnet-group-name tenantguard-redis-subnet \
  --auto-failover-enabled \
  --multi-az \
  --region $AWS_REGION 2>/dev/null | \
  jq -r '.CacheCluster.CacheNodes[0].Address' || \
  aws elasticache describe-cache-clusters \
    --cache-cluster-id tenantguard-redis \
    --show-cache-node-info \
    --region $AWS_REGION \
    --query 'CacheClusters[0].CacheNodes[0].Address' \
    --output text)

echo "Redis Endpoint: $REDIS_ENDPOINT"
echo "Waiting for Redis to be available (3-5 minutes)..."

aws elasticache wait cache-cluster-available \
  --cache-cluster-id tenantguard-redis \
  --region $AWS_REGION

echo "Redis is ready!"
```

---

## Step 7: Initialize RDS Database

```bash
# Wait for RDS to be fully initialized
sleep 30

# Get RDS endpoint
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier tenantguard-db \
  --region $AWS_REGION \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)

# Install PostgreSQL client if needed (macOS)
# brew install postgresql

# Connect and initialize schema
PGPASSWORD=$DB_PASSWORD psql \
  -h $RDS_ENDPOINT \
  -U $DB_USER \
  -d $DB_NAME \
  -f db/schema.sql

echo "Database schema initialized!"
```

---

## Step 8: Create ECS Cluster and Task Definitions

```bash
# Create ECS Cluster
aws ecs create-cluster \
  --cluster-name $CLUSTER_NAME \
  --capacity-providers FARGATE FARGATE_SPOT \
  --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
  --region $AWS_REGION

echo "ECS Cluster created: $CLUSTER_NAME"
```

### Create IAM Role for ECS Task Execution

```bash
# Create role for task execution
aws iam create-role \
  --role-name tenantguard-ecs-task-execution-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ecs-tasks.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' 2>/dev/null || echo "Role already exists"

# Attach policy for ECR and CloudWatch Logs
aws iam attach-role-policy \
  --role-name tenantguard-ecs-task-execution-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

aws iam attach-role-policy \
  --role-name tenantguard-ecs-task-execution-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess

# Create role for task (application permissions)
aws iam create-role \
  --role-name tenantguard-ecs-task-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ecs-tasks.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' 2>/dev/null || echo "Role already exists"

# Allow access to Secrets Manager
aws iam put-role-policy \
  --role-name tenantguard-ecs-task-role \
  --policy-name secretsmanager-access \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "arn:aws:secretsmanager:*:*:secret:tenantguard/*"
    }]
  }'
```

---

## Step 9: Create Application Load Balancer (ALB)

```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name $ALB_NAME \
  --subnets $SUBNET_1 $SUBNET_2 \
  --security-groups $ALB_SG \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --region $AWS_REGION \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --region $AWS_REGION \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

echo "ALB created: $ALB_DNS"

# Create Target Group for API
API_TARGET_GROUP=$(aws elbv2 create-target-group \
  --name tenantguard-api-tg \
  --protocol HTTP \
  --port $CONTAINER_PORT \
  --vpc-id $VPC_ID \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --region $AWS_REGION \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

echo "API Target Group: $API_TARGET_GROUP"

# Create Target Group for Dashboard
DASHBOARD_TARGET_GROUP=$(aws elbv2 create-target-group \
  --name tenantguard-dashboard-tg \
  --protocol HTTP \
  --port 3000 \
  --vpc-id $VPC_ID \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-path / \
  --health-check-interval-seconds 30 \
  --region $AWS_REGION \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

echo "Dashboard Target Group: $DASHBOARD_TARGET_GROUP"

# Create Target Group for Predictor
PREDICTOR_TARGET_GROUP=$(aws elbv2 create-target-group \
  --name tenantguard-predictor-tg \
  --protocol HTTP \
  --port 5000 \
  --vpc-id $VPC_ID \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --region $AWS_REGION \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

echo "Predictor Target Group: $PREDICTOR_TARGET_GROUP"

# Create ALB Listener (default to dashboard)
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$DASHBOARD_TARGET_GROUP \
  --region $AWS_REGION

# Create ALB Rule for API
aws elbv2 create-rule \
  --listener-arn $(aws elbv2 describe-listeners \
    --load-balancer-arn $ALB_ARN \
    --region $AWS_REGION \
    --query 'Listeners[0].ListenerArn' \
    --output text) \
  --priority 1 \
  --conditions Field=path-pattern,Values=/api/* \
  --actions Type=forward,TargetGroupArn=$API_TARGET_GROUP \
  --region $AWS_REGION

# Create ALB Rule for Predictor
aws elbv2 create-rule \
  --listener-arn $(aws elbv2 describe-listeners \
    --load-balancer-arn $ALB_ARN \
    --region $AWS_REGION \
    --query 'Listeners[0].ListenerArn' \
    --output text) \
  --priority 2 \
  --conditions Field=path-pattern,Values=/predict* \
  --actions Type=forward,TargetGroupArn=$PREDICTOR_TARGET_GROUP \
  --region $AWS_REGION
```

---

## Step 10: Create ECS Task Definitions

Create `ecs/task-definition-api.json`:

```json
{
  "family": "tenantguard-api",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::ACCOUNT_ID:role/tenantguard-ecs-task-execution-role",
  "taskRoleArn": "arn:aws:iam::ACCOUNT_ID:role/tenantguard-ecs-task-role",
  "containerDefinitions": [
    {
      "name": "tenantguard-api",
      "image": "ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/tenantguard-api:latest",
      "portMappings": [{
        "containerPort": 8080,
        "hostPort": 8080,
        "protocol": "tcp"
      }],
      "environment": [
        {"name": "API_PORT", "value": "8080"},
        {"name": "REDIS_URL", "value": "REDIS_ENDPOINT:6379"},
        {"name": "LOG_LEVEL", "value": "info"}
      ],
      "secrets": [
        {"name": "DB_PASSWORD", "valueFrom": "arn:aws:secretsmanager:REGION:ACCOUNT_ID:secret:tenantguard/db-password"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/tenantguard-api",
          "awslogs-region": "REGION",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
```

Register it:

```bash
# Replace placeholders
sed -i "" "s/ACCOUNT_ID/$AWS_ACCOUNT_ID/g" ecs/task-definition-api.json
sed -i "" "s/REGION/$AWS_REGION/g" ecs/task-definition-api.json
sed -i "" "s/REDIS_ENDPOINT/$REDIS_ENDPOINT/g" ecs/task-definition-api.json

# Register task definition
aws ecs register-task-definition \
  --cli-input-json file://ecs/task-definition-api.json \
  --region $AWS_REGION
```

---

## Step 11: Create ECS Services

```bash
# Create API Service
aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name tenantguard-api-service \
  --task-definition tenantguard-api \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$ECS_SG],assignPublicIp=ENABLED}" \
  --load-balancers targetGroupArn=$API_TARGET_GROUP,containerName=tenantguard-api,containerPort=8080 \
  --deployment-configuration minimumHealthyPercent=50,maximumPercent=200 \
  --region $AWS_REGION

echo "API Service created!"

# Create Dashboard Service
aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name tenantguard-dashboard-service \
  --task-definition tenantguard-dashboard \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$ECS_SG],assignPublicIp=ENABLED}" \
  --load-balancers targetGroupArn=$DASHBOARD_TARGET_GROUP,containerName=tenantguard-dashboard,containerPort=3000 \
  --region $AWS_REGION

echo "Dashboard Service created!"

# Create Predictor Service
aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name tenantguard-predictor-service \
  --task-definition tenantguard-predictor \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$ECS_SG],assignPublicIp=ENABLED}" \
  --load-balancers targetGroupArn=$PREDICTOR_TARGET_GROUP,containerName=tenantguard-predictor,containerPort=5000 \
  --region $AWS_REGION

echo "Predictor Service created!"
```

---

## Step 12: Set Up CloudWatch Monitoring

```bash
# Create log groups
aws logs create-log-group --log-group-name /ecs/tenantguard-api --region $AWS_REGION 2>/dev/null || echo "Log group exists"
aws logs create-log-group --log-group-name /ecs/tenantguard-dashboard --region $AWS_REGION 2>/dev/null || echo "Log group exists"
aws logs create-log-group --log-group-name /ecs/tenantguard-predictor --region $AWS_REGION 2>/dev/null || echo "Log group exists"

# Set retention
aws logs put-retention-policy --log-group-name /ecs/tenantguard-api --retention-in-days 7 --region $AWS_REGION
aws logs put-retention-policy --log-group-name /ecs/tenantguard-dashboard --retention-in-days 7 --region $AWS_REGION
aws logs put-retention-policy --log-group-name /ecs/tenantguard-predictor --retention-in-days 7 --region $AWS_REGION

echo "CloudWatch log groups created!"
```

---

## Step 13: Access Your Deployment

Once everything is running:

```bash
# Get ALB DNS name
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --region $AWS_REGION \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

echo "Dashboard: http://$ALB_DNS"
echo "API: http://$ALB_DNS/api/v1/tenants"
echo "Predictor: http://$ALB_DNS/predict"
```

---

## Step 14: Auto-Scaling

```bash
# Register scalable target for API service
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/$CLUSTER_NAME/tenantguard-api-service \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 2 \
  --max-capacity 10 \
  --region $AWS_REGION

# Create scaling policy (CPU-based)
aws application-autoscaling put-scaling-policy \
  --policy-name tenantguard-api-cpu-scaling \
  --service-namespace ecs \
  --resource-id service/$CLUSTER_NAME/tenantguard-api-service \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration 'TargetValue=70.0,PredefinedMetricSpecification={PredefinedMetricType=ECSServiceAverageCPUUtilization},ScaleOutCooldown=60,ScaleInCooldown=300' \
  --region $AWS_REGION

echo "Auto-scaling configured!"
```

---

## Monitoring & Alerts

View logs in CloudWatch:

```bash
# Stream API logs
aws logs tail /ecs/tenantguard-api --follow --region $AWS_REGION

# Get recent errors
aws logs filter-log-events \
  --log-group-name /ecs/tenantguard-api \
  --filter-pattern "ERROR" \
  --region $AWS_REGION
```

Create CloudWatch Alarms:

```bash
# High CPU alert
aws cloudwatch put-metric-alarm \
  --alarm-name tenantguard-api-high-cpu \
  --alarm-description "Alert when API CPU exceeds 80%" \
  --metric-name CPUUtilization \
  --namespace AWS/ECS \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=ServiceName,Value=tenantguard-api-service Name=ClusterName,Value=$CLUSTER_NAME \
  --region $AWS_REGION
```

---

## Cost Estimation

| Service | Monthly Cost | Notes |
|---------|--------------|-------|
| ECS Fargate | ~$50-100 | 2+ tasks per service |
| RDS db.t4g.micro | ~$30 | Multi-AZ backup |
| ElastiCache cache.t4g.micro | ~$20 | Multi-AZ failover |
| ALB | ~$20 | Data processing |
| Data Transfer | ~$10-50 | Egress costs |
| **Total** | **~$150-250/month** | For production-ready HA |

---

## Cleanup

To tear down everything and avoid charges:

```bash
# Delete ECS services
aws ecs delete-service --cluster $CLUSTER_NAME --service tenantguard-api-service --force --region $AWS_REGION
aws ecs delete-service --cluster $CLUSTER_NAME --service tenantguard-dashboard-service --force --region $AWS_REGION
aws ecs delete-service --cluster $CLUSTER_NAME --service tenantguard-predictor-service --force --region $AWS_REGION

# Delete ECS cluster
aws ecs delete-cluster --cluster $CLUSTER_NAME --region $AWS_REGION

# Delete ALB
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN --region $AWS_REGION

# Delete RDS
aws rds delete-db-instance --db-instance-identifier tenantguard-db --skip-final-snapshot --region $AWS_REGION

# Delete ElastiCache
aws elasticache delete-cache-cluster --cache-cluster-id tenantguard-redis --region $AWS_REGION

# Delete VPC and related resources
aws ec2 detach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID --region $AWS_REGION
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $AWS_REGION
aws ec2 delete-vpc --vpc-id $VPC_ID --region $AWS_REGION

echo "Cleanup complete!"
```

---

## Troubleshooting

### ECS Tasks not starting?

```bash
aws ecs describe-tasks \
  --cluster $CLUSTER_NAME \
  --tasks $(aws ecs list-tasks --cluster $CLUSTER_NAME --region $AWS_REGION --query 'taskArns[0]' --output text) \
  --region $AWS_REGION \
  --query 'tasks[0].{lastStatus:lastStatus,stoppedReason:stoppedReason}'
```

### Can't connect to RDS?

```bash
# Verify security group rules
aws ec2 describe-security-groups --group-ids $RDS_SG --region $AWS_REGION

# Test connectivity from ECS task
aws ecs execute-command \
  --cluster $CLUSTER_NAME \
  --task $(aws ecs list-tasks --cluster $CLUSTER_NAME --region $AWS_REGION --query 'taskArns[0]' --output text) \
  --container tenantguard-api \
  --interactive \
  --command "/bin/sh" \
  --region $AWS_REGION
```

---

## Next Steps

1. **Enable HTTPS** — Use AWS Certificate Manager for free SSL
2. **Add CloudFront** — Cache dashboard and reduce latency
3. **Set up WAF** — Protect API from DDoS and attacks
4. **Enable multi-region** — Deploy to multiple regions for HA
5. **Add backup automation** — Use AWS Backup for RDS and S3
6. **Implement CI/CD** — Use CodePipeline for automated deployments

---

**Questions?** Check AWS documentation or open an issue in the repo.
