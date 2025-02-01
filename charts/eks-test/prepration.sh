ARCH=amd64
PLATFORM=$(uname -s)_$ARCH

curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" | grep $PLATFORM | sha256sum --check
tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz
sudo mv /tmp/eksctl /usr/local/bin

curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# need to create the cluster before executing bellow command.
eksctl create cluster -f ./cluster.yaml

echo "------------------------- Associate OIDC"
eksctl utils associate-iam-oidc-provider --cluster eks-phoenix --approve

echo "------------------------- Install AWS loadbalancer"
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json
POLICY_ARN=$(aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json \
    --query 'Policy.Arn' --output text)

eksctl create iamserviceaccount \
  --cluster=eks-phoenix \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn ${POLICY_ARN} --approve 

helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=eks-phoenix \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

echo "------------------------- Install external DNS"
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns
eksctl create iamserviceaccount \
  --cluster=eks-phoenix \
  --name=external-dns-service-account \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonRoute53FullAccess --approve 
helm upgrade --install external-dns \
  --set serviceAccount.create=false \
  --set serviceAccount.name=external-dns-service-account \
  external-dns/external-dns



# IAM Role for EKS norker nodes to access EFS file system 
# https://github.com/kubernetes-sigs/aws-efs-csi-driver/blob/master/docs/iam-policy-create.md
echo "------------------------- Install EFS CSI driver"
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-efs-csi-driver/master/docs/iam-policy-example.json
EFS_POLICY_ARN=$(aws iam create-policy \
    --policy-name EKS_EFS_CSI_Driver_Policy \
    --policy-document file://iam-policy-example.json \
    --query 'Policy.Arn' --output text)
eksctl create iamserviceaccount \
    --cluster eks-phoenix \
    --namespace kube-system \
    --name efs-csi-controller-sa \
    --attach-policy-arn ${EFS_POLICY_ARN} \
    --approve \
    --region us-east-1
# EFS CSI driver to mount EFS to kubernetes
# https://docs.aws.amazon.com/eks/latest/userguide/add-ons-images.html
# https://github.com/kubernetes-sigs/aws-efs-csi-driver?tab=readme-ov-file
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm repo update aws-efs-csi-driver
helm upgrade --install aws-efs-csi-driver --namespace kube-system aws-efs-csi-driver/aws-efs-csi-driver \
  --set image.repository=602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/aws-efs-csi-driver \
  --set controller.serviceAccount.create=false \
  --set controller.serviceAccount.name=efs-csi-controller-sa  


echo "------------------------- Mount EFS"
FILE_SYSTEM_ID=$(aws efs create-file-system --creation-token phoenix-token --region us-east-1 --query 'FileSystemId' --output text)
VPC_ID=$(aws eks describe-cluster --name eks-phoenix --region us-east-1 --query 'cluster.resourcesVpcConfig.vpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text)
WORKER_NODES_SG=$(aws ec2 describe-instances --filters "Name=tag:aws:eks:cluster-name,Values=eks-phoenix" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $WORKER_NODES_SG --protocol tcp --port 2049 --cidr 10.0.0.0/16
for SUBNET in $SUBNETS; do
  aws efs create-mount-target --file-system-id $FILE_SYSTEM_ID --subnet-id $SUBNET --security-groups $WORKER_NODES_SG
done
# aws efs describe-file-systems --file-system-id $FILE_SYSTEM_ID
# aws efs describe-mount-targets --file-system-id $FILE_SYSTEM_ID





# DOMAIN_NAME=$(aws route53 list-hosted-zones --query "HostedZones[0].Name" --output text | xargs | sed 's/.$//')
# helm upgrade --install phoenix --set phoenixDB.volumes.fileSystemId=<FID> --set baseDomain=$DOMAIN_NAME --set phoenixDB.volumes.storageClassName=efs-sc -n operators --create-namespace .
# kubectl logs -n kube-system -l app=efs-csi-controller
# kubectl logs -n operators -l app.kubernetes.io/name=external-dns

# kubectl describe ingress phoenix-backend-ingress -n operators 
