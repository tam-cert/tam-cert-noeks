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
# Targets MetalLB IP on port 443 for traffic.
# Health check uses Kubernetes healthCheckNodePort on node IPs.

resource "aws_lb_target_group" "teleport" {
  name        = "${var.training_prefix}-teleport-tg"
  port        = 443
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = var.teleport_health_check_node_port
    path                = "/healthz"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
    matcher             = "200"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-teleport-tg"
  })
}

# ─── Register MetalLB IP as target on port 443 ───────────────────────────────

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

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "nlb_dns_name" {
  value       = aws_lb.teleport.dns_name
  description = "DNS name of the NLB — point grant-tam-teleport.gvteleport.com CNAME here"
}
