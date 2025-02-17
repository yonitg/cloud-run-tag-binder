#!/bin/sh
# Copyright 2022 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

PROJECT_ID=[FUNCTION_PROJECT_ID]
FOLDER_ID=[INSPECTED_FOLDER_ID]
TEST_PROJECT_ID=[TEST_PROJECT_ID]
#TAG_VALUE=tagValues/[TAG_VALUE_ID]
REGION=[RESOURCE_REGION]

FUNCTION_SERVICE_ACCOUNT=cloud-run-tag-binder@$PROJECT_ID.iam.gserviceaccount.com
SINK_NAME=cloud-run-create-service-sink
TAG_NAME=AllowPublicAccess

PROJECT_NUMBER=`gcloud projects describe $PROJECT_ID --format="value(projectNumber)"`
ORG_ID=`gcloud projects get-ancestors $PROJECT_ID | grep organization | cut -f1 -d' '`
TRIGGER_SERVICE_ACCOUNT=$PROJECT_NUMBER-compute@developer.gserviceaccount.com

gcloud services enable \
  cloudresourcemanager.googleapis.com \
  artifactregistry.googleapis.com \
  cloudfunctions.googleapis.com \
  run.googleapis.com logging.googleapis.com \
  cloudbuild.googleapis.com \
  pubsub.googleapis.com \
  eventarc.googleapis.com \
  orgpolicy.googleapis.com \
  --project $PROJECT_ID

gcloud resource-manager tags keys create $TAG_NAME \
  --parent=organizations/$ORG_ID

gcloud resource-manager tags values create true \
  --parent=$ORG_ID/$TAG_NAME

TAG_VALUE=`gcloud resource-manager tags values describe $ORG_ID/$TAG_NAME/true \
  --format="value(name)"`

tee allowPublicAccessPolicy.json <<EOF
{
  "name": "folders/$FOLDER_ID/policies/iam.allowedPolicyMemberDomains",
  "spec": {
    "inheritFromParent": true,
    "rules": [
      {
        "allowAll": true,
        "condition": {
          "expression": "resource.matchTag(\"$ORG_ID/$TAG_NAME\", \"true\")",
          "title": "allow"
        }
      }
    ]
  }
}
EOF

gcloud org-policies set-policy allowPublicAccessPolicy.json

gcloud iam service-accounts create cloud-run-tag-binder \
  --display-name="Service account with permissions to bind tag value to Cloud Run services" \
  --project=$PROJECT_ID

gcloud iam roles create runTagBinder \
  --organization=$ORG_ID \
  --title="Cloud Run Tag Binder" \
  --stage=GA \
  --description="Have access to create tag bindings for cloud run services" \
  --permissions=run.services.createTagBinding

gcloud resource-manager tags values add-iam-policy-binding $TAG_VALUE \
  --member="serviceAccount:${FUNCTION_SERVICE_ACCOUNT}" \
  --role='roles/resourcemanager.tagUser'

gcloud organizations add-iam-policy-binding $ORG_ID \
  --member="serviceAccount:${FUNCTION_SERVICE_ACCOUNT}" \
  --role="organizations/$ORG_ID/roles/runTagBinder"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${TRIGGER_SERVICE_ACCOUNT}" \
  --role='roles/eventarc.eventReceiver'

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role='roles/iam.serviceAccountTokenCreator'

# Sink to Log bucket
# SINK_LOG_BUCKET=logs-bucket
# SINK_DESTINATION=logging.googleapis.com/projects/$PROJECT_ID/locations/$REGION/buckets/$SINK_LOG_BUCKET

# gcloud logging buckets create $SINK_LOG_BUCKET \
#   --location=$REGION \
#   --project=$PROJECT_ID

# Sink to PubSub
SINK_TOPIC=cloud-run-logs
SINK_DESTINATION=pubsub.googleapis.com/projects/$PROJECT_ID/topics/$SINK_TOPIC

gcloud pubsub topics create $SINK_TOPIC \
  --project $PROJECT_ID

# Create sink
gcloud logging sinks create $SINK_NAME \
  $SINK_DESTINATION \
  --description="Cloud Run Create Service sink" \
  --include-children \
  --folder=$FOLDER_ID \
  --log-filter='LOG_ID("cloudaudit.googleapis.com/activity") AND
protoPayload.methodName="google.cloud.run.v1.Services.CreateService" AND
resource.type="cloud_run_revision"'

SINK_IDENTITY=`gcloud logging sinks describe $SINK_NAME \
  --folder ${FOLDER_ID} \
  --format="value(writerIdentity)"`

# If Sink is log bucket
# gcloud projects add-iam-policy-binding $PROJECT_ID \
#   --member=$SINK_IDENTITY \
#   --role='roles/logging.bucketWriter' \
#   --condition=expression="resource.name.endsWith('buckets/$SINK_LOG_BUCKET')",title="filter bucket"

# gcloud functions deploy cloud-run-service-tag-binder \
# --gen2 \
# --runtime=nodejs16 \
# --region=$REGION \
# --source=. \
# --entry-point=cloudRunServiceCreatedEvent \
# --set-env-vars TAG_VALUE=$TAG_VALUE \
# --run-service-account=$FUNCTION_SERVICE_ACCOUNT \
# --trigger-location=$REGION \
# --trigger-event-filters="type=google.cloud.audit.log.v1.written" \
# --trigger-event-filters="serviceName=run.googleapis.com" \
# --trigger-event-filters="methodName=google.cloud.run.v1.Services.CreateService" \
# --trigger-service-account=$TRIGGER_SERVICE_ACCOUNT \
# --project=$PROJECT_ID \
# --quiet #\
# #--set-env-vars DEBUG="true" 

# If Sink is pubsub
gcloud pubsub topics add-iam-policy-binding $SINK_TOPIC \
  --member=$SINK_IDENTITY \
  --role='roles/pubsub.publisher' \
  --project=$PROJECT_ID

gcloud functions deploy cloud-run-service-tag-binder \
--gen2 \
--runtime=nodejs16 \
--region=$REGION \
--source=. \
--entry-point=cloudRunServiceCreatedEvent \
--set-env-vars TAG_VALUE=$TAG_VALUE \
--run-service-account=$FUNCTION_SERVICE_ACCOUNT \
--trigger-topic=$SINK_TOPIC \
--trigger-service-account=$TRIGGER_SERVICE_ACCOUNT \
--project=$PROJECT_ID \
--quiet
#--set-env-vars DEBUG="true" \

gcloud run deploy hello \
  --image us-docker.pkg.dev/cloudrun/container/hello@sha256:2e70803dbc92a7bffcee3af54b5d264b23a6096f304f00d63b7d1e177e40986c \
  --region $REGION \
  --allow-unauthenticated \
  --project $TEST_PROJECT_ID
