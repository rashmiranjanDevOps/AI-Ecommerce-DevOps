data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------- IAM: an instance role instead of access keys ----------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # shell without opening SSH
}

locals {
  ecr_read_actions = [
    "ecr:BatchGetImage",
    "ecr:GetDownloadUrlForLayer",
    "ecr:BatchCheckLayerAvailability",
    "ecr:DescribeImages",
    "ecr:DescribeRepositories",
  ]
  ecr_push_actions = [
    "ecr:InitiateLayerUpload",
    "ecr:UploadLayerPart",
    "ecr:CompleteLayerUpload",
    "ecr:PutImage",
  ]
  policy_statements = concat(
    [{
      Sid      = "EcrLogin"
      Effect   = "Allow"
      Action   = ["ecr:GetAuthorizationToken"]
      Resource = "*"
    }],
    length(var.ecr_repository_arns) == 0 ? [] : [{
      Sid      = "EcrRepositories"
      Effect   = "Allow"
      Action   = var.ecr_push ? concat(local.ecr_read_actions, local.ecr_push_actions) : local.ecr_read_actions
      Resource = var.ecr_repository_arns
    }],
    var.allow_eks_describe ? [{
      Sid      = "EksDescribe"
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster", "eks:ListClusters"]
      Resource = "*"
    }] : [],
  )
}

resource "aws_iam_role_policy" "this" {
  name = "project-access"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.policy_statements
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-instance"
  role = aws_iam_role.this.name
}

# ---------- network ----------
resource "aws_security_group" "this" {
  name_prefix = "${var.name}-"
  description = "${var.name} server"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.ingress_rules

    content {
      description = ingress.value.description
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = "tcp"
      cidr_blocks = ingress.value.cidrs
    }
  }

  egress {
    description = "All outbound (package installs, ECR, GitHub)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------- server ----------
resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name
  monitoring             = true

  # IMDSv2 only: protects the instance credentials from SSRF attacks.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = var.name }

  lifecycle {
    ignore_changes = [ami] # do not replace the server when Canonical publishes a new image
  }
}

resource "aws_eip" "this" {
  count = var.allocate_eip ? 1 : 0

  domain   = "vpc"
  instance = aws_instance.this.id

  tags = { Name = "${var.name}-eip" }
}
