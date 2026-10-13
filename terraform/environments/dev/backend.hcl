# Filled in by ./bootstrap-backend.sh (it prints the exact bucket name). Replace <ACCOUNT_ID>.
bucket         = "nexvion-tfstate-<ACCOUNT_ID>"
key            = "dev/terraform.tfstate"
region         = "ap-south-1"
dynamodb_table = "nexvion-tf-locks"
encrypt        = true
