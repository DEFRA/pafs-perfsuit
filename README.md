# pafs-perfsuit

JMeter-based performance test suite for the PAFS (Project Application and Funding Service) portal, designed to run on the CDP (Core Delivery Platform).

- [Scenarios](#scenarios)
- [Think Times](#think-times)
- [Load Profiles](#load-profiles)
- [Test Data](#test-data)
  - [What data is needed](#what-data-is-needed)
  - [Data files in this repo](#data-files-in-this-repo)
  - [How to prepare data in the perf-test environment](#how-to-prepare-data-in-the-perf-test-environment)
- [Running from the CDP Portal](#running-from-the-cdp-portal)
- [Running locally with Docker Compose](#running-locally-with-docker-compose)
- [Running locally with LocalStack](#running-locally-with-localstack)
- [Environment variables](#environment-variables)
- [Build and publish](#build-and-publish)
- [Licence](#licence)

---

## Scenarios

The suite contains four thread groups, each representing a distinct user journey. All groups run concurrently against the same target environment.

| Scenario | Description |
|---|---|
| **S01 - Create New Proposal** | An RMA user logs in, creates a brand-new PAF proposal and completes the multi-step form through to submission. This is the most write-intensive journey. |
| **S02 - Existing Proposal** | An RMA user logs in and navigates through an existing project (browse summary pages, review answers). This represents the majority of day-to-day usage and carries 90% of the virtual user load. |
| **S03 - Auto User Creation** | An admin user logs in and approves a new RMA account via the auto-approval flow. |
| **S04 - General User Creation** | An admin user logs in and manually creates a new general user account. |

**JMX files:**

| File | Purpose |
|---|---|
| `PAFS_PeakLoadTest_60Users.jmx` | Primary load test — used by `peak_60` (default) |
| `PAFS_PeakLoadTest_75Users.jmx` | Stretch/stress load test — used by `peak_75` and `peak_165` |
| `PAFS_SingleUserTest.jmx` | Single-user trace for manual script debugging |
| `test.jmx` | Single-user baseline used for script validation |

---

## Think Times

A think time (pause) is applied between every transaction to simulate realistic user behaviour - the time a user spends reading a page before interacting.

| Property | Default | Description |
|---|---|---|
| `think_time` | `10000` ms (10 s) | Pause between each page-level transaction, applied across all scenarios |

The 10 s default reflects a realistic reading and interaction time for a form-heavy GOV.UK service. It can be overridden per profile (the `smoke` profile uses 2 s to allow faster script iteration).

There is also a fixed **5.5 minute pause** (330,000 ms) at the end of the S01 proposal-creation loop. This simulates the real-world gap between a user completing one proposal and starting another. It is intentional and not controlled by `think_time`.

---

## Load Profiles

Load profiles allow you to change the number of virtual users, ramp time, and test duration **at run time from the CDP Portal** without rebuilding the Docker image. Set the `PROFILE` environment variable when starting a test run.

### Profile summary

| Profile | Total users | Think time | Steady state | Approximate total run | Use case |
|---|---|---|---|---|---|
| `smoke` | 4 (1 per scenario) | 2 s | 5 min | ~6 min | Quick script sanity check |
| `peak_60` | **60** | 10 s | 60 min | ~70 min | Standard peak load — validates capacity NFR (NF_CP_1) |
| `peak_75` | **75** | 10 s | 60 min | ~72 min | Stretch peak — above-capacity stress test |
| `peak_165` | **165** | 10 s | 60 min | ~87 min | Capacity-ceiling stress test — requires `POSTGRES_POOL_MAX=100` |
| `soak` | 30 | 10 s | 4 hours | ~4 hr 5 min | Overnight endurance — detects memory leaks and connection pool exhaustion |

### User distribution within each peak profile

S02 starts immediately and carries the bulk of the load. S01, S03, and S04 are delayed to start after S02 has fully ramped, so the system is already under realistic concurrent load when the write-heavy and admin journeys begin.

| Scenario | peak_60 | peak_75 | peak_165 | Ramp rate | Start delay |
|---|---|---|---|---|---|
| S01 - Create New Proposal | 3 | 4 | 9 | 10 s / user | After S02 fully ramped |
| S02 - Existing Proposal | 54 | 67 | 148 | 10 s / user | Immediately (t=0) |
| S03 - Auto User Creation | 2 | 2 | 4 | 10 s / user | After S02 fully ramped |
| S04 - General User Creation | 2 | 2 | 4 | 10 s / user | After S02 fully ramped |

### How to select a profile from the CDP Portal

1. Go to **Test Suites** in the [CDP Portal](https://portal.cdp-int.defra.cloud/test-suites)
2. Select `pafs-perfsuit`
3. Press **Run** and choose the `perf-test` environment
4. Under **Profile**, press **Yes** and enter one of: `smoke`, `peak_60`, `peak_75`, `peak_165`, `soak`
5. Press **Start**

No code change or Docker rebuild is needed.

### Profile configuration files

Each profile is a Java properties file in `profiles/`. Edit a file here and rebuild the image to permanently change a profile's settings.

```
profiles/
  smoke.properties
  peak_60.properties
  peak_75.properties
  peak_165.properties
  soak.properties
```

Each file controls the following properties:

```properties
# Think time between transactions (ms)
think_time=10000

# S01 thread group
s01.threads=3       # number of virtual users
s01.ramp=30         # ramp-up period in seconds
s01.duration=3630   # total duration = ramp + steady state (seconds)
s01.delay=540       # startup delay in seconds

# S02, S03, S04 follow the same pattern
s02.threads=54
s02.ramp=540
s02.duration=4140
s02.delay=0
```

---

## Test Data

### What data is needed

**You cannot run a meaningful load test without first preparing data in the target environment.** The test scripts authenticate as real users and navigate to real project reference numbers. If accounts or projects do not exist the JMeter response assertions will fail.

| Data item | Used by | Minimum rows needed | Notes |
|---|---|---|---|
| Regular user accounts (`perfuser*@yopmail.com`) | S01, S02 | 320 (20 + 300) | Non-admin RMA users, `admin = false`, `disabled = false`. Sized for `peak_165`; all lighter profiles use a subset. |
| Admin user accounts (`perfadmin*@yopmail.com`) | S03, S04 | 20 (10 + 10) | `admin = true`, `disabled = false` |
| Existing projects | S02 | 300 | Projects with reference numbers from `S02_ProjectNames.csv`, owned by S02 users, seeded with `project_type`, `earliest_start_year`, and `project_end_financial_year` |

### Data files in this repo

All CSV files live in `scenarios/` and are baked into the Docker image at build time. JMeter recycles rows when threads outnumber CSV rows (`shareMode=all`, `recycle=true`).

| File | Rows | Contents |
|---|---|---|
| `S01_Credentials.csv` | 20 | `email,password` — regular RMA users for S01 |
| `S02_Credentials.csv` | 300 | `email,password` — regular RMA users for S02 |
| `S02_ProjectNames.csv` | 300 | Project slugs (e.g. `NWC501E-432A-001A`) generated per `RUN_ID` for S02 to browse |
| `S03_Credentials.csv` | 10 | `email,password` — admin users for S03 |
| `S04_Credentials.csv` | 10 | `email,password` — admin users for S04 |

All accounts use the password `Password123!`. The bcrypt hash (12 rounds) is:

```
$2b$12$J80EQtXP5gH/JTz1pD2KfekstXaS9W2wpnBNK/ekXi6HJEvaWgBMa
```

This is the same hash format used by `seed-dev-users.sql` in the `pafs-backend-api` repository.

> If you see session conflicts during a run (a thread is redirected to `/login` mid-journey because another thread sharing the same account logged it out), add more unique rows to the relevant CSV file and rebuild the image.

### How to prepare data in the perf-test environment

#### Step 1 - Seed user accounts

Connect to the `pafs_backend_api` database in the `perf-test` environment (via the CDP Terminal or `psql`) and insert all users from the four credential CSVs.

Use the pattern from `seed-dev-users.sql` in `pafs-backend-api`. A minimal example for one regular user:

```sql
INSERT INTO pafs_core_users (
    email, encrypted_password, first_name, last_name,
    job_title, admin, disabled, sign_in_count, failed_attempts,
    created_at, updated_at
) VALUES (
    'perfuser119@yopmail.com',
    '$2b$12$J80EQtXP5gH/JTz1pD2KfekstXaS9W2wpnBNK/ekXi6HJEvaWgBMa',
    'Perf', 'User', 'RMA', false, false, 0, 0,
    CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
);
```

For admin users (S03, S04) set `admin = true`.

Generate a `seed-perf-users.sql` script that bulk-inserts all rows from all four CSV files and run it once per environment. Use `ON CONFLICT (email) DO NOTHING` to make it idempotent:

```sql
INSERT INTO pafs_core_users (email, encrypted_password, ...)
VALUES (...)
ON CONFLICT (email) DO NOTHING;
```

#### Step 2 - Seed existing projects for S02

S02 navigates to existing projects by reference number. Each reference number in `S02_ProjectNames.csv` must exist in the database and be accessible by one of the S02 users.

The 87 reference numbers follow the pattern `NWC501E-001A-XXXA` (area code `NWC501E`).

Options for creating the project data:

1. **Manual creation (recommended first time):** Log into the portal as an S02 user in `perf-test` and submit real proposals. Record the generated reference numbers, update `S02_ProjectNames.csv` in this repo, and rebuild the image.

2. **SQL seed:** Insert rows directly into `pafs_core_projects` (and all linked tables) using the reference numbers already in `S02_ProjectNames.csv`. Each project must have a valid `area_id` that belongs to one of the S02 users and must be in a state the user can view.

#### Step 3 - Verify with a smoke run before full load

Before running `peak_60` or `peak_75`, always run `smoke` first:

1. Run with `PROFILE=smoke` from the CDP Portal
2. Open the HTML report when the run completes
3. All transactions should show HTTP 200 with `PASS` assertions

**Common failures and causes:**

| Symptom | Cause |
|---|---|
| HTTP 401 on login | User account does not exist or password hash is incorrect |
| HTTP 302 redirect to `/login` mid-journey | Session invalidated - another thread sharing the same account logged it out; add more unique rows to the CSV |
| HTTP 404 on project page | Project reference number does not exist in the database |
| HTTP 403 on project page | User does not have permission to view the project (area_id mismatch) |

---

## Service Level Agreement (SLA)

All performance profiles must meet the following NFRs under steady-state load:

| NFR | Target | Metric |
|---|---|---|
| Page response time (95th percentile) | **≤ 2 s** | All page-level transactions under `peak_60` and `peak_75` |
| Page response time (99th percentile) | **≤ 4 s** | Tail latency under `peak_60` and `peak_75` |
| Error rate | **< 1%** | HTTP 4xx/5xx across all transactions in steady state |
| Login transaction time (95th pct) | **≤ 2 s** | S01/S02 `/login` POST |
| Dashboard load (95th pct) | **≤ 2 s** | `/` GET after login |
| Project overview (95th pct) | **≤ 2 s** | `/project/{ref}` GET |
| Form step save (95th pct) | **≤ 2 s** | Any `/project/{ref}/*` POST |
| Submit proposal (95th pct) | **≤ 2 s** | `/project/{ref}/submit` POST |
| Throughput consistency | No step-down in requests/sec during steady state | Indicates no memory leak |

For `peak_165` (capacity-ceiling test), the SLA threshold relaxes to **≤ 3 s at 95th percentile** — this profile intentionally operates above rated capacity to locate the breaking point.

---

## Running from the CDP Portal

This is the primary way to run load tests against the `perf-test` environment.

1. Commit changes to `main` - GitHub Actions builds and publishes a new Docker image automatically
2. Confirm the build completed from the `Actions` tab in GitHub
3. Go to [CDP Portal - Test Suites](https://portal.cdp-int.defra.cloud/test-suites)
4. Select `pafs-perfsuit`
5. Choose the `perf-test` environment
6. Optionally set a **Profile** value (`smoke`, `peak_60`, `peak_75`, `peak_165`, `soak`)
7. Press **Run**
8. When the run completes the portal shows pass/fail status and a link to the HTML report

> The CDP Platform enforces a **2-hour maximum run time**. The `soak` profile (4 hours) will be terminated at the 2-hour mark. Contact the CDP team if extended soak runs are required.

---

## Running locally with Docker Compose

Use this to develop and verify test scripts before pushing to `main`.

### Prerequisites

- Docker
- `pafs-portal-frontend` Docker image available locally or as a published tag

### Steps

```bash
# Build the test image
docker compose build --no-cache development

# Start the full stack (LocalStack + Redis + service + tests)
docker compose up --build
```

Once `localstack` and `service` are healthy the `development` container starts and runs the tests automatically. Reports are written to `./reports/` on your host.

### Configure the target service

In `compose.yml`, replace `service-name` with the actual image name:

```yaml
service:
  image: defradigital/pafs-portal-frontend:${SERVICE_VERSION:-latest}
```

The service must expose a `/health` endpoint on port `3000`.

### Run a specific profile locally

```bash
docker compose run --rm \
  -e PROFILE=smoke \
  -e TEST_SCENARIO=PAFS_PeakLoadTest_60Users \
  development
```

---

## Running locally with LocalStack

Use this when you want to run a single test container without the full Compose stack.

```bash
# 1. Build the test image
docker build . -t pafs-perftest

# 2. Start LocalStack and create the results bucket
docker run -d -p 4566:4566 localstack/localstack:4.3.0
aws --endpoint-url=http://localhost:4566 s3 mb s3://test-results

# 3. Run the tests
docker run \
  -e S3_ENDPOINT='http://host.docker.internal:4566' \
  -e RESULTS_OUTPUT_S3_PATH='s3://test-results' \
  -e AWS_ACCESS_KEY_ID='test' \
  -e AWS_SECRET_ACCESS_KEY='test' \
  -e AWS_REGION='eu-west-2' \
  -e ENVIRONMENT='local' \
  -e SERVICE_ENDPOINT='host.docker.internal' \
  -e SERVICE_PORT='3000' \
  -e SERVICE_URL_SCHEME='http' \
  -e TEST_SCENARIO='PAFS_PeakLoadTest_60Users' \
  -e PROFILE='smoke' \
  pafs-perftest
```

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `ENVIRONMENT` | _(required)_ | Target environment name (`perf-test`, `local`). Set automatically by CDP. Used in logs and passed to JMeter as `-Jenv`. |
| `PROFILE` | _(unset)_ | Load profile name. One of `smoke`, `peak_60`, `peak_75`, `peak_165`, `soak`. Loads `profiles/<PROFILE>.properties` via JMeter's `-q` flag. If unset, JMX-embedded defaults apply (equivalent to `peak_60`). |
| `TEST_SCENARIO` | `test` | JMX file name without extension. When a `PROFILE` is set this defaults to `PAFS_PeakLoadTest_60Users`. |
| `SERVICE_ENDPOINT` | `service-name.<ENVIRONMENT>.cdp-int.defra.cloud` | Hostname of the service under test. |
| `SERVICE_PORT` | `443` | Port of the service under test. |
| `SERVICE_URL_SCHEME` | `https` | Protocol (`https` on CDP, `http` locally). |
| `S3_ENDPOINT` | `https://s3.eu-west-2.amazonaws.com` | S3 endpoint for publishing results. Override with LocalStack URL for local runs. |
| `RESULTS_OUTPUT_S3_PATH` | _(required)_ | S3 path where test results are uploaded. Set automatically by CDP. Without this the run exits with an error. |
| `RUN_ID` | _(set by CDP)_ | Unique run identifier included in log output. |

### JMeter properties (set via profile files)

These override the hardcoded defaults in the JMX `${__P(name,default)}` expressions.

| Property | peak_60 | peak_75 | peak_165 | Description |
|---|---|---|---|---|
| `think_time` | `10000` | `10000` | `10000` | Think time in ms between transactions |
| `s01.threads` | `3` | `4` | `9` | Virtual users for S01 |
| `s01.ramp` | `30` | `40` | `90` | Ramp-up time in seconds |
| `s01.duration` | `3630` | `3640` | `3690` | Total group duration (ramp + 3600 s steady state) |
| `s01.delay` | `540` | `670` | `1480` | Startup delay — waits for S02 to fully load |
| `s02.threads` | `54` | `67` | `148` | Virtual users for S02 |
| `s02.ramp` | `540` | `670` | `1480` | Ramp-up time in seconds (10 s/user) |
| `s02.duration` | `4140` | `4270` | `5080` | Total group duration (ramp + 3600 s steady state) |
| `s02.delay` | `0` | `0` | `0` | No delay — S02 starts immediately |
| `s03.threads` | `2` | `2` | `4` | Virtual users for S03 |
| `s03.ramp` | `20` | `20` | `20` | Ramp-up time in seconds |
| `s03.duration` | `3620` | `3620` | `3620` | Total group duration |
| `s03.delay` | `570` | `710` | `1570` | Startup delay in seconds |
| `s04.threads` | `2` | `2` | `4` | Virtual users for S04 |
| `s04.ramp` | `20` | `20` | `20` | Ramp-up time in seconds |
| `s04.duration` | `3620` | `3620` | `3620` | Total group duration |
| `s04.delay` | `600` | `730` | `1590` | Startup delay in seconds |

---

## Build and publish

The [.github/workflows/publish.yml](.github/workflows/publish.yml) GitHub Actions workflow builds and publishes a new Docker image on every push to `main`.

The CDP Portal always runs the **latest published image**. Check the `Actions` tab in GitHub to confirm the build succeeded before starting a test run from the portal.

To force a rebuild without a code change, re-run the latest `Publish` workflow from the GitHub Actions tab.

---

## Licence

THIS INFORMATION IS LICENSED UNDER THE CONDITIONS OF THE OPEN GOVERNMENT LICENCE found at:

<http://www.nationalarchives.gov.uk/doc/open-government-licence/version/3>

The following attribution statement MUST be cited in your products and applications when using this information.

> Contains public sector information licensed under the Open Government licence v3
