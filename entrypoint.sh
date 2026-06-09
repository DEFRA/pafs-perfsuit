#!/bin/sh
set -x

echo "run_id: $RUN_ID in $ENVIRONMENT"

NOW=$(date +"%Y%m%d-%H%M%S")

if [ -z "${JM_HOME}" ]; then
  JM_HOME=/opt/perftest
fi

JM_SCENARIOS=${JM_HOME}/scenarios
JM_PROFILES=${JM_HOME}/profiles
JM_REPORTS=${JM_HOME}/reports
JM_LOGS=${JM_HOME}/logs

mkdir -p ${JM_REPORTS} ${JM_LOGS}

# ---------------------------------------------------------------------------
# Profile-based load configuration
#
# Set the PROFILE env var in the CDP Portal at run time to select a load
# profile without rebuilding the Docker image:
#
#   smoke     — 1 user/scenario, ~5 min  (quick sanity check)
#   peak_60   — 60 concurrent users, ~75 min  (standard peak load)
#   peak_75   — 75 concurrent users, ~75 min  (stretch peak load)
#   soak      — 30 users, ~4 hours  (endurance / overnight)
#
# When PROFILE is set the corresponding profiles/<PROFILE>.properties file is
# passed to JMeter via -q, which overrides the thread-group defaults embedded
# in the JMX (s01.threads, s02.threads, etc.).
#
# If PROFILE is not set, test.jmx runs with 1 thread per scenario (~5 min).
# ---------------------------------------------------------------------------
PROFILE_OPTS=""
if [ -n "${PROFILE}" ]; then
  PROFILE_FILE="${JM_PROFILES}/${PROFILE}.properties"
  if [ -f "${PROFILE_FILE}" ]; then
    echo "Using load profile: ${PROFILE} (${PROFILE_FILE})"
    PROFILE_OPTS="-q ${PROFILE_FILE}"
    # Select the matching JMX unless the caller has already set TEST_SCENARIO
    if [ -z "${TEST_SCENARIO}" ]; then
      case "${PROFILE}" in
        peak_75) TEST_SCENARIO=PAFS_PeakLoadTest_75Users ;;
        *)       TEST_SCENARIO=PAFS_PeakLoadTest_60Users ;;
      esac
    fi
  else
    echo "WARNING: Profile '${PROFILE}' not found at ${PROFILE_FILE} — falling back to JMX defaults"
  fi
fi

TEST_SCENARIO=${TEST_SCENARIO:-test}
SCENARIOFILE=${JM_SCENARIOS}/${TEST_SCENARIO}.jmx
REPORTFILE=${NOW}-perftest-${TEST_SCENARIO}-${PROFILE:-default}-report.csv
LOGFILE=${JM_LOGS}/perftest-${TEST_SCENARIO}.log

# Before running the suite, replace 'service-name' with the name/url of the service to test.
# ENVIRONMENT is set to the name of the environment the test is running in.
SERVICE_ENDPOINT=${SERVICE_ENDPOINT:-service-name.${ENVIRONMENT}.cdp-int.defra.cloud}
# PORT is used to set the port of this performance test container
SERVICE_PORT=${SERVICE_PORT:-443}
SERVICE_URL_SCHEME=${SERVICE_URL_SCHEME:-https}

# Run the test suite
# shellcheck disable=SC2086  — intentional word-splitting for PROFILE_OPTS
jmeter -n -t ${SCENARIOFILE} -e -l "${REPORTFILE}" -o ${JM_REPORTS} -j ${LOGFILE} -f \
  ${PROFILE_OPTS} \
  -Jenv="${ENVIRONMENT}" \
  -Jdomain="${SERVICE_ENDPOINT}" \
  -Jport="${SERVICE_PORT}" \
  -Jprotocol="${SERVICE_URL_SCHEME}"

test_exit_code=$?

# Publish the results into S3 so they can be displayed in the CDP Portal
if [ -n "$RESULTS_OUTPUT_S3_PATH" ]; then
  # Copy the CSV report file and the generated report files to the S3 bucket
   if [ -f "$JM_REPORTS/index.html" ]; then
      aws --endpoint-url=$S3_ENDPOINT s3 cp "$REPORTFILE" "$RESULTS_OUTPUT_S3_PATH/$REPORTFILE"
      aws --endpoint-url=$S3_ENDPOINT s3 cp "$JM_REPORTS" "$RESULTS_OUTPUT_S3_PATH" --recursive
      if [ $? -eq 0 ]; then
        echo "CSV report file and test results published to $RESULTS_OUTPUT_S3_PATH"
      fi
   else
      echo "$JM_REPORTS/index.html is not found"
      exit 1
   fi
else
   echo "RESULTS_OUTPUT_S3_PATH is not set"
   exit 1
fi

exit $test_exit_code
