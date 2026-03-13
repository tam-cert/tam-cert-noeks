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
# Uses instance target type targeting node IPs directly on the Teleport NodePort

resource "aws_lb_target_group" "teleport" {
  name        = "${var.training_prefix}-teleport-tg"
  port        = 32059
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = "32059"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-teleport-tg"
  })
}

# ─── Register all three node IPs as targets on the NodePort ──────────────────

resource "aws_lb_target_group_attachment" "master" {
  target_group_arn = aws_lb_target_group.teleport.arn
  target_id        = var.master_ip
  port             = 32059
}

resource "aws_lb_target_group_attachment" "node1" {
  target_group_arn = aws_lb_target_group.teleport.arn
  target_id        = var.node1_ip
  port             = 32059
}

resource "aws_lb_target_group_attachment" "node2" {
  target_group_arn = aws_lb_target_group.teleport.arn
  target_id        = var.node2_ip
  port             = 32059
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

# ─── Security Group: allow NLB to reach NodePort on cluster nodes ─────────────

resource "aws_security_group_rule" "nlb_to_cluster" {
  type              = "ingress"
  from_port         = 32059
  to_port           = 32059
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.main.id
  description       = "Allow NLB health checks and traffic to Teleport NodePort"
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "nlb_dns_name" {
  value       = aws_lb.teleport.dns_name
  description = "DNS name of the NLB — point grant-tam-teleport.gvteleport.com CNAME here"
}
