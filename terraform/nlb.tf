# ─── NLB for Teleport ─────────────────────────────────────────────────────────
# Routes external HTTPS traffic to the MetalLB IP (172.49.20.100)
# assigned to the Teleport proxy service.

resource "aws_lb" "teleport" {
  name               = "${var.training_prefix}-teleport-nlb"
  load_balancer_type = "network"
  internal           = false
  subnets            = [aws_subnet.main.id]

  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = false

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-teleport-nlb"
  })
}

# ─── Target Group ─────────────────────────────────────────────────────────────
# Targets MetalLB IP on port 443.
# TCP health check on 443 — passes on successful TCP connect regardless of TLS.

resource "aws_lb_target_group" "teleport" {
  name        = "${var.training_prefix}-teleport-tg2"
  port        = 443
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = "443"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-teleport-tg2"
  })
}

# ─── Register MetalLB IP as target ────────────────────────────────────────────

resource "aws_lb_target_group_attachment" "teleport" {
  target_group_arn = aws_lb_target_group.teleport.arn
  target_id        = "172.49.20.100"
  port             = 443
}

# ─── Listener ─────────────────────────────────────────────────────────────────

resource "aws_lb_listener" "teleport_443" {
  load_balancer_arn = aws_lb.teleport.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.teleport.arn
  }
}

# ─── Security Group: allow NLB traffic and health checks ──────────────────────

resource "aws_security_group_rule" "nlb_to_teleport_443" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.main.id
  description       = "Allow HTTPS traffic to Teleport via MetalLB"
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "nlb_dns_name" {
  value       = aws_lb.teleport.dns_name
  description = "DNS name of the NLB — point grant-tam-teleport.gvteleport.com CNAME here"
}
