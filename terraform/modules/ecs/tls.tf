# The certificate for the HTTPS listener (alb.tf).
#
# With domain_name set, ACM issues a public cert, validated by DNS records
# in the Route 53 zone route53_zone_id, and an alias record points the name
# at the ALB. ACM renews it on its own while the validation records stay.
#
# With no domain (the demo default) the cert is self-signed, made by the
# hashicorp/tls provider and imported into ACM. Imported certs cost nothing
# and ACM never renews them, so Terraform does it: once the cert is inside
# early_renewal_hours of expiry, the next plan makes a new key and cert and
# re-imports them into the same ACM ARN. Browsers and curl don't trust a
# self-signed cert, so clients need curl -k (or --cacert with the PEM from
# the self_signed_cert_pem output).
#
# The key lives in Terraform state, like any tls_private_key. State is in
# the encrypted, access-limited bucket, and the cert only fronts a demo.

locals {
  use_domain = var.domain_name != null

  certificate_arn = local.use_domain ? aws_acm_certificate_validation.domain[0].certificate_arn : aws_acm_certificate.self_signed[0].arn
}

# Self-signed

resource "tls_private_key" "self_signed" {
  count = local.use_domain ? 0 : 1

  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "self_signed" {
  count = local.use_domain ? 0 : 1

  private_key_pem = tls_private_key.self_signed[0].private_key_pem

  # The ALB's own name, so hostname checks pass with --cacert. No cycle:
  # the ALB doesn't depend on the cert, only the HTTPS listener does.
  dns_names = [aws_lb.this.dns_name]

  subject {
    common_name  = "${var.name_prefix}-alb"
    organization = var.name_prefix
  }

  validity_period_hours = var.self_signed_validity_hours
  early_renewal_hours   = var.self_signed_early_renewal_hours

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "self_signed" {
  count = local.use_domain ? 0 : 1

  private_key      = tls_private_key.self_signed[0].private_key_pem
  certificate_body = tls_self_signed_cert.self_signed[0].cert_pem

  tags = {
    Name = "${var.name_prefix}-alb-self-signed"
  }

  # The HTTPS listener holds this cert, so a new one has to exist before the
  # old one can go. A renewal re-imports into the same ARN in place.
  lifecycle {
    create_before_destroy = true
  }
}

# Real domain

resource "aws_acm_certificate" "domain" {
  count = local.use_domain ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"
  key_algorithm     = "EC_prime256v1"

  options {
    certificate_transparency_logging_preference = "ENABLED"
  }

  tags = {
    Name = "${var.name_prefix}-alb"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.use_domain ? {
    for o in aws_acm_certificate.domain[0].domain_validation_options : o.domain_name => {
      name   = o.resource_record_name
      type   = o.resource_record_type
      record = o.resource_record_value
    }
  } : {}

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "domain" {
  count = local.use_domain ? 1 : 0

  certificate_arn         = aws_acm_certificate.domain[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# The friendly name for the ALB. Alias records are free and follow the ALB's
# IPs as they change.
resource "aws_route53_record" "alb" {
  count = local.use_domain ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
