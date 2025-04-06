provider "aws" {
  region = "ap-south-1"  
}

# Create VPC
resource "aws_vpc" "medusa_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "medusa-vpc"
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "medusa_igw" {
  vpc_id = aws_vpc.medusa_vpc.id

  tags = {
    Name = "medusa-igw"
  }
}

# Create Public Subnet
resource "aws_subnet" "medusa_subnet" {
  vpc_id                  = aws_vpc.medusa_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = {
    Name = "medusa-subnet"
  }
}

# Create Route Table
resource "aws_route_table" "medusa_rt" {
  vpc_id = aws_vpc.medusa_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.medusa_igw.id
  }

  tags = {
    Name = "medusa-rt"
  }
}

# Associate Route Table with Subnet
resource "aws_route_table_association" "medusa_rta" {
  subnet_id      = aws_subnet.medusa_subnet.id
  route_table_id = aws_route_table.medusa_rt.id
}

# Create Security Group
resource "aws_security_group" "medusa_sg" {
  name        = "medusa-sg"
  description = "Security group for Medusa services"
  vpc_id      = aws_vpc.medusa_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "medusa-sg"
  }
}

# Create IAM role for ECS task execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# Attach the AWS managed policy for ECS task execution
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_cluster" "medusa_cluster" {
  name = "medusa-cluster"
  
  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"
      log_configuration {
        cloud_watch_log_group_name = "/ecs/medusa-cluster"
      }
    }
  }

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# Output the cluster IP
output "cluster_ip" {
  value = aws_ecs_cluster.medusa_cluster.id
}

resource "aws_ecs_task_definition" "backend" {
  family                   = "medusa-backend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "backend"
      image     = "985539759598.dkr.ecr.ap-south-1.amazonaws.com/medusa-backend:latest"
      essential = true
      portMappings = [
        {
          containerPort = 9000
          hostPort      = 9000
        }
      ]
      environment = [
        {
          name  = "NODE_ENV"
          value = "development"
        },
        {
          name  = "DATABASE_URL"
          value = "postgres://postgres:postgres@postgres:5432/medusa-docker"
        },
        {
          name  = "REDIS_URL"
          value = "redis://cache"
        },
        {
          name  = "MINIO_ENDPOINT"
          value = "http://minio:9000"
        },
        {
          name  = "MINIO_BUCKET"
          value = "medusa-bucket"
        },
        {
          name  = "MINIO_ACCESS_KEY"
          value = "7nR9aSt9LR32Py3o"
        },
        {
          name  = "MINIO_SECRET_KEY"
          value = "ath8oTjP2rLdhY08EwLMUZksvWwhPyGv"
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "backend_service" {
  name            = "backend-service"
  cluster         = aws_ecs_cluster.medusa_cluster.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = 1

  launch_type = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.medusa_subnet.id]
    security_groups  = [aws_security_group.medusa_sg.id]
    assign_public_ip = true
  }
}

resource "aws_ecs_task_definition" "postgres" {
  family                   = "medusa-postgres"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "postgres"
      image     = "985539759598.dkr.ecr.ap-south-1.amazonaws.com/medusa-postgres:latest"
      essential = true
      portMappings = [
        {
          containerPort = 5432
          hostPort      = 5432
        }
      ]
      environment = [
        {
          name  = "POSTGRES_USER"
          value = "postgres"
        },
        {
          name  = "POSTGRES_PASSWORD"
          value = "postgres"
        },
        {
          name  = "POSTGRES_DB"
          value = "medusa-docker"
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "postgres_service" {
  name            = "postgres-service"
  cluster         = aws_ecs_cluster.medusa_cluster.id
  task_definition = aws_ecs_task_definition.postgres.arn
  desired_count   = 1

  launch_type = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.medusa_subnet.id]
    security_groups  = [aws_security_group.medusa_sg.id]
    assign_public_ip = true
  }
}

resource "aws_ecs_task_definition" "redis" {
  family                   = "medusa-redis"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "redis"
      image     = "985539759598.dkr.ecr.ap-south-1.amazonaws.com/medusa-redis:latest"
      essential = true
      portMappings = [
        {
          containerPort = 6379
          hostPort      = 6379
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "redis_service" {
  name            = "redis-service"
  cluster         = aws_ecs_cluster.medusa_cluster.id
  task_definition = aws_ecs_task_definition.redis.arn
  desired_count   = 1

  launch_type = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.medusa_subnet.id]
    security_groups  = [aws_security_group.medusa_sg.id]
    assign_public_ip = true
  }
}

resource "aws_ecs_task_definition" "minio" {
  family                   = "medusa-minio"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "minio"
      image     = "985539759598.dkr.ecr.ap-south-1.amazonaws.com/medusa-minio:latest"
      essential = true
      portMappings = [
        {
          containerPort = 9000
          hostPort      = 9000
        },
        {
          containerPort = 9090
          hostPort      = 9090
        }
      ]
      environment = [
        {
          name  = "MINIO_ROOT_USER"
          value = "ROOTNAME"
        },
        {
          name  = "MINIO_ROOT_PASSWORD"
          value = "CHANGEME123"
        }
      ]
      command = ["server", "/data", "--console-address", ":9090"]
    }
  ])
}

resource "aws_ecs_service" "minio_service" {
  name            = "minio-service"
  cluster         = aws_ecs_cluster.medusa_cluster.id
  task_definition = aws_ecs_task_definition.minio.arn
  desired_count   = 1

  launch_type = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.medusa_subnet.id]
    security_groups  = [aws_security_group.medusa_sg.id]
    assign_public_ip = true
  }
}

resource "aws_ecs_task_definition" "admin" {
  family                   = "medusa-admin"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "admin"
      image     = "985539759598.dkr.ecr.ap-south-1.amazonaws.com/medusa-admin:latest"
      essential = true
      portMappings = [
        {
          containerPort = 7700
          hostPort      = 7700
        }
      ]
      environment = [
        {
          name  = "MEDUSA_BACKEND_URL"
          value = "http://backend:9000"
        },
        {
          name  = "NODE_OPTIONS"
          value = "--openssl-legacy-provider"
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "admin_service" {
  name            = "admin-service"
  cluster         = aws_ecs_cluster.medusa_cluster.id
  task_definition = aws_ecs_task_definition.admin.arn
  desired_count   = 1

  launch_type = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.medusa_subnet.id]
    security_groups  = [aws_security_group.medusa_sg.id]
    assign_public_ip = true
  }
}

resource "aws_ecs_task_definition" "storefront" {
  family                   = "medusa-storefront"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "storefront"
      image     = "985539759598.dkr.ecr.ap-south-1.amazonaws.com/medusa-storefront:latest"
      essential = true
      portMappings = [
        {
          containerPort = 8100
          hostPort      = 8100
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "storefront_service" {
  name            = "storefront-service"
  cluster         = aws_ecs_cluster.medusa_cluster.id
  task_definition = aws_ecs_task_definition.storefront.arn
  desired_count   = 1

  launch_type = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.medusa_subnet.id]
    security_groups  = [aws_security_group.medusa_sg.id]
    assign_public_ip = true
  }
}