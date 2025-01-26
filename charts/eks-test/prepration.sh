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

eksctl utils associate-iam-oidc-provider --cluster eks-phoenix --approve


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

helm repo add external-dns https://kubernetes-sigs.github.io/external-dns
eksctl create iamserviceaccount \
  --cluster=eks-phoenix \
  --name=external-dns-service-account \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonRoute53FullAccess --approve 
helm upgrade --install external-dns \
  --set serviceAccount.create=false
  --set serviceAccount.name=external-dns-service-account \
  external-dns/external-dns



# IAM Role for EKS norker nodes to access EFS file system 
# https://github.com/kubernetes-sigs/aws-efs-csi-driver/blob/master/docs/iam-policy-create.md
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



# FILE_SYSTEM_ID=$(aws efs create-file-system --creation-token phoenix-token --region us-east-1 --query 'FileSystemId' --output text)
# VPC_ID=$(aws eks describe-cluster --name eks-phoenix --region us-east-1 --query 'cluster.resourceVpcConfig.vpcId' --output text)
# SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Value=$VPC_ID" --query 'Subnets[].SubnetId' --output text)
# for SUBNET in $SUBNETS; do
#   aws efs create-mount-target --file-system-id $FILE_SYSTEM_ID --subnet-id $SUBNET --security-groups <SG-id> #SG that allows inbound NFS traffic(port 2049) from worker nodes SG
# done
# aws efs describe-file-systems --file-system-id $FILE_SYSTEM_ID
# aws efs describe-mount-targets --file-system-id $FILE_SYSTEM_ID
