# Anna University: AI-Powered Question Paper Generation (AWS)

Event-driven textbook ingestion plus retrieval-augmented question generation. Faculty pick an indexed textbook, subject, units, difficulty and question count; the system returns a syllabus-aligned, source-traceable question paper (DOCX, JSON, optional answer key) for human review. This repository holds the application code, the Terraform that builds it, and the GitHub Actions pipeline that deploys it. Place this file at the repository root.

This is a reference sample: it shows how a project of this kind is structured, deployed and operated, so junior developers can follow the same shape in their own work.

## Architecture, mapped to the diagram

| Diagram area | Where it lives |
|---|---|
| 01 Ingestion: S3, EventBridge, SQS queue and DLQ, Lambda coordinator, extraction, chunking, embeddings | `infra/storage.tf`, `infra/messaging.tf`, `src/ingest/`, `src/common/chunking.py`, `src/common/documents.py` |
| 02 Shared data: processed and intermediate S3, DynamoDB registry, OpenSearch dual indexes | `infra/storage.tf`, `infra/data.tf`, `src/common/registry.py`, `src/common/search.py` |
| 03 RAG generation: API Gateway, job controller, retrieval, prompt builder, Bedrock, quality gates, delivery | `infra/api.tf`, `src/api/`, `src/generate/`, `src/common/quality.py` |
| 04 Security and operations: CloudWatch, X-Ray, CloudTrail, IAM, KMS, VPC endpoints, WAF, Cognito, DLQ, idempotency, reprocessing | `infra/main.tf`, `network.tf`, `auth.tf`, `api.tf`, `monitoring.tf`, API reprocess route |
| Web application: CloudFront and S3 static UI | `infra/storage.tf` (hosting and runtime `config.json`) |
| Step Functions (optional), Secrets Manager | Not used. SQS plus Lambda covers the orchestration, and no secret exists: access is by IAM role |

Scope: the UI source and PDF export are outside this repository (output is DOCX and JSON). OpenSearch has no fine-grained access control; access is limited by the VPC, a security group and a resource policy that names the Lambda roles.

## Repository layout

```
.github/workflows/terraform.yml   test, validate, scan, plan, approve, apply, smoke test
.github/dependabot.yml            weekly updates for actions, Terraform and test dependencies
bootstrap/                        one-time: state bucket and GitHub OIDC deploy roles (run by an administrator)
infra/                            the stack; modules/lambda_function builds each function, role and alias
src/api, src/ingest, src/generate, src/common     one package, three handlers
tests/                            unit tests, no AWS access needed
```

## How it works

Ingestion: an administrator registers a textbook (`POST /textbooks`) with its units and page ranges and gets a presigned S3 upload form. S3 sends the upload to EventBridge, which queues it. The ingest Lambda validates the real file type (magic bytes, size), claims the S3 object version in DynamoDB (idempotency), extracts text (DOCX parser, or Textract OCR for PDF), strips running headers, chunks by unit and page, embeds with Titan, and bulk-indexes in OpenSearch. Status runs `PENDING_UPLOAD → UPLOADED → PROCESSING → COMPLETED / FAILED` with an error code. Only COMPLETED versions are selectable or searched.

Generation: `POST /question-papers` validates the five inputs against the COMPLETED textbook, records a job and returns a job id (202). The generate Lambda retrieves passages per selected unit (BM25 plus vector, merged), builds a grounded prompt, asks Claude for one question per slot through a tool call, then applies the quality gates: count, empty text, exact duplicate, subject, unit, difficulty, every question cites a retrieved passage, exact repeat of an earlier accepted question, near-duplicate inside the paper and against the question bank. Rejected slots are regenerated, at most 3 rounds in all; if gaps remain the job fails with `QUALITY_GATE_FAILED` and nothing is delivered. Accepted papers are written to S3 and their questions are remembered. The client polls `GET /question-papers/{job_id}` for presigned downloads.

| Route | Who | Purpose |
|---|---|---|
| `GET /health` | public | liveness |
| `POST /textbooks`, `POST /textbooks/{id}/{version}/reprocess` | administrator | register and upload; re-index a version |
| `GET /textbooks`, `GET /textbooks/{id}/{version}` | faculty, administrator | list and status |
| `POST /question-papers` (optional `Idempotency-Key`, `X-Correlation-Id`), `GET /question-papers`, `GET /question-papers/{job_id}` | faculty, administrator | request and download; jobs are private to their owner and administrators |

Request fields: `textbook_id`, `version`, `subject`, `units`, `difficulty` (Easy, Medium, Hard, Mixed), `count` (1-100), optional `sections` (name, count, marks; counts must add up), `include_answer_key`, `formats` (docx, json).

## Deploying from the private GitHub repository

1. Create the private repository and push this tree. Set `github_repository` in `bootstrap/variables.tf` to the repository's `owner/name` (the default is an example name); the deploy roles trust only that repository.
2. An administrator runs the one-time stack from a workstation: `cd bootstrap && terraform init && terraform apply -var github_repository=<owner/name>`. Add `-var create_opensearch_service_linked_role=true` if the account has never had a VPC OpenSearch domain, and `-var create_github_oidc_provider=false` if it already has the GitHub provider. Keep its state safe; it changes rarely.
3. Set the GitHub variables the output `github_setup` prints (`AWS_REGION`, `TF_STATE_BUCKET`, `AWS_PLAN_ROLE_ARN`, `ALERT_EMAIL`), create the `dev` and `prod` environments, set `AWS_APPLY_ROLE_ARN` in each, and add required reviewers to `prod`. No AWS key is stored in GitHub.
4. Open a pull request: tests, format, validate and an IaC scan run, then the dev and prod plans appear in the job summary. Review them. Merging to `main` applies dev, then waits for prod approval, applies the same saved plan, and smoke-tests `/health` and that the API refuses requests without a token.
5. After the first apply: create users in the Cognito pool and add them to `faculty` or `administrator`, sync the web UI to the web bucket, and register a first textbook.

Environments: `prod` runs OpenSearch on two data nodes in two availability zones, WAF, CloudTrail, MFA, deletion protection and 90-day logs. `dev` runs one `t3.small.search` node in one zone with none of those, so it can be destroyed freely.

Rollback: every code change publishes an immutable Lambda version behind the `live` alias. `aws lambda update-alias --function-name <fn> --name live --function-version <n>` rolls back in seconds; then fix forward in Git (Terraform will show the alias drift).

## Models and measurements

Model ids and sizes are read from AWS, never written from memory (`aws bedrock list-inference-profiles`, `list-foundation-models`, `aws opensearch list-versions`). Re-run these before changing one.

- Generation: `global.anthropic.claude-sonnet-5-5` (variable `llm_model_id`). `global.` profiles may process requests outside India; use an `in.anthropic.*` profile if data must stay in India (in ap-south-1 these exist for Sonnet 5, Opus 5 and Haiku 4.5).
- Embeddings: `amazon.titan-embed-text-v2:0`, on demand, 1024 dimensions.
- OpenSearch `OpenSearch_3.7`; `t3.small.search` and `m7g.large.search` are listed as available in ap-south-1.
- Sonnet 5.5 rejects a forced tool call on Bedrock (only `auto` is accepted); `common/bedrock.py` falls back automatically. Haiku 5.5 accepts a forced call.
- Duplicate threshold 0.80 cosine (`duplicate_similarity`), chosen from measurement: re-asked questions scored 0.86-0.89 and different ones 0.65 or less. A very small textbook runs out of new questions and a second paper fails the gate; that is the gate working. Re-measure on your own textbooks before changing the threshold.

## Operations

| Alarm | First step |
|---|---|
| `lambda-errors-<fn>` | Search that function's log group for `*_error` or `unhandled_error`; roll back the alias if a release caused it |
| `dead-letter-ingest` / `dead-letter-generate` | Read the failed message and the registry error code, fix the cause, then `aws sqs start-message-move-task --source-arn <dlq arn>` |
| `queue-age-*` | Work is waiting: check Lambda concurrency limits and Bedrock quotas |
| `api-5xx` | Search for `generate_error` and `unhandled_error`; check Bedrock throttling |
| `search-cluster-red`, `search-free-storage`, `search-cpu` | Check the OpenSearch domain; grow the volume or node type |

Logs are JSON lines carrying ids, counts and error codes. They never carry prompts, textbook text or question content. Metrics `TextbooksIndexed`, `TextbooksFailed`, `PapersCompleted`, `PapersFailed` feed the dashboard. Set `alert_email` for prod; Terraform warns until you do.

## Rules for Claude

- Complete code with working defaults; no `TODO` or placeholders.
- Never write a model id, instance type, ARN format or API shape from memory. Read it from AWS or the AWS documentation, and prove behaviour with one real call.
- Never run `terraform apply`, `destroy`, `import` or `state` commands, or change GitHub or AWS settings, unless the user asks in the conversation. Deployment goes through the pipeline.
- Never put keys in any file, workflow or message. `*.tfvars`, state, plans and `build/` stay out of Git.
- Do not weaken a production control to pass a plan. Prod/non-prod differences live in `locals` in `infra/main.tf` only.
- Pin every GitHub Action to a commit SHA with the version in a comment; resolve SHAs from the GitHub API, do not guess.
- A change to `src/` needs a test. Run `python -m unittest discover -s tests` (needs `pip install -r tests/requirements.txt`).
- Verify infrastructure in a scratch copy: `terraform fmt -recursive`, `init -backend=false`, `validate`, then `plan` for `prod` and `-var environment=dev` with a local backend override. The plan reads the account id, so use real credentials (read-only); dummy keys fail.
- Keep the Lambda free of pip dependencies (standard library plus boto3) so `archive_file` packages it with no build step.
- Report only what you ran and saw. A plan is not a deployment.

## Definition of done

A change is done when every step below has been carried out and its output kept with the commit:

1. Unit tests pass: `python -m unittest discover -s tests`.
2. `terraform fmt -check -recursive` is clean and `terraform validate` has no warnings in `infra` and `bootstrap`.
3. The prod and dev plans are reviewed: the create/change/destroy counts match the intent and every IAM, network or storage change is understood.
4. The pull request pipeline is green, including the IaC scan, and a reviewer has approved.
5. After merge, dev is applied and its smoke test passes; the prod reviewers approve; prod is applied and its smoke test passes.
6. For pipeline changes, an end-to-end run in dev: register a textbook, upload it, wait for COMPLETED, request a paper, download it, and run the Test Report cases below.
7. Faculty review every generated paper before official use.
8. The release record exists: release id, approver, plan, test output and the rollback command.

Test Report cases and where they are covered:

| Case | Covered by |
|---|---|
| TC-01 request validation | `test_api`: invalid registrations and requests |
| TC-02 only COMPLETED versions | `test_api`, `test_generate`: not-COMPLETED textbooks refused; the OpenSearch filter in the end-to-end run |
| TC-03 count and schema | `test_quality` (the prototype's rules), `test_generate` |
| TC-04 duplicates | `test_generate`: in-paper, question bank, exact repeat, round cap |
| TC-05 failure status | `test_generate`, `test_ingest`: FAILED with error code, no internals leaked |
| TC-06 traceability | `test_quality`, `test_generate`: citations required, pages in the JSON |
| TC-07 retry and dead-letter | `test_ingest`, `test_generate`: retry and final-failure logic; the DLQ in the end-to-end run |
| TC-08 idempotency | `test_ingest` repeated event, `test_api` idempotency key, redelivery handling |
| TC-09 output delivery | `test_generate`: DOCX and JSON written and read back; download links in the end-to-end run |
| TC-10 security and logging | IAM review, scanner output and a log review (steps 3 and 4, plus the logging rule above) |
