/*
  Backend examples — uncomment and configure one before running `terraform init`.

  Recommended: Terraform Cloud or an S3-compatible backend with state locking.

  Example: Terraform Cloud
  ------------------------
  terraform {
    backend "remote" {
      organization = "your-org"
      workspaces {
        name = "home-ops-bootstrap"
      }
    }
  }

  Example: S3 + DynamoDB (AWS)
  -----------------------------
  terraform {
    backend "s3" {
      bucket         = "your-terraform-state-bucket"
      key            = "home-ops/bootstrap/terraform.tfstate"
      region         = "us-east-1"
      dynamodb_table = "terraform-locks"
      encrypt        = true
    }
  }

  Example: local (good for quick testing only)
  -------------------------------------------
  terraform {
    backend "local" {
      path = "./terraform.tfstate"
    }
  }


  Example: Cloudflare R2 (S3-compatible)
  ---------------------------------------
  Note: R2 is S3-compatible but does not provide DynamoDB-style state locking. For safe concurrent runs use Terraform Cloud or another locking mechanism.
  terraform {
    backend "s3" {
      bucket         = "your-r2-bucket"
      key            = "home-ops/bootstrap/terraform.tfstate"
      region         = "auto"
      endpoint       = "https://<account-id>.r2.cloudflarestorage.com"
      force_path_style = true
      # Credentials: set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in your environment
      # or configure a named profile.
    }
  }


  Example: Backblaze B2 (S3-compatible)
  -------------------------------------
  Note: B2 offers an S3-compatible endpoint. Like R2, B2 does not provide DynamoDB locking.
  terraform {
    backend "s3" {
      bucket         = "your-b2-bucket"
      key            = "home-ops/bootstrap/terraform.tfstate"
      region         = "us-west-000"
      endpoint       = "https://s3.us-west-000.backblazeb2.com"
      force_path_style = true
      # Credentials: set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY to your B2 S3 keys
    }
  }

*/
