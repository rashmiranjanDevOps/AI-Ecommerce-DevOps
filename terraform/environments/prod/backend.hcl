bucket         = "nexvion-tfstate-<ACCOUNT_ID>"
key            = "prod/terraform.tfstate"
region         = "ap-south-1"
dynamodb_table = "nexvion-tf-locks"
encrypt        = true
