CLUSTER_NAME ?= shaky-cluster
# Only has an effect during creation. Upgrades of existing clusters need to be handled manually
# Reference: https://cloud.google.com/kubernetes-engine/release-notes
KUBERNETES_VERSION ?= 1.14.8-gke.17
TEKTON_VERSION ?= v0.9.1

# By default use the currently active account and project, but allow override during make invoke
SERVICE_ACCOUNT ?= $(shell gcloud config list --format 'value(core.account)' 2>/dev/null)
PROJECT_NAME ?= $(shell gcloud config list --format 'value(core.project)' 2>/dev/null)
# Default is a unique bucket name for the project
BUCKET_NAME ?= ${CLUSTER_NAME}-europe-west1-${PROJECT_NAME}

init:
	gcloud config set core/project ${PROJECT_NAME}
	gcloud config set core/account ${SERVICE_ACCOUNT}
	gcloud config set compute/region europe-west1
	gcloud config set container/cluster ${CLUSTER_NAME}

create: create-infra update-services
update: update-services

# --num-nodes is per zone
# --min-nodes is per zone
# --max-nodes is per zone
# Stackdriver is used for logging and monitoring.
# Vertical Pod Autoscaler is used for pod resource request recommendations.
# Preemptible nodes are cheaper but are replaced at least once per 24 hours.
create-infra: init
	@echo "Enable necessary Google Cloud APIs"
	gcloud services enable container.googleapis.com compute.googleapis.com iam.googleapis.com iamcredentials.googleapis.com
	@echo "Create cluster"
	gcloud beta container clusters create ${CLUSTER_NAME} \
	  --cluster-version=${KUBERNETES_VERSION} \
	  --region=europe-west1 \
	  --node-locations=europe-west1-d,europe-west1-d-b,europe-west1-d-c \
	  --disk-size=100 \
	  --disk-type=pd-ssd \
	  --machine-type=n1-standard-4 \
	  --min-cpu-platform="Intel Skylake" \
	  --image-type=COS_CONTAINERD \
	  --enable-autoscaling \
	  --num-nodes=1 \
	  --min-nodes=1 \
	  --max-nodes=2 \
	  --enable-stackdriver-kubernetes \
	  --enable-vertical-pod-autoscaling \
	  --enable-ip-alias \
	  --enable-shielded-nodes \
	  --shielded-secure-boot \
	  --identity-namespace=${PROJECT_NAME}.svc.id.goog \
	  --preemptible
	@echo "Granting ${SERVICE_ACCOUNT} cluster-admin role binding"
	kubectl create clusterrolebinding cluster-admin-binding \
	  --clusterrole=cluster-admin \
	  --user=${SERVICE_ACCOUNT}
	@echo "Can ${SERVICE_ACCOUNT} create roles now?"
	kubectl auth can-i create roles
	@echo "Create service account for Config Connector"
	gcloud iam service-accounts create cnrm-system
	gcloud projects add-iam-policy-binding ${PROJECT_NAME} \
  	  --member serviceAccount:cnrm-system@${PROJECT_NAME}.iam.gserviceaccount.com \
  	  --role roles/owner
	gcloud iam service-accounts keys create --iam-account \
 	  cnrm-system@${PROJECT_NAME}.iam.gserviceaccount.com key.json
	@echo "Put Config Connector service account key into a Kubernetes Secret"
	kubectl create namespace cnrm-system
	kubectl create secret generic gcp-key --from-file key.json --namespace cnrm-system
	rm -v key.json

update-services: init
	gcloud container clusters get-credentials ${CLUSTER_NAME} --region=europe-west1-d
	@echo "Installing Config Connector"
	kubectl apply -f services/config-connector/
	@echo "Installing Tekton Pipelines"
	kubectl apply -f services/tekton/

check-upgrades: init
	@echo -e "\nConfigured Kubernetes version: ${KUBERNETES_VERSION}"
	@echo -n "Available Kubernetes versions: "
	@gcloud container get-server-config --region=europe-west1-d --format="value(validMasterVersions)" 2>/dev/null
	@echo "Configured Tekton version: ${TEKTON_VERSION}"
	@printf "Available Tekton version: "
	@curl -sL https://api.github.com/repos/tektoncd/pipeline/releases | jq -r .[0].tag_name
	@echo "Tekton changelog: https://github.com/tektoncd/pipeline/releases"

download-tekton:
	wget -O services/tekton/release.yaml https://github.com/tektoncd/pipeline/releases/download/${TEKTON_VERSION}/release.yaml

download-config-connector:
	curl -X GET -sLO \
      -H "Authorization: Bearer $(shell gcloud auth print-access-token)" \
      --location-trusted \
      https://us-central1-cnrm-eap.cloudfunctions.net/download/latest/infra/install-bundle.tar.gz
	tar zxvf install-bundle.tar.gz
	mv install-bundle/* services/config-connector/
	rm -rf install-bundle
	rm -v install-bundle.tar.gz
