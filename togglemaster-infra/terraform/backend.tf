terraform {
  backend "s3" {
    bucket = "tc4-togglemaster-tfstate-029709361658"
    key    = "fase-4/terraform.tfstate"
    region = "us-east-1"

    use_lockfile = true
  }
}