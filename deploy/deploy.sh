#!/usr/bin/env bash
# Despliegue completo en AWS (correr en CloudShell, us-east-1).
# Uso:  bash deploy/deploy.sh all      (o un paso:  bash deploy/deploy.sh paso1_ecr)
set -uo pipefail

export AWS_DEFAULT_REGION=us-east-1
EXPECTED_ACCOUNT=787124623188
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
if [ "$ACCOUNT" != "$EXPECTED_ACCOUNT" ]; then
  echo "ABORT: cuenta $ACCOUNT no es la cuenta del campus $EXPECTED_ACCOUNT"; return 1 2>/dev/null || exit 1
fi

P=cs-docker                                   # prefijo (como jaom-docker del profe)
REPO=$P
REGISTRY=$ACCOUNT.dkr.ecr.us-east-1.amazonaws.com
CLUSTER=cs-cluster-produccion
FAMILY=$P-task
SERVICE=$P-task-service
SG_NAME=$P-sg
LOG_GROUP=/ecs/$FAMILY
BUCKET=$P-frontend-$ACCOUNT
ROLE=ecsTaskExecutionRole
cd "$(dirname "${BASH_SOURCE[0]}")/.." || true

paso1_ecr() {   # Repositorio privado ECR + build/push de las 2 imagenes
  aws ecr describe-repositories --repository-names $REPO >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name $REPO --image-scanning-configuration scanOnPush=true >/dev/null
  aws ecr get-login-password | docker login --username AWS --password-stdin $REGISTRY
  docker build --no-cache --platform linux/amd64 -t $REPO:api ./api
  docker tag $REPO:api $REGISTRY/$REPO:api && docker push $REGISTRY/$REPO:api
  docker build --no-cache --platform linux/amd64 -t $REPO:nginx -f nginx/Dockerfile .
  docker tag $REPO:nginx $REGISTRY/$REPO:nginx && docker push $REGISTRY/$REPO:nginx
  aws ecr list-images --repository-name $REPO --output table
}

paso2_iam() {   # Rol de ejecucion de tareas ECS
  if ! aws iam get-role --role-name $ROLE >/dev/null 2>&1; then
    aws iam create-role --role-name $ROLE --description "Allows ECS tasks to call AWS services on your behalf." \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    aws iam attach-role-policy --role-name $ROLE --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    sleep 10
  fi
  aws iam get-role --role-name $ROLE --query Role.Arn --output text
}

paso3_taskdef() {   # Definicion de tarea Fargate: db (MySQL) + api + nginx en el mismo task
  aws logs create-log-group --log-group-name $LOG_GROUP 2>/dev/null || true
  LOG='"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"'$LOG_GROUP'","awslogs-region":"us-east-1","awslogs-stream-prefix":"ecs"}}'
  cat > /tmp/taskdef.json <<EOF
{
  "family": "$FAMILY",
  "requiresCompatibilities": ["FARGATE"],
  "networkMode": "awsvpc",
  "cpu": "1024", "memory": "3072",
  "runtimePlatform": {"cpuArchitecture": "X86_64", "operatingSystemFamily": "LINUX"},
  "executionRoleArn": "arn:aws:iam::$ACCOUNT:role/$ROLE",
  "containerDefinitions": [
    {"name": "db", "image": "public.ecr.aws/docker/library/mysql:8.0", "essential": true,
     "portMappings": [{"containerPort": 3306, "protocol": "tcp"}],
     "environment": [
       {"name": "MYSQL_ROOT_PASSWORD", "value": "rootsecretpassword"},
       {"name": "MYSQL_DATABASE", "value": "appdb"},
       {"name": "MYSQL_USER", "value": "appuser"},
       {"name": "MYSQL_PASSWORD", "value": "apppassword"}],
     $LOG},
    {"name": "api", "image": "$REGISTRY/$REPO:api", "essential": true,
     "portMappings": [{"containerPort": 8000, "protocol": "tcp"}],
     "dependsOn": [{"containerName": "db", "condition": "START"}],
     "environment": [
       {"name": "DB_HOST", "value": "127.0.0.1"},
       {"name": "DB_PORT", "value": "3306"},
       {"name": "DB_USER", "value": "appuser"},
       {"name": "DB_PASSWORD", "value": "apppassword"},
       {"name": "DB_NAME", "value": "appdb"}],
     $LOG},
    {"name": "nginx", "image": "$REGISTRY/$REPO:nginx", "essential": true,
     "portMappings": [{"containerPort": 80, "protocol": "tcp", "appProtocol": "http"}],
     "dependsOn": [{"containerName": "api", "condition": "START"}],
     "environment": [{"name": "API_HOST", "value": "127.0.0.1"}],
     $LOG}
  ]
}
EOF
  aws ecs register-task-definition --cli-input-json file:///tmp/taskdef.json \
    --query 'taskDefinition.[family,revision,status]' --output text
}

paso4_red() {   # Grupo de seguridad (HTTP 80 publico) en la VPC por defecto
  VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
  SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC Name=default-for-az,Values=true --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
  SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$SG_NAME Name=vpc-id,Values=$VPC --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$SG" = "None" ]; then
    SG=$(aws ec2 create-security-group --group-name $SG_NAME --description "HTTP 80 para nginx (ECS)" --vpc-id $VPC --query GroupId --output text)
    aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
  fi
  export VPC SUBNETS SG; echo "VPC=$VPC SG=$SG SUBNETS=$SUBNETS"
}

paso5_ecs() {   # Cluster + servicio Fargate con IP publica
  paso4_red
  aws ecs describe-clusters --clusters $CLUSTER --query 'clusters[?status==`ACTIVE`].clusterName' --output text | grep -q $CLUSTER \
    || aws ecs create-cluster --cluster-name $CLUSTER --capacity-providers FARGATE --query cluster.clusterName --output text
  if aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query 'services[?status==`ACTIVE`].serviceName' --output text | grep -q $SERVICE; then
    aws ecs update-service --cluster $CLUSTER --service $SERVICE --task-definition $FAMILY --force-new-deployment --query service.serviceName --output text
  else
    aws ecs create-service --cluster $CLUSTER --service-name $SERVICE --task-definition $FAMILY \
      --desired-count 1 --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=ENABLED}" \
      --query service.serviceName --output text
  fi
}

ecs_dns() {   # DNS publico del task en ejecucion
  TASK=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --desired-status RUNNING --query 'taskArns[0]' --output text)
  ENI=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text)
  aws ec2 describe-network-interfaces --network-interface-ids $ENI --query 'NetworkInterfaces[0].Association.[PublicIp,PublicDnsName]' --output text
}

paso6_s3() {   # Bucket S3: sitio web estatico + politica de bucket (lectura publica)
  read -r IP DNS < <(ecs_dns); echo "ECS: http://$IP  ($DNS)"
  aws s3api head-bucket --bucket $BUCKET 2>/dev/null || aws s3api create-bucket --bucket $BUCKET >/dev/null
  aws s3api put-public-access-block --bucket $BUCKET --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
  aws s3api put-bucket-website --bucket $BUCKET --website-configuration '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"index.html"}}'
  aws s3api put-bucket-policy --bucket $BUCKET --policy '{
    "Version":"2012-10-17",
    "Statement":[{"Sid":"PublicReadGetObject","Effect":"Allow","Principal":"*",
      "Action":"s3:GetObject","Resource":"arn:aws:s3:::'$BUCKET'/*"}]}'
  mkdir -p /tmp/site && cp frontend/* /tmp/site/
  sed -i "s#window.API_URL_DIRECTA = \"\"#window.API_URL_DIRECTA = \"http://$DNS\"#" /tmp/site/config.js
  aws s3 sync /tmp/site s3://$BUCKET --delete --cache-control "no-cache"
  echo "S3 website: http://$BUCKET.s3-website-us-east-1.amazonaws.com"
}

paso7_cloudfront() {   # CloudFront: / -> S3 website, /api/* /docs /openapi.json -> ECS (nginx)
  read -r IP DNS < <(ecs_dns)
  S3_ORIGIN=$BUCKET.s3-website-us-east-1.amazonaws.com
  OPT=658327ea-f89d-4fab-a63d-7e88639e58f6      # Managed-CachingOptimized
  NOCACHE=4135ea2d-6df8-44a3-9df3-4b5a84be39ad  # Managed-CachingDisabled
  ALLVIEW=b689b0a8-53d0-40ab-baf2-68738e2966ac  # Managed-AllViewerExceptHostHeader
  api_beh() { echo '{"PathPattern":"'$1'","TargetOriginId":"ecs-nginx","ViewerProtocolPolicy":"redirect-to-https",
    "AllowedMethods":{"Quantity":7,"Items":["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],"CachedMethods":{"Quantity":2,"Items":["GET","HEAD"]}},
    "CachePolicyId":"'$NOCACHE'","OriginRequestPolicyId":"'$ALLVIEW'","Compress":true}'; }
  CUSTOM='"CustomOriginConfig":{"HTTPPort":80,"HTTPSPort":443,"OriginProtocolPolicy":"http-only","OriginSslProtocols":{"Quantity":1,"Items":["TLSv1.2"]}}'
  cat > /tmp/cf.json <<EOF
{
  "CallerReference": "$P-$(date +%s)",
  "Comment": "$P frontend S3 + API ECS",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "PriceClass": "PriceClass_100",
  "Origins": {"Quantity": 2, "Items": [
    {"Id": "s3-website", "DomainName": "$S3_ORIGIN", $CUSTOM},
    {"Id": "ecs-nginx", "DomainName": "$DNS", $CUSTOM}]},
  "DefaultCacheBehavior": {"TargetOriginId": "s3-website", "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {"Quantity": 2, "Items": ["GET","HEAD"], "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}},
    "CachePolicyId": "$OPT", "Compress": true},
  "CacheBehaviors": {"Quantity": 3, "Items": [$(api_beh '/api/*'), $(api_beh '/docs*'), $(api_beh '/openapi.json')]}
}
EOF
  aws cloudfront create-distribution --distribution-config file:///tmp/cf.json \
    --query 'Distribution.[Id,DomainName,Status]' --output text
}

estado() {
  echo "--- ECS"; aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query 'services[0].[status,runningCount,desiredCount]' --output text
  echo "--- Task DNS"; ecs_dns
  echo "--- S3: http://$BUCKET.s3-website-us-east-1.amazonaws.com"
  echo "--- CloudFront"; aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='$P frontend S3 + API ECS'].[Id,DomainName,Status]" --output text
}

case "${1:-}" in
  all)
    paso1_ecr && paso2_iam && paso3_taskdef && paso5_ecs
    echo "Esperando que el task quede RUNNING..."; aws ecs wait services-stable --cluster $CLUSTER --services $SERVICE
    paso6_s3 && paso7_cloudfront && estado ;;
  "") echo "Uso: bash deploy/deploy.sh {all|paso1_ecr|paso2_iam|paso3_taskdef|paso5_ecs|paso6_s3|paso7_cloudfront|estado}" ;;
  *) "$@" ;;
esac
