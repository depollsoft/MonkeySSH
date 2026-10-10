#!/bin/bash
# One-time, idempotent IAM setup for the push Cloud Functions in the monkeyssh
# project (see docs/push-notifications.md, "Deployment"). Run by a project
# Owner with gcloud. It creates:
#
#   push-functions@      the functions' runtime identity: FCM send, App Check
#                        token verification, and read access to the
#                        PUSH_TICKET_KEYS secret, nothing else.
#   functions-deployer@  the identity .github/workflows/deploy-functions.yml
#                        deploys as. No key exists; GitHub Actions reaches it
#                        through the `github` Workload Identity pool, whose
#                        provider only accepts this repository, refs/heads/main
#                        and deploy-functions.yml.
#
# The PUSH_TICKET_KEYS secret itself must already exist.
set -euo pipefail

P=monkeyssh
NUM=529923319565
REPO_ID=1137523514  # depollsoft/MonkeySSH; ids survive renames and transfers
OWNER_ID=273730039
RUNTIME="push-functions@$P.iam.gserviceaccount.com"
DEPLOYER="functions-deployer@$P.iam.gserviceaccount.com"
SECRET=PUSH_TICKET_KEYS

ensure_account() {
  gcloud iam service-accounts describe "$1@$P.iam.gserviceaccount.com" --project "$P" >/dev/null 2>&1 ||
    gcloud iam service-accounts create "$1" --project "$P" --display-name "$2" --description "$3"
}
project_role() {
  gcloud projects add-iam-policy-binding "$P" --member "serviceAccount:$1" --role "$2" \
    --condition=None --format=none
}
secret_role() {
  gcloud secrets add-iam-policy-binding "$SECRET" --project "$P" \
    --member "serviceAccount:$1" --role "$2" --format=none
}

ensure_account push-functions "Push functions runtime" \
  "Runs registerPushDevice and pushNotify: FCM send, App Check verify, ticket key secret."
ensure_account functions-deployer "Functions deployer (GitHub Actions)" \
  "Deploys Cloud Functions from deploy-functions.yml on main via Workload Identity Federation."

project_role "$RUNTIME" roles/firebasecloudmessaging.admin
project_role "$RUNTIME" roles/firebaseappcheck.tokenVerifier
secret_role "$RUNTIME" roles/secretmanager.secretAccessor

# What firebase-tools needs to deploy new public HTTPS functions:
# cloudfunctions.functions.setIamPolicy (Admin, not Developer), the Cloud Run
# invoker policy, the image cleanup policy, and API and secret checks.
for role in roles/cloudfunctions.admin roles/run.admin roles/artifactregistry.admin \
            roles/firebase.viewer roles/serviceusage.serviceUsageConsumer \
            roles/secretmanager.viewer; do
  project_role "$DEPLOYER" "$role"
done
# Read and, if ever missing, repair the runtime account's access to this one
# secret. It cannot read the secret's value.
secret_role "$DEPLOYER" roles/secretmanager.admin
# firebase-tools checks actAs on the App Engine default account before every
# deploy, and Cloud Build runs as the default compute account.
for account in "$RUNTIME" "$P@appspot.gserviceaccount.com" "$NUM-compute@developer.gserviceaccount.com"; do
  gcloud iam service-accounts add-iam-policy-binding "$account" --project "$P" \
    --member "serviceAccount:$DEPLOYER" --role roles/iam.serviceAccountUser --format=none
done

gcloud iam workload-identity-pools describe github --location global --project "$P" >/dev/null 2>&1 ||
  gcloud iam workload-identity-pools create github --location global --project "$P" \
    --display-name "GitHub Actions"
condition="assertion.repository_id == '$REPO_ID' && assertion.repository_owner_id == '$OWNER_ID'"
condition+=" && assertion.ref == 'refs/heads/main'"
condition+=" && assertion.workflow_ref.startsWith('depollsoft/MonkeySSH/.github/workflows/deploy-functions.yml@')"
mapping="google.subject=assertion.sub,attribute.repository_id=assertion.repository_id"
mapping+=",attribute.ref=assertion.ref,attribute.workflow_ref=assertion.workflow_ref"
if gcloud iam workload-identity-pools providers describe monkeyssh-functions \
    --workload-identity-pool github --location global --project "$P" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers update-oidc monkeyssh-functions \
    --workload-identity-pool github --location global --project "$P" \
    --attribute-mapping "$mapping" --attribute-condition "$condition"
else
  gcloud iam workload-identity-pools providers create-oidc monkeyssh-functions \
    --workload-identity-pool github --location global --project "$P" \
    --display-name "MonkeySSH functions deploy" \
    --issuer-uri https://token.actions.githubusercontent.com \
    --attribute-mapping "$mapping" --attribute-condition "$condition"
fi
gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER" --project "$P" \
  --member "principalSet://iam.googleapis.com/projects/$NUM/locations/global/workloadIdentityPools/github/attribute.repository_id/$REPO_ID" \
  --role roles/iam.workloadIdentityUser --format=none

echo "Done. The deploy workflow uses:"
echo "  provider: projects/$NUM/locations/global/workloadIdentityPools/github/providers/monkeyssh-functions"
echo "  account:  $DEPLOYER"
