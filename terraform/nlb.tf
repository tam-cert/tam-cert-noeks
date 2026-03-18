# ─── NLB for Teleport ─────────────────────────────────────────────────────────

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
# Targets all three node IPs on NodePort 32443.
# Health check uses TCP on 32443 — Teleport proxy responds on this port.
# Previously used healthCheckNodePort 32444 with externalTrafficPolicy: Local,
# but that requires type: LoadBalancer. With type: NodePort the health check
# hits the NodePort directly via TCP.

resource "aws_lb_target_group" "teleport" {
  name        = "${var.training_prefix}-teleport-tg"
  port        = 32443
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = "32443"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-teleport-tg"
  })
}

# ─── Register all three node IPs as targets ───────────────────────────────────

resource "aws_lb_target_group_attachment" "master" {
  target_group_arn = aws_lb_target_group.teleport.arn
  target_id        = var.master_ip
  port             = 32443
}

resource "aws_lb_target_group_attachment" "node1" {
  target_group_arn = aws_lb_target_group.teleport.arn
  target_id        = var.node1_ip
  port             = 32443
}

resource "aws_lb_target_group_attachment" "node2" {
  target_group_arn = aws_lb_target_group.teleport.arn
  target_id        = var.node2_ip
  port             = 32443
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

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "nlb_dns_name" {
  value       = aws_lb.teleport.dns_name
  description = "DNS name of the NLB — point grant-tam-teleport.gvteleport.com CNAME here"
}
