# AWS deployment

Deploys the ingest service to ECS Fargate behind an Application Load Balancer, with RDS
Postgres, CloudWatch alarms, and a GitHub Actions pipeline that authenticates via OIDC rather
than stored AWS keys.

```
Internet → ALB → ECS Fargate (ingest) → RDS Postgres
                       ↓
                  CloudWatch logs + alarms → SNS → email
```

---

## Read this first: TimescaleDB is not on RDS

RDS does not offer the TimescaleDB extension. The schema therefore **degrades to plain Postgres**
in this deployment — no hypertables, no continuous aggregates. That is a real limitation, not an
oversight, and pretending otherwise would be the wrong lesson to take from this directory.

Three honest options:

| Option | Trade-off |
|---|---|
| **Timescale Cloud**, VPC-peered | What a real deployment does. Costs more than free tier. |
| **TimescaleDB on Fargate** + EFS | Cheap, single-AZ, no managed backups. Fine for a demo. |
| **Plain RDS** + scheduled materialised views | What this uses. Free tier, loses the time-series features. |

The deployment still exercises what it is meant to: a managed database, VPC isolation, secrets
that never touch a task definition, least-privilege IAM, alarms that correspond to real failures,
and a pipeline that ships a commit to production.

---

## Prerequisites

- An AWS account (free tier covers most of this)
- Terraform ≥ 1.6 — or run it through Docker, no install needed:
  ```bash
  docker run --rm -it -v "$PWD:/w" -w /w hashicorp/terraform:1.9.8 <command>
  ```
- AWS CLI configured with credentials that can create IAM, VPC, ECS, and RDS resources
- Docker, to build the image

## Deploy

**1. Set the database password.** Never put it in a file.

```bash
export TF_VAR_db_password="$(openssl rand -base64 24)"
echo "$TF_VAR_db_password"   # save this somewhere safe
```

**2. Configure and apply.**

```bash
cp example.tfvars terraform.tfvars   # then edit alarm_email
terraform init
terraform plan       # read this before applying
terraform apply
```

RDS takes 5–10 minutes. The ECS service will fail its health checks until an image exists — that
is expected, and step 3 fixes it.

**3. Push the first image.** Terraform creates an empty ECR repository; nothing runs until you
push something into it.

```bash
REGION=$(terraform output -raw -state=terraform.tfstate 2>/dev/null || echo eu-west-1)
ECR=$(terraform output -raw ecr_repository_url)

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ECR%%/*}"
docker build -t "$ECR:latest" ../ingest
docker push "$ECR:latest"

aws ecs update-service --cluster telemetry-cluster --service telemetry-ingest --force-new-deployment
```

**4. Load the schema.** RDS is not publicly reachable by design, so tunnel through a one-off task
or a bastion. Simplest route for a demo:

```bash
aws ecs run-task --cluster telemetry-cluster \
  --task-definition telemetry-ingest \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[<subnet-id>],securityGroups=[<task-sg>],assignPublicIp=ENABLED}" \
  --overrides '{"containerOverrides":[{"name":"ingest","command":["sh","-c","apk add --no-cache postgresql-client && psql $DATABASE_URL -f /app/init.sql"]}]}'
```

**5. Verify.**

```bash
curl "$(terraform output -raw health_url)"
```

**6. Wire up CI.** Add the deploy role as a repository secret:

```bash
gh secret set AWS_DEPLOY_ROLE_ARN --body "$(terraform output -raw github_deploy_role_arn)"
```

Pushes to `main` now build, push, and deploy automatically.

---

## Cost

Assuming a new account inside the 12-month free tier:

| Resource | Cost |
|---|---|
| ECS Fargate (0.25 vCPU / 0.5 GB, always on) | ~$9/month — **not** free tier |
| ALB | ~$16/month — **not** free tier |
| RDS db.t4g.micro | Free for 12 months, then ~$12/month |
| ECR, CloudWatch logs, Secrets Manager | Pennies at this scale |

**Roughly $25/month, and the ALB is the largest line.** A budget alarm at $20 is included, but it
notifies — it does not stop anything.

**Destroy it when you are not demonstrating it:**

```bash
terraform destroy
```

Bring it back up in under fifteen minutes whenever you need it. Do not leave it running for
months to keep a link alive on a CV — take screenshots instead.

---

## What production would change

Everything below is deliberately omitted here, and being able to say why is the point:

- **Private subnets + NAT gateway** for tasks and RDS. Adds ~$32/month and buys real isolation.
  This uses public subnets with security-group restrictions instead: RDS accepts connections only
  from the task security group, so it is not internet-reachable, but it is not defence in depth.
- **HTTPS.** ACM certificate, a domain, redirect 80 → 443. HTTP-only is fine for a demo and
  unacceptable for anything real.
- **`multi_az = true`** on RDS, plus `deletion_protection` and `skip_final_snapshot = false`.
- **Autoscaling** on the ECS service. Fixed at one task here, so the CPU alarm is advisory.
- **Remote state** in S3 with DynamoDB locking. Local state means one operator and no history.
- **WAF** on the ALB, and authentication on the ingest endpoint — there is currently none.

## Security notes

- The database password lives in Secrets Manager and is injected at container start. It never
  appears in the task definition, where `ecs:DescribeTaskDefinition` would expose it.
- Execution role and task role are separate. The app calls no AWS APIs, so its task role is
  empty. Collapsing the two into one over-privileged role is the most common ECS mistake.
- The GitHub OIDC trust policy is scoped to one repository. Omitting that condition would let any
  repository on GitHub assume the role — a known and actively exploited misconfiguration.
- The deploy role holds only ECR push and ECS update permissions, with `iam:PassRole` restricted
  to the two roles in this stack.
