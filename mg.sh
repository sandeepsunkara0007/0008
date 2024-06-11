#!/bin/bash

# Variables to set for your environment
CDF_INSTANCE_ID=ajay-data-fusion
CDF_REGION=us-west1
OUTPUT_FILE="pipeline_run_details.json"

# Initialize the output file with the opening bracket
echo "[" > $OUTPUT_FILE

# Get initial access token and URLs
AUTH_TOKEN=$(gcloud auth print-access-token)
if [[ -z "$AUTH_TOKEN" ]]; then
  echo "Failed to get auth token"
  exit 1
fi

CDAP_ENDPOINT=$(gcloud beta data-fusion instances describe \
    --location=${CDF_REGION} \
    --format="value(apiEndpoint)" \
    ${CDF_INSTANCE_ID})
if [[ -z "$CDAP_ENDPOINT" ]]; then
  echo "Failed to get CDAP endpoint"
  exit 1
fi

# Get the list of pipelines
PIPELINE_DETAILS=$(curl -s -X GET \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        "${CDAP_ENDPOINT}/v3/namespaces/default/apps?artifactName=cdap-data-pipeline" \
        | jq -r '.[].name')

if [[ -z "$PIPELINE_DETAILS" ]]; then
  echo "No pipelines found or failed to get pipeline details"
  exit 1
fi

index=0

for PIPELINE in ${PIPELINE_DETAILS}
do
    CDF_PIPELINE=${PIPELINE}

    # Get the latest run ID for the current pipeline
    LATEST_RUN_ID=$(curl -s -X GET \
            -H "Authorization: Bearer ${AUTH_TOKEN}" \
            "${CDAP_ENDPOINT}/v3/namespaces/default/apps/${CDF_PIPELINE}/workflows/DataPipelineWorkflow/runs" \
            | jq -r '.[0].runid')

    if [ -n "${LATEST_RUN_ID}" ]; then
        # Get the run details for the latest run
        RUN_DETAILS=$(curl -s -X GET \
                -H "Authorization: Bearer ${AUTH_TOKEN}" \
                "${CDAP_ENDPOINT}/v3/namespaces/default/apps/${CDF_PIPELINE}/workflows/DataPipelineWorkflow/runs/${LATEST_RUN_ID}" \
                | jq -r '{runid, starting, start, end, status, profileName: .profile.profileName, namespace: .profile.namespace}')

        if [[ -z "$RUN_DETAILS" ]]; then
            echo "Failed to get run details for pipeline: ${CDF_PIPELINE}, run ID: ${LATEST_RUN_ID}"
            continue
        fi

        # Get error logs for the latest run
        ERROR_LOGS=$(curl -s -X GET \
                -H "Authorization: Bearer ${AUTH_TOKEN}" \
                "${CDAP_ENDPOINT}/v3/namespaces/default/apps/${CDF_PIPELINE}/workflows/DataPipelineWorkflow/runs/${LATEST_RUN_ID}/logs?format=json" \
                | jq -r '[.[] | select(.log.logLevel == "ERROR") | .log.message]')

        # Extract individual details
        RUN_ID=$(echo ${RUN_DETAILS} | jq -r '.runid')
        STARTING=$(echo ${RUN_DETAILS} | jq -r '.starting')
        START=$(echo ${RUN_DETAILS} | jq -r '.start')
        END=$(echo ${RUN_DETAILS} | jq -r '.end')
        STATUS=$(echo ${RUN_DETAILS} | jq -r '.status')
        PROFILE_NAME=$(echo ${RUN_DETAILS} | jq -r '.profileName')
        NAMESPACE=$(echo ${RUN_DETAILS} | jq -r '.namespace')

        # Convert epoch time to formatted date
        STARTING_TIME=$(date --date=@${STARTING} +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null)
        START_TIME=$(date --date=@${START} +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null)
        END_TIME=$(date --date=@${END} +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null)

        # Format the details as JSON
        RUN_DETAILS_JSON=$(jq -c -n \
            --arg index "$index" --arg profileName "$PROFILE_NAME" --arg namespace "$NAMESPACE" --arg pipeline "$CDF_PIPELINE" --arg runId "$RUN_ID" --arg starting "$STARTING_TIME" --arg start "$START_TIME" --arg end "$END_TIME" --arg status "$STATUS" --argjson errorLogs "$ERROR_LOGS" \
            '{index: $index, profileName: $profileName, namespace: $namespace, pipeline: $pipeline, runId: $runId, starting: $starting, start: $start, end: $end, status: $status, errorLogs: $errorLogs}')

        # Append the JSON to the output file
        echo "$RUN_DETAILS_JSON," >> $OUTPUT_FILE
    else
        echo "Pipeline: ${CDF_PIPELINE}, No Runs Found"
    fi

    # Increment index for the next pipeline
    index=$((index + 1))
done

# Replace the last comma with the closing bracket
sed -i '$ s/,$/]/' $OUTPUT_FILE

echo "Pipeline run details written to ${OUTPUT_FILE}"

