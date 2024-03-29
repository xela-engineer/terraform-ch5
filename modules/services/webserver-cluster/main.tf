provider "aws" {
  region = "us-east-2"
}

data "aws_vpc" "default" {  // 1 get the default VPC
  default = true
}

data "aws_subnets" "default" { 
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id] // 2 get the default VPC ID, ==> then we can get the default VPC subnet
  }
}

# Part : security group

resource "aws_security_group" "instance" {
  name = "${var.cluster_name}-instance"
  # Allow ec2 instance to receive traffic on port 8080
  ingress {
    from_port = var.server_port
    to_port = var.server_port
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_launch_configuration" "example" {
  image_id        = var.ami
  instance_type   = var.instance_type
  security_groups = [aws_security_group.instance.id]

  user_data = templatefile("${path.module}/user-data.sh", {
    server_text = var.server_text
    server_port = var.server_port
    db_address  = data.terraform_remote_state.db.outputs.db_module_output.address
    db_port     = data.terraform_remote_state.db.outputs.db_module_output.port
  })
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "example" {
  name = "${var.cluster_name}-${aws_launch_configuration.example.name}"

  launch_configuration = aws_launch_configuration.example.name
  vpc_zone_identifier  = data.aws_subnets.default.ids # 3 now we can get the default VPC's subnet IDs
  
  target_group_arns = [aws_lb_target_group.asg.arn]
  health_check_type = "ELB"

  min_size = var.min_size
  max_size = var.max_size

  # Wait for at least this many instances to pass health checks before
  # considering the ASG deployment complete
  min_elb_capacity = var.min_size

  # When replacing this ASG, create the replacement first, and only delete the
  # original after
  lifecycle {
    create_before_destroy = true
  }
  
  tag {
    key = "name"
    value = "${var.cluster_name}-asg-example"
    propagate_at_launch = true
  }

  dynamic "tag" {
    // Task 5: Conditionals with for_each and for Expressions
    for_each = {
      for key, value in var.custom_tags:
        key => upper(value)
        if key != "Name" 
    }
    // ==== END Task 5: Conditionals with for_each and for Expressions ==========
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}


resource "aws_lb" "example" {     # create ALB
  name               = "${var.cluster_name}-asg-example"
  load_balancer_type = "application"
  subnets            = data.aws_subnets.default.ids
  security_groups = [aws_security_group.alb.id]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port = local.http_port
  protocol = "HTTP"
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code = 404 
    }
  }
}
resource "aws_security_group" "alb" {
  name = "${var.cluster_name}-alb"
  
}

resource "aws_security_group_rule" "allow_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id

  from_port   = local.http_port
  to_port     = local.http_port
  protocol    = local.tcp_protocol
  cidr_blocks = local.all_ips
}

resource "aws_security_group_rule" "allow_all_outbound" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id

  from_port   = local.any_port
  to_port     = local.any_port
  protocol    = local.any_protocol
  cidr_blocks = local.all_ips
}

resource "aws_lb_target_group" "asg" {
  name = "${var.cluster_name}-asg-example"
  port = var.server_port
  protocol = "HTTP"
  vpc_id = data.aws_vpc.default.id

  health_check {
    path = "/"
    protocol = "HTTP"
    matcher = 200
    interval = 15
    timeout = 3
    healthy_threshold = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}

# ========= schduling ==========
resource "aws_autoscaling_schedule" "scale_out_during_business_hours" {
  count = var.enable_autoscaling ? 1:0
  autoscaling_group_name = aws_autoscaling_group.example.name
  scheduled_action_name = "scale-out-during-business-hours"
  min_size = 2
  max_size = 10
  desired_capacity = 10
  recurrence = "0 9 * * *"    # means “9 a.m. every day”
}

resource "aws_autoscaling_schedule" "scale_in_at_night" {
  count = var.enable_autoscaling ? 1:0
  autoscaling_group_name = aws_autoscaling_group.example.name
  scheduled_action_name = "scale-in-at-night"
  min_size = 2
  max_size = 10
  desired_capacity = 2
  recurrence = "0 17 * * *"   # means “5 p.m. every day”
}# ================ END =============


data "terraform_remote_state" "db" {
  backend = "s3"

  config = {
    #bucket = "terraform-up-and-running-state-collection"
    #key    = "stage/data-stores/mysql/terraform.tfstate"
    bucket = var.db_remote_state_bucket
    key    = var.db_remote_state_key
    region = "us-east-2"
  }
}