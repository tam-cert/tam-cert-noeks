# ─── Route53 DNS Records for Teleport ────────────────────────────────────────

# Look up the existing hosted zone for gvteleport.com
data "aws_route53_zone" "teleport" {
  name         = "gvteleport.com"
  private_zone = false
}

# grant-tam-teleport.gvteleport.com → NLB
resource "aws_route53_record" "teleport" {
  zone_id = data.aws_route53_zone.teleport.zone_id
  name    = "grant-tam-teleport.gvteleport.com"
  type    = "CNAME"
  ttl     = 300
  records = [aws_lb.teleport.dns_name]
}

# *.grant-tam-teleport.gvteleport.com → NLB (for app access)
resource "aws_route53_record" "teleport_wildcard" {
  zone_id = data.aws_route53_zone.teleport.zone_id
  name    = "*.grant-tam-teleport.gvteleport.com"
  type    = "CNAME"
  ttl     = 300
  records = [aws_lb.teleport.dns_name]
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "teleport_dns" {
  value = aws_route53_record.teleport.fqdn
}

output "teleport_wildcard_dns" {
  value = aws_route53_record.teleport_wildcard.fqdn
}
