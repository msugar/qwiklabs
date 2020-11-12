#! /bin/bash

#
# Quest: Getting Started: Create and Manage Cloud Resources
#        https://google.qwiklabs.com/quests/120
#
# Lab: Getting Started: Create and Manage Cloud Resources: Challenge Lab
#
# This challenge lab tests your skills and knowledge from the labs in the 
# Getting Started: Create and Manage Cloud Resources quest. You should be
# familiar with the content of labs before attempting this lab
#

#
echo Set the default project_id, region, and zone for all resources
#

gcloud auth list
gcloud config list project

#gcloud projects list
DEFAULT_PROJECT=$(gcloud config get-value core/project 2> /dev/null)
DEFAULT_PROJECT=${DEFAULT_PROJECT:-$DEVSHELL_PROJECT_ID}
DEFAULT_PROJECT=${DEFAULT_PROJECT:-my-qwiklabs-295305}
read -p "Enter PROJECT ID [$DEFAULT_PROJECT]: " PROJECT_ID
PROJECT_ID=${PROJECT_ID:-$DEFAULT_PROJECT}
gcloud config set project $PROJECT_ID
echo "PROJECT_ID=$PROJECT_ID"

#gcloud compute project-info describe --project $PROJECT_ID

#gcloud compute regions list
DEFAULT_REGION=$(gcloud config get-value compute/region 2> /dev/null)
DEFAULT_REGION=${DEFAULT_REGION:-us-east1}
read -p "Enter REGION [$DEFAULT_REGION]: " REGION
REGION=${REGION:-$DEFAULT_REGION}
gcloud config set compute/region $REGION
echo "REGION=$REGION"

#gcloud compute zones list
DEFAULT_ZONE=$(gcloud config get-value compute/zone 2> /dev/null)
DEFAULT_ZONE=${DEFAULT_ZONE:-us-east1-b}
read -p "Enter ZONE [$DEFAULT_ZONE]: " ZONE
ZONE=${ZONE:-$DEFAULT_ZONE}
gcloud config set compute/zone $ZONE
echo "ZONE=$ZONE"

#
echo Task 1: Create a project jumphost instance
#

# gcloud compute machine-types list
VM_NAME=nucleus-jumphost
gcloud compute instances create $VM_NAME --machine-type=f1-micro --zone=$ZONE
gcloud compute instances describe $VM_NAME

# Connect to your VM instance with SSH
#gcloud compute ssh $VM_NAME --zone $ZONE

#
echo  Task 2: Create a Kubernetes service cluster
#

gcloud services enable container.googleapis.com

# Create a GKE cluster
# Create a cluster (in the us-east1-b zone) to host the service.
CLUSTER_NAME=nucleus-cluster
CLUSTER_ZONE=us-east1-b
gcloud container clusters create $CLUSTER_NAME --zone=$CLUSTER_ZONE

# Get authentication credentials for the cluster
gcloud container clusters get-credentials $CLUSTER_NAME

# Deploy an application to the cluster
# Use the Docker container hello-app (gcr.io/google-samples/hello-app:2.0)
# as a place holder; the team will replace the container with their own work later.
# Expose the app on port 8080.
#APP_NAME=hello-server
APP_NAME=nucleus-hello-server
APP_PORT=8080
kubectl create deployment $APP_NAME --image=gcr.io/google-samples/hello-app:2.0
kubectl expose deployment $APP_NAME --type=LoadBalancer --port $APP_PORT

kubectl get service

#
echo Task 3: Set up an HTTP load balancer
#

# Startup script to be used by every virtual machine instance to set up Nginx server
cat << EOF > startup.sh
#! /bin/bash
apt-get update
apt-get install -y nginx
service nginx start
sed -i -- 's/nginx/Google Cloud Platform - '"\$HOSTNAME"'/' /var/www/html/index.nginx-debian.html
EOF

# * Create an instance template that uses the startup script
# Instance templates define the configuration of every VM in the cluster
# (disk, CPUs, memory, etc)
#INSTANCE_TEMPLATE_NAME=nginx-template
INSTANCE_TEMPLATE_NAME=nucleus-nginx-template
gcloud compute instance-templates create $INSTANCE_TEMPLATE_NAME \
         --metadata-from-file startup-script=startup.sh
         
# * Create a target pool.
# A target pool allows a single access point to all the instances in a group
# and is necessary for load balancing.
#TARGET_POOL_NAME=nginx-pool
TARGET_POOL_NAME=nucleus-nginx-pool
gcloud compute target-pools create $TARGET_POOL_NAME

# * Create a managed instance group.
# Managed instance groups use the instance template to instantiate multiple
# VM instances.
# This creates 2 virtual machine instances with names that are prefixed with 
# ${BASE_INSTANCE_NAME}-. This may take a couple of minutes.
#MANAGED_INSTANCE_GROUP_NAME=nginx-group
MANAGED_INSTANCE_GROUP_NAME=nucleus-nginx-group
#BASE_INSTANCE_NAME=nginx
BASE_INSTANCE_NAME=nucleus-webserver
NUMBER_OF_INSTANCES=2
gcloud compute instance-groups managed create $MANAGED_INSTANCE_GROUP_NAME \
         --base-instance-name $BASE_INSTANCE_NAME \
         --size $NUMBER_OF_INSTANCES \
         --template $INSTANCE_TEMPLATE_NAME \
         --target-pool $TARGET_POOL_NAME
         
gcloud compute instances list        
         
# * Create a firewall rule to allow traffic (80/tcp).
# Configure a firewall so that you can connect to the machines on port 80 via the EXTERNAL_IP addresses returned in the previous result
#FIREWALL_RULE_NAME=www-firewall
FIREWALL_RULE_NAME=nucleus-www-firewall
FIREWALL_RULE_PORT=80
gcloud compute firewall-rules create $FIREWALL_RULE_NAME --allow tcp:$FIREWALL_RULE_PORT

# Network load balancer x HTTP(s) load balancer
#
# Network load balancing allows you to balance the load of your systems based on incoming IP data, such as address, port, and protocol type. You also get some options that are not available with HTTP(S) load balancing. For example, you can load balance additional TCP/UDP-based protocols, such as SMTP traffic. And if your application utilizes TCP connections, network load balancing allows your app to inspect the packets, but HTTP(S) load balancing does not.
#gcloud compute forwarding-rules create nginx-lb \
#         --region us-central1 \
#         --ports=80 \
#         --target-pool nginx-pool
#gcloud compute forwarding-rules list
#
# HTTP(S) load balancing provides global load balancing for HTTP(S) requests directed to your instances. You can configure URL rules to route some URLs to one set of instances and route other URLs to other instances. Requests are always routed to the instance group that is closest to the user, if that group has enough capacity and is appropriate for the request. If the closest group does not have enough capacity, the request is sent to the closest group that does have capacity.

# * Create a health check.
# Health checks verify that the instance is responding to HTTP or HTTPS traffic.
#HEALTH_CHECK_NAME=http-basic-check
HEALTH_CHECK_NAME=nucleus-http-basic-check
gcloud compute http-health-checks create $HEALTH_CHECK_NAME

# Define an HTTP service, and map a port name to the relevant port for the instance group
# Now the load balancing service can forward traffic to the named port.
gcloud compute instance-groups managed \
      set-named-ports $MANAGED_INSTANCE_GROUP_NAME \
      --named-ports http:80

# * Create a backend service, and attach the managed instance group.
#BACKEND_SERVICE_NAME=nginx-backend
BACKEND_SERVICE_NAME=nucleus-nginx-backend
# Create a backend service:
gcloud compute backend-services create $BACKEND_SERVICE_NAME \
      --protocol HTTP --http-health-checks $HEALTH_CHECK_NAME --global
# Add the instance group to the backend service:      
gcloud compute backend-services add-backend $BACKEND_SERVICE_NAME \
   --instance-group $MANAGED_INSTANCE_GROUP_NAME \
   --instance-group-zone $ZONE \
   --global      
      
# * Create a URL map, and target the HTTP proxy to route requests to your URL map.
# Create a default URL map that directs all incoming requests to all your instances:
#URL_MAP_NAME=web-map
URL_MAP_NAME=nucleus-web-map
gcloud compute url-maps create $URL_MAP_NAME \
   --default-service $BACKEND_SERVICE_NAME
# Create a target HTTP proxy to route requests to your URL map:
#TARGET_HTTP_PROXY_NAME=http-lb-proxy
TARGET_HTTP_PROXY_NAME=nucleus-http-lb-proxy
gcloud compute target-http-proxies create $TARGET_HTTP_PROXY_NAME \
   --url-map $URL_MAP_NAME

# * Create a forwarding rule.
# A forwarding rule sends traffic to a specific target HTTP or HTTPS proxy depending on the IP address, IP protocol, and port specified. The global forwarding rule does not support multiple ports. After you create the global forwarding rule, it can take several minutes for your configuration to propagate.
# Create a global forwarding rule to handle and route incoming requests:
#FORWARDING_RULE_NAME=http-content-rule
FORWARDING_RULE_NAME=nucleus-http-content-rule
gcloud compute forwarding-rules create $FORWARDING_RULE_NAME \
      --global \
      --target-http-proxy $TARGET_HTTP_PROXY_NAME \
      --ports 80
      
gcloud compute forwarding-rules list

# From your browser, access http://IP_ADDRESS

#
echo Delete resources
#

while true; do
  read -p "Delete resources? (Y/n) " YES_NO
  YES_NO=${YES_NO:-Yes}
  case $YES_NO in
    [Yy]* ) 
      # Delete HTTP load balancer
      gcloud compute forwarding-rules delete $FORWARDING_RULE_NAME --global --quiet
      gcloud compute target-http-proxies delete $TARGET_HTTP_PROXY_NAME --quiet
      gcloud compute url-maps delete $URL_MAP_NAME --quiet
      gcloud compute backend-services delete $BACKEND_SERVICE_NAME --global --quiet
      gcloud compute http-health-checks delete $HEALTH_CHECK_NAME --quiet
      gcloud compute firewall-rules delete $FIREWALL_RULE_NAME --quiet
      gcloud compute instance-groups managed delete $MANAGED_INSTANCE_GROUP_NAME --quiet
      gcloud compute target-pools delete $TARGET_POOL_NAME --quiet
      gcloud compute instance-templates delete $INSTANCE_TEMPLATE_NAME --quiet

      # Deleting the cluster
      gcloud container clusters delete $CLUSTER_NAME --zone=$CLUSTER_ZONE --quiet

      # Delete jumphost VM
      gcloud compute instances delete $VM_NAME --quiet
      
      break
      ;;
    [Nn]* ) 
      break
      ;;
    * ) echo "Please answer yes or no.";;
  esac
done



