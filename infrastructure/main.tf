provider "aws" {
  region     = "eu-central-1"
  version    = "~> 2.0"
}

terraform {
  backend "s3" {
    bucket = "ter-buck"
    key    = "terprod2/terraform.tfstate"
    region = "eu-central-1"
  }
}

resource "aws_vpc" "main" {
  cidr_block = var.cidr
}
 
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = element(var.private_subnets, count.index)
  availability_zone = element(var.availability_zones, count.index)
  count             = length(var.private_subnets)
}
 
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = element(var.public_subnets, count.index)
  availability_zone       = element(var.availability_zones, count.index)
  count                   = length(var.public_subnets)
  map_public_ip_on_launch = true
}

resource "aws_db_instance" "default" {
  allocated_storage    = 10
  engine               = "postgres"
  final_snapshot_identifier = "final-snapshot-${md5(timestamp())}"
  engine_version       = "13.7"
  instance_class       = "db.t3.micro"
  username             = "postgres"
  password             = "postgres"
  publicly_accessible = true
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
}
 
resource "aws_route" "public" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}
 
resource "aws_route_table_association" "public" {
  count          = length(var.public_subnets)
  subnet_id      = element(aws_subnet.public.*.id, count.index)
  route_table_id = aws_route_table.public.id
}

resource "aws_nat_gateway" "main" {
  count         = length(var.private_subnets)
  allocation_id = element(aws_eip.nat.*.id, count.index)
  subnet_id     = element(aws_subnet.public.*.id, count.index)
  depends_on    = [aws_internet_gateway.main]
}
 
resource "aws_eip" "nat" {
  count = length(var.private_subnets)
  vpc = true
}

resource "aws_route_table" "private" {
  count  = length(var.private_subnets)
  vpc_id = aws_vpc.main.id
}
 
resource "aws_route" "private" {
  count                  = length(compact(var.private_subnets))
  route_table_id         = element(aws_route_table.private.*.id, count.index)
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = element(aws_nat_gateway.main.*.id, count.index)
}
 
resource "aws_route_table_association" "private" {
  count          = length(var.private_subnets)
  subnet_id      = element(aws_subnet.private.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, count.index)
}

resource "aws_security_group" "alb" {
  name   = "${var.name}-sg-alb-${var.environment}"
  vpc_id = aws_vpc.main.id
 
  ingress {
   protocol         = "tcp"
   from_port        = 80
   to_port          = 80
   cidr_blocks      = ["0.0.0.0/0"]
   ipv6_cidr_blocks = ["::/0"]
  }
 
  ingress {
   protocol         = "tcp"
   from_port        = 443
   to_port          = 443
   cidr_blocks      = ["0.0.0.0/0"]
   ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
   protocol         = "-1"
   from_port        = 0
   to_port          = 0
   cidr_blocks      = ["0.0.0.0/0"]
   ipv6_cidr_blocks = ["::/0"]
  }
 
  egress {
   protocol         = "-1"
   from_port        = 0
   to_port          = 0
   cidr_blocks      = ["0.0.0.0/0"]
   ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_security_group" "ecs_tasks" {
  name   = "${var.name}-sg-task-${var.environment}"
  vpc_id = aws_vpc.main.id
 
  ingress {
   protocol         = "tcp"
   from_port        = var.container_port
   to_port          = var.container_port
   cidr_blocks      = ["0.0.0.0/0"]
   ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
   protocol         = "-1"
   from_port        = 0
   to_port          = 0
   cidr_blocks      = ["0.0.0.0/0"]
   ipv6_cidr_blocks = ["::/0"]
  }
 
  egress {
   protocol         = "-1"
   from_port        = 0
   to_port          = 0
   cidr_blocks      = ["0.0.0.0/0"]
   ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_ecr_repository" "main" {
  name                 = "${var.name}-${var.environment}"
  image_tag_mutability = "MUTABLE"
}

resource "aws_ecr_lifecycle_policy" "main" {
  repository = aws_ecr_repository.main.name
 
  policy = jsonencode({
   rules = [{
     rulePriority = 1
     description  = "keep last 10 images"
     action       = {
       type = "expire"
     }
     selection     = {
       tagStatus   = "any"
       countType   = "imageCountMoreThan"
       countNumber = 10
     }
   }]
  })
}

resource "aws_ecs_cluster" "main" {
  name = "${var.name}-cluster-${var.environment}"
}

resource "aws_ecs_task_definition" "main" {
  family = "service"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  container_definitions = jsonencode([{
   name        = "${var.name}-container-${var.environment}"
   image       = "${aws_ecr_repository.main.repository_url}:latest"
   essential   = true
#    environment = var.container_environment
   portMappings = [{
     protocol      = "tcp"
     containerPort = 80
     hostPort      = 80
   }]
  }])
}

resource "aws_iam_role" "ecs_task_role" {
  name = "${var.name}-ecsTaskRole"
 
  assume_role_policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Action": "sts:AssumeRole",
     "Principal": {
       "Service": "ecs-tasks.amazonaws.com"
     },
     "Effect": "Allow",
     "Sid": ""
   }
 ]
}
EOF
}
 
resource "aws_iam_policy" "dynamodb" {
  name        = "${var.name}-task-policy-dynamodb"
  description = "Policy that allows access to DynamoDB"
 
 policy = <<EOF
{
   "Version": "2012-10-17",
   "Statement": [
       {
           "Effect": "Allow",
           "Action": [
               "dynamodb:CreateTable",
               "dynamodb:UpdateTimeToLive",
               "dynamodb:PutItem",
               "dynamodb:DescribeTable",
               "dynamodb:ListTables",
               "dynamodb:DeleteItem",
               "dynamodb:GetItem",
               "dynamodb:Scan",
               "dynamodb:Query",
               "dynamodb:UpdateItem",
               "dynamodb:UpdateTable"
           ],
           "Resource": "*"
       }
   ]
}
EOF
}
 
resource "aws_iam_role_policy_attachment" "ecs-task-role-policy-attachment" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.dynamodb.arn
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.name}-ecsTaskExecutionRole"
 
  assume_role_policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Action": "sts:AssumeRole",
     "Principal": {
       "Service": "ecs-tasks.amazonaws.com"
     },
     "Effect": "Allow",
     "Sid": ""
   }
 ]
}
EOF
}
 
resource "aws_iam_role_policy_attachment" "ecs-task-execution-role-policy-attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_service" "main" {
 name                               = "${var.name}-service-${var.environment}"
 cluster                            = aws_ecs_cluster.main.id
 task_definition                    = aws_ecs_task_definition.main.arn
 desired_count                      = 1
 deployment_minimum_healthy_percent = 50
 deployment_maximum_percent         = 200
 launch_type                        = "FARGATE"
 scheduling_strategy                = "REPLICA"
 depends_on = [
   aws_lb_target_group.main,
   aws_lb.main
 ]
 
 network_configuration {
   security_groups  = [aws_security_group.ecs_tasks.id]
   subnets            = [
    for subnet in aws_subnet.private : subnet.id
  ]
 }
 
 load_balancer {
   target_group_arn = aws_lb_target_group.main.arn
   container_name   = "${var.name}-container-${var.environment}"
   container_port   = var.container_port
 }
 
 lifecycle {
   ignore_changes = [task_definition, desired_count]
 }
}

resource "aws_lb" "main" {
  name               = "${var.name}-alb-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [
    aws_security_group.alb.id
  ]
  subnets            = [
    for subnet in aws_subnet.public : subnet.id
  ]
 
  enable_deletion_protection = false
}
 
resource "aws_lb_target_group" "main" {
  name        = "${var.name}-tg-${var.environment}"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
 
  health_check {
   healthy_threshold   = "3"
   interval            = "30"
   protocol            = "HTTP"
   matcher             = "200"
   timeout             = "3"
   path                = var.health_check_path
   unhealthy_threshold = "2"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.id
  port              = 80
  protocol          = "HTTP"
 
  default_action {
   type = "forward"
   target_group_arn = aws_lb_target_group.main.id
 
  #  redirect {
  #    port        = 443
  #    protocol    = "HTTPS"
  #    status_code = "HTTP_301"
  #  }
  }
}
 
# resource "aws_alb_listener" "https" {
#   load_balancer_arn = aws_lb.main.id
#   port              = 443
#   protocol          = "HTTPS"
 
#   ssl_policy        = "ELBSecurityPolicy-2016-08"
# #   certificate_arn   = var.alb_tls_cert_arn
 
#   default_action {
#     target_group_arn = aws_alb_target_group.main.id
#     type             = "forward"
#   }
# }

# resource "aws_appautoscaling_target" "ecs_target" {
#   max_capacity       = 4
#   min_capacity       = 1
#   resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.main.name}"
#   scalable_dimension = "ecs:service:DesiredCount"
#   service_namespace  = "ecs"
# }

# resource "aws_appautoscaling_policy" "ecs_policy_memory" {
#   name               = "memory-autoscaling"
#   policy_type        = "TargetTrackingScaling"
#   resource_id        = aws_appautoscaling_target.ecs_target.resource_id
#   scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
#   service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace
 
#   target_tracking_scaling_policy_configuration {
#    predefined_metric_specification {
#      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
#    }
 
#    target_value       = 80
#   }
# }
 
# resource "aws_appautoscaling_policy" "ecs_policy_cpu" {
#   name               = "cpu-autoscaling"
#   policy_type        = "TargetTrackingScaling"
#   resource_id        = aws_appautoscaling_target.ecs_target.resource_id
#   scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
#   service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace
 
#   target_tracking_scaling_policy_configuration {
#    predefined_metric_specification {
#      predefined_metric_type = "ECSServiceAverageCPUUtilization"
#    }
 
#    target_value       = 60
#   }
# }