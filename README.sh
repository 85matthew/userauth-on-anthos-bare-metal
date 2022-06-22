# userauth-on-anthos-bare-metal

BILLING_ACCOUNT_ID=00000-mybilling-id-00000
PROJECT_NAME=abm-12042022
CREATE_VPC_NAME=default
ROUTER_NAME=router
CLUSTER_NAME=abmc

MACHINE_TYPE=n1-standard-8
VM_PREFIX=abm
VM_WS=$VM_PREFIX-ws
VM_CP1=$VM_PREFIX-cp1
VM_CP2=$VM_PREFIX-cp2
VM_CP3=$VM_PREFIX-cp3
VM_W1=$VM_PREFIX-w1
VM_W2=$VM_PREFIX-w2
gcloud config set project $PROJECT_NAME



export PROJECT_ID=$(gcloud config get-value project)
export ZONE=us-central1-a
export REGION=us-central1

# Create the variables and arrays needed for all the commands on this page:
declare -a VMs=("$VM_WS" "$VM_CP1" "$VM_CP2" "$VM_CP3" "$VM_W1" "$VM_W2")
declare -a IPs=()


####
gcloud compute ssh root@$VM_WS --zone ${ZONE} --tunnel-through-iap
# Wait for connection
# Then run
export clusterid=$CLUSTER_NAME
export KUBECONFIG=$HOME/bmctl-workspace/$clusterid/$clusterid-kubeconfig
####


###
# Install Anthos Service Mesh
###
curl https://storage.googleapis.com/csm-artifacts/asm/asmcli_1.13 > asmcli

curl https://raw.githubusercontent.com/GoogleCloudPlatform/asm-user-auth/v1.1.0/overlay/user-auth-overlay.yaml > user-auth-overlay.yaml

chmod +x asmcli

kubectl create ns istio-system

kubectl config use-context connectgateway_abm-12042022_global_abmc

unset PROJECT_ID # Have to unset this var or asm will grab it and fail.
./asmcli validate \
  --kubeconfig /home/admin_/.kube/config \
  --fleet_id abm-12042022 \
  --output_dir install_dir \
  --platform multicloud


./asmcli install \
  --kubeconfig /home/admin_/.kube/config \
  --fleet_id abm-12042022 \
  --output_dir install_dir \
  --platform multicloud \
  --enable_all \
  --ca mesh_ca \
  --custom_overlay user-auth-overlay.yaml


kubectl create ns asm-user-auth
LABEL=asm-1132-2

kubectl label namespace asm-user-auth \
  istio.io/rev=$LABEL --overwrite



###
# Configuration for OAuth User Authentication
###
LABEL=asm-1132-2
kubectl create namespace asm-user-auth
kubectl label namespace asm-user-auth istio.io/rev=LABEL --overwrite

# Deploy Gateways
kubectl apply -n asm-user-auth -f install_dir/samples/gateways/istio-ingressgateway/

gcloud services status identitytoolkit.googleapis.com

export OIDC_CLIENT_ID='000000000-123412341234-yourOAuthClientID.apps.googleusercontent.com'
export OIDC_CLIENT_SECRET='asdf-mysecret'
export OIDC_ISSUER_URI='https://accounts.google.com'
# Leave redirect host blank to use the original request URL host.
export OIDC_REDIRECT_HOST=''
export OIDC_REDIRECT_PATH='/_gcp_asm_authenticate'

kpt pkg get https://github.com/GoogleCloudPlatform/asm-user-auth.git@v1.1.0 .
cd asm-user-auth/


openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem \
 -days 365 -nodes -subj '/CN=localhost'

# Load the keys into secrets
 kubectl create -n asm-user-auth secret tls userauth-tls-cert --key=key.pem \
--cert=cert.pem

kubectl create secret generic secret-key  \
    --from-file="session_cookie.key"="./samples/cookie_encryption_key.json" \
    --from-file="rctoken.key"="./samples/rctoken_signing_key.json"  \
    --namespace=asm-user-auth

# Substitue our configuration information into the package for deployment
kpt fn eval pkg --image gcr.io/kpt-fn/apply-setters:v0.2 --truncate-output=false -- \
  client-id="$(echo -n ${OIDC_CLIENT_ID} | base64 -w0)" \
  client-secret="$(echo -n ${OIDC_CLIENT_SECRET} | base64 -w0)" \
  issuer-uri="${OIDC_ISSUER_URI}" \
  redirect-host="${OIDC_REDIRECT_HOST}" \
  redirect-path="${OIDC_REDIRECT_PATH}"

# Remove the potential alpha version CRD if exists.
kubectl delete crd userauthconfigs.security.anthos.io
kubectl apply -f ./pkg/asm_user_auth_config_v1beta1.yaml
kubectl apply -f ./pkg

# (Optional) Disable old ASM ingress
kubectl edit cm -n gke-system istio

# Change to OFF and comment other options
# ingressControllerMode: OFF
# #ingressControllerMode: DEFAULT
# #ingressSelector: ingress-gke-system
# #ingressService: istio-ingress

# Restart istiod
kubectl rollout restart deployment/istiod -n gke-system

# Delete the old ingress
kubectl delete deployment -n gke-system istio-ingress
kubectl delete deployment -n gke-system istiod

# ASM core components are installed at this point. Now the application can be deployed and the mesh configured
kubectl apply -f manifests/
