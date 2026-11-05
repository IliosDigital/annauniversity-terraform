# Identity: faculty and administrators sign in with Cognito. Accounts are created
# by an administrator (no self sign-up). The group decides what the API allows.

resource "aws_cognito_user_pool" "main" {
  name                     = local.name
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = local.is_prod ? "ON" : "OFF"
  deletion_protection      = local.is_prod ? "ACTIVE" : "INACTIVE"

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  dynamic "software_token_mfa_configuration" {
    for_each = local.is_prod ? [1] : []

    content {
      enabled = true
    }
  }
}

resource "aws_cognito_user_group" "this" {
  for_each = {
    faculty       = "Faculty who request and download question papers"
    administrator = "Administrators who manage textbooks and users"
  }

  name         = each.key
  description  = each.value
  user_pool_id = aws_cognito_user_pool.main.id
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "${local.name}-web"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = false # a browser cannot keep a secret
  explicit_auth_flows                  = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true
  supported_identity_providers         = ["COGNITO"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  callback_urls                        = ["${local.web_origin}/"]
  logout_urls                          = ["${local.web_origin}/"]

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 12

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "hours"
  }
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${local.name}-${local.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}
