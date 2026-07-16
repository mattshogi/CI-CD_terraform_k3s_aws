# Public network load balancer fronting the HA k3s servers for web traffic.
#
# Only ports 80 and 443 are exposed. The Kubernetes API (6443) is deliberately
# NOT fronted here — cluster joins use private IPs, and the API must not be
# reachable from the internet.
#
# Ordering note (avoids a dependency cycle): aws_lb has no dependency on the
# target instances (its dns_name is known once the LB itself is created), so
# callers can feed dns_name into node user_data. The instances are attached
# afterwards via the separate aws_lb_target_group_attachment resources below,
# which are the only things that depend on target_instance_ids. Graph order is
# therefore: aws_lb -> nodes (consume dns_name) -> attachments (consume ids).

resource "aws_lb" "this" {
  name               = var.name
  internal           = false
  load_balancer_type = "network"
  subnets            = var.subnet_ids
}

resource "aws_lb_target_group" "http" {
  name        = "${var.name}-http"
  port        = 80
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "80"
  }
}

resource "aws_lb_target_group" "https" {
  name        = "${var.name}-https"
  port        = 443
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "443"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http.arn
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.https.arn
  }
}

resource "aws_lb_target_group_attachment" "http" {
  count            = length(var.target_instance_ids)
  target_group_arn = aws_lb_target_group.http.arn
  target_id        = var.target_instance_ids[count.index]
  port             = 80
}

resource "aws_lb_target_group_attachment" "https" {
  count            = length(var.target_instance_ids)
  target_group_arn = aws_lb_target_group.https.arn
  target_id        = var.target_instance_ids[count.index]
  port             = 443
}
