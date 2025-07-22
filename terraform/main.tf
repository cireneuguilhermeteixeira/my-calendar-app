provider "aws" {
  region = "us-east-1"
}

data "aws_vpc" "default" {
  default = true
}
data "aws_subnets" "default" {
  filter { name = "vpc-id" values = [data.aws_vpc.default.id] }
}

// Security Group for EC2 Instances

resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP from Internet"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress { from_port = 0 to_port = 0 protocol = "-1" cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "ec2_sg" {
  name        = "ec2-sg"
  description = "Allow HTTP from ALB; MySQL to Aurora"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  egress { from_port = 0 to_port = 0 protocol = "-1" cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "rds_sg" {
  name        = "rds-sg"
  description = "Allow MySQL from EC2"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }
  egress { from_port = 0 to_port = 0 protocol = "-1" cidr_blocks = ["0.0.0.0/0"] }
}



// IAM Role for EC2 Instances
resource "aws_iam_role" "ec2_role" {
  name = "calendar-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ec2_policy" {
  name = "calendar-ec2-policy"
  role = aws_iam_role.ec2_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"]
        Resource = [aws_sqs_queue.app_queue.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.notifications.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["es:ESHttp*"]
        Resource = ["${aws_elasticsearch_domain.calendar_es.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["rds:DescribeDBClusters","rds-db:connect"]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "calendar-ec2-profile"
  role = aws_iam_role.ec2_role.name
}


// Launch Template + Auto Scaling Group


resource "aws_launch_template" "app_lt" {
  name_prefix   = "calendar-app-"
  image_id      = "ami-0123456789abcdef0"    # escolha sua AMI
  instance_type = "t3.micro"
  iam_instance_profile { name = aws_iam_instance_profile.ec2_profile.name }
  security_group_names = [aws_security_group.ec2_sg.name]
  user_data = base64encode(<<-EOF
    #!/bin/bash
    # Instala dependências e inicia sua aplicação
    # Ela deve:
    # 1) Expor HTTP na porta 80 (para ALB)
    # 2) Poll no SQS para jobs pesados
EOF
  )
}

resource "aws_autoscaling_group" "app_asg" {
  name                      = "calendar-asg"
  max_size                  = 3
  min_size                  = 1
  desired_capacity          = 2
  vpc_zone_identifier       = data.aws_subnets.default.ids
  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }
  target_group_arns         = [aws_lb_target_group.app_tg.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  tag {
    key                 = "Name"
    value               = "calendar-app"
    propagate_at_launch = true
  }
}


// Application Load Balancer

resource "aws_lb" "app_alb" {
  name               = "calendar-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "app_tg" {
  name     = "calendar-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    interval            = 30
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

// API Gateway HTTP API + Integration with ALB

resource "aws_apigatewayv2_api" "calendar_api" {
  name          = "calendar-api"
  protocol_type = "HTTP"
}

# Integração ao ALB
resource "aws_apigatewayv2_integration" "alb" {
  api_id             = aws_apigatewayv2_api.calendar_api.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = aws_lb_listener.app_listener.arn
}

# Rotas básicas via ALB
locals {
  routes = [
    "POST /events",
    "PUT /events/{id}",
    "DELETE /events/{id}",
    "GET /events",
    "GET /events/{id}"
  ]
}
resource "aws_apigatewayv2_route" "alb_routes" {
  for_each  = toset(local.routes)
  api_id    = aws_apigatewayv2_api.calendar_api.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

# Integração SQS para sugestões (tarefas pesadas)
resource "aws_sqs_queue" "app_queue" {
  name                       = "calendar-suggestions-queue"
  visibility_timeout_seconds = 30
}

resource "aws_iam_role" "apigw_sqs_role" {
  name               = "apigw-sqs-role"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume.json
}
data "aws_iam_policy_document" "apigw_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service" services = ["apigateway.amazonaws.com"] }
  }
}

resource "aws_iam_role_policy" "apigw_sqs_policy" {
  name   = "apigw-sqs-policy"
  role   = aws_iam_role.apigw_sqs_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = [aws_sqs_queue.app_queue.arn]
    }]
  })
}

resource "aws_apigatewayv2_integration" "sqs" {
  api_id                    = aws_apigatewayv2_api.calendar_api.id
  integration_type          = "AWS_PROXY"
  integration_subtype       = "SQS-SendMessage"
  integration_uri           = "arn:aws:apigateway:${var.region}:sqs:path/${aws_sqs_queue.app_queue.name}"
  credentials_arn           = aws_iam_role.apigw_sqs_role.arn
  payload_format_version    = "1.0"
}

resource "aws_apigatewayv2_route" "suggest" {
  api_id    = aws_apigatewayv2_api.calendar_api.id
  route_key = "POST /suggest"
  target    = "integrations/${aws_apigatewayv2_integration.sqs.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.calendar_api.id
  name        = "$default"
  auto_deploy = true
}


// SNS Topic for Email Notifications


resource "aws_sns_topic" "notifications" {
  name = "calendar-notifications"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = "seu-email@exemplo.com"
}

// Elasticsearch Domain for Search

resource "aws_elasticsearch_domain" "calendar_es" {
  domain_name           = "calendar-es"
  elasticsearch_version = "7.10"

  cluster_config {
    instance_type  = "t3.small.elasticsearch"
    instance_count = 2
  }
  ebs_options {
    ebs_enabled = true
    volume_size = 10
    volume_type = "gp2"
  }

  access_policies = data.aws_iam_policy_document.es_access.json
}
data "aws_iam_policy_document" "es_access" {
  statement {
    effect = "Allow"
    principals { type = "AWS" identifiers = ["*"] }
    actions   = ["es:*"]
    resources = ["${aws_elasticsearch_domain.calendar_es.arn}/*"]
  }
}

// Aurora MySQL Cluster

resource "aws_rds_cluster" "calendar_cluster" {
  cluster_identifier      = "calendar-cluster"
  engine                  = "aurora-mysql"
  master_username         = "admin"
  master_password         = "S3nh4F0rt3!"
  skip_final_snapshot     = true
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
}

resource "aws_rds_cluster_instance" "calendar_instances" {
  count                   = 2
  cluster_identifier      = aws_rds_cluster.calendar_cluster.id
  instance_class          = "db.t3.medium"
  engine                  = aws_rds_cluster.calendar_cluster.engine
}
