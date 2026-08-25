# Copy to terraform.tfvars and fill in. terraform.tfvars is gitignored.
#
# Better still, keep the password out of files entirely:
#   export TF_VAR_db_password='...'

region      = "eu-west-1"
project     = "telemetry"
alarm_email = "you@example.com"

# db_password = "set via TF_VAR_db_password instead"
