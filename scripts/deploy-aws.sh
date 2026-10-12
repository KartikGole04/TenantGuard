#!/bin/bash
# TenantGuard AWS Deployment Script
# This script automates the entire AWS deployment process

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}TenantGuard AWS Deployment${NC}"
echo "================================"

# Check prerequisites
check_prerequisites() {
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    if ! command -v aws &> /dev/null; then
        echo -e "${RED}AWS CLI not found. Install it first.${NC}"
        exit 1
    fi
    
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker not found. Install it first.${NC}"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}jq not found. Install it first.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Prerequisites OK${NC}"
}

# Load environment
load_env() {
    echo -e "${YELLOW}Loading environment...${NC}"
    
    if [ -f .env.aws ]; then
        source .env.aws
    else
        echo -e "${RED}.env.aws not found. Creating it...${NC}"
        cat > .env.aws << 'EOF'
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export PROJECT_NAME=tenantguard
export ENVIRONMENT=prod
export ECR_REPO_NAME=tenantguard
export CLUSTER_NAME=tenantguard-cluster
export CONTAINER_PORT=8080
export CONTAINER_MEMORY=512
export CONTAINER_CPU=256
export DB_INSTANCE_CLASS=db.t4g.micro
export DB_ALLOCATED_STORAGE=20
export DB_NAME=tenantguard_db
export DB_USER=tenantguard_admin
export DB_PASSWORD=$(openssl rand -base64 32)
export REDIS_NODE_TYPE=cache.t4g.micro
export REDIS_ENGINE_VERSION=7.0
export ALB_NAME=tenantguard-alb
export VPC_CIDR=10.0.0.0/16
export SUBNET_1_CIDR=10.0.1.0/24
export SUBNET_2_CIDR=10.0.2.0/24
export API_SECRET_KEY=$(openssl rand -base64 32)
EOF
        source .env.aws
    fi
    
    echo -e "${GREEN}Environment loaded${NC}"
    echo "  Region: $AWS_REGION"
    echo "  Account: $AWS_ACCOUNT_ID"
    echo "  Cluster: $CLUSTER_NAME"
}

# Push Docker images to ECR
push_images() {
    echo -e "${YELLOW}Pushing Docker images to ECR...${NC}"
    
    # Create repositories
    aws ecr create-repository --repository-name $PROJECT_NAME-api --region $AWS_REGION 2>/dev/null || true
    aws ecr create-repository --repository-name $PROJECT_NAME-predictor --region $AWS_REGION 2>/dev/null || true
    aws ecr create-repository --repository-name $PROJECT_NAME-dashboard --region $AWS_REGION 2>/dev/null || true
    
    # Login to ECR
    aws ecr get-login-password --region $AWS_REGION | \
        docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
    
    # Build and push API
    echo -e "${YELLOW}Building and pushing API image...${NC}"
    docker build -f Dockerfile.api -t $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT_NAME-api:latest .
    docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT_NAME-api:latest
    
    # Build and push Predictor
    echo -e "${YELLOW}Building and pushing Predictor image...${NC}"
    docker build -f predictor/Dockerfile -t $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT_NAME-predictor:latest ./predictor
    docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT_NAME-predictor:latest
    
    # Build and push Dashboard
    echo -e "${YELLOW}Building and pushing Dashboard image...${NC}"
    docker build -f dashboard/Dockerfile -t $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT_NAME-dashboard:latest ./dashboard
    docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT_NAME-dashboard:latest
    
    echo -e "${GREEN}Images pushed${NC}"
}

# Main
main() {
    check_prerequisites
    load_env
    push_images
    
    echo -e "${GREEN}Next steps:${NC}"
    echo "1. Run: source .env.aws"
    echo "2. Follow docs/AWS_DEPLOYMENT.md for full setup"
    echo "3. Create infrastructure manually or use CloudFormation"
}

main
