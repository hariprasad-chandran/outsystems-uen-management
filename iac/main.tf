terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "OutSystems-UEN-Platform"
      Environment = "Production"
      ManagedBy   = "Terraform"
    }
  }
}

variable "aws_region" {
  default = "ap-southeast-1"
}

# --- 1. Networking (VPC across 2 AZs) ---
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "outsystems-vpc" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "outsystems-public-${count.index + 1}" }
}

resource "aws_subnet" "private_app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "outsystems-private-app-${count.index + 1}" }
}

resource "aws_subnet" "private_db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 20}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "outsystems-private-db-${count.index + 1}" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- 2. Security Groups ---
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Public HTTP/HTTPS access"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app_sg" {
  name        = "outsystems-app-sg"
  description = "Allow inbound from ALB and inter-node deployment orchestration"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  ingress {
    from_port   = 12000
    to_port     = 12001
    protocol    = "tcp"
    self        = true # Deployment Service communication
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db_sg" {
  name        = "outsystems-db-sg"
  description = "Allow SQL Server inbound from Application tier only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 1433
    to_port         = 1433
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- 3. Database Layer (Multi-AZ SQL Server) ---
resource "aws_db_subnet_group" "db" {
  name       = "outsystems-db-subnet-group"
  subnet_ids = aws_subnet.private_db[*].id
}

resource "aws_db_instance" "outsystems_db" {
  identifier             = "outsystems-sql-db"
  engine                 = "sqlserver-se"
  engine_version         = "15.00.4385.2.v1"
  instance_class         = "db.m5.xlarge"
  allocated_storage      = 100
  multi_az               = true
  publicly_accessible    = false
  username               = "outsystems_admin"
  password               = "TempPassword2026!ChangeMe"
  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  skip_final_snapshot    = true
}

# --- 4. Compute Layer (Deployment Controller & Front-Ends) ---
resource "aws_instance" "deployment_controller" {
  ami                    = "ami-0c55b159cbfafe1f0" # Placeholder Windows Server 2022 AMI
  instance_type          = "m5.xlarge"
  subnet_id              = aws_subnet.private_app[0].id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  tags                   = { Name = "outsystems-controller" }
}

# --- 5. Application Load Balancer ---
resource "aws_lb" "alb" {
  name               = "outsystems-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "app_tg" {
  name     = "outsystems-app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path     = "/UENManagement/uenlist"
    protocol = "HTTP"
    matcher  = "200-399"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}
