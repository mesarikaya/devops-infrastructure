# Define a local block to compute the tags
locals {
  common_tags = {
    Terraform   = "true"
    Environment = var.environment
    Project     = "devops-code-project"
  }
  kubernetes_tags = {
    cluster_name = "${var.environment}-devops-cluster"
  }
  security_group_tags = {
    name = "${var.environment}-security_group"
  }

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.environment}-devops-cluster" = "shared"
    "kubernetes.io/role/elb"                                  = 1
    "type"                                                    = "public"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.environment}-devops-cluster" = "shared"
    "kubernetes.io/role/internal-elb"                         = 1
    "type"                                                    = "private"
  }
}

# Configure the AWS Provider
provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_secretsmanager_secret_version" "ec2_private_key" {
  secret_id = "dev/infra"
}

/*locals {
  private_key = data.aws_secretsmanager_secret_version.ec2_private_key.secret_string
}
 */


module "vpc" {
  source                   = "./modules/vpc"
  vpc_name                 = var.vpc_name
  vpc_cidr                 = var.vpc_cidr
  vpc_azs                  = data.aws_availability_zones.available.names
  vpc_private_subnets      = var.vpc_private_subnets
  vpc_public_subnets       = var.vpc_public_subnets
  vpc_enable_nat_gateway   = var.vpc_enable_nat_gateway
  vpc_single_nat_gateway   = var.vpc_single_nat_gateway
  vpc_enable_dns_hostnames = var.vpc_enable_dns_hostnames
  vpc_common_tags          = local.common_tags
  public_subnet_tags       = local.public_subnet_tags
  private_subnet_tags      = local.private_subnet_tags
}

# Create an AMI data for latest linux image from amazon
data "aws_ami" "latest_amazon_linux_x86" {
  most_recent = true
  filter {
    name   = "image-id"
    values = ["ami-05ccf7ebc9a8216aa"]
  }
  /* filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-lunar-23.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  } */

  owners = ["amazon"]
}

resource "aws_key_pair" "ec2_key_pair" {
  key_name   = "ec2_key_pair"
  public_key = file(var.ec2_public_key)
}

module "ssh_security" {
  source              = "./modules/security_groups"
  security_group_name = "${local.security_group_tags.name}-ssh"
  vpc_id              = module.vpc.vpc_id
  allowed_ports       = var.allowed_ssh_ports
  security_group_tags = merge(
    local.common_tags,
    {
      name = "ssh-security-group-${var.environment}"
    }
  )
}

module "http_security" {
  source              = "./modules/security_groups"
  security_group_name = "${local.security_group_tags.name}-tcp"
  vpc_id              = module.vpc.vpc_id
  allowed_ports       = var.allowed_http_ports
  security_group_tags = merge(
    local.common_tags,
    {
      name = "tcp-security-group-${var.environment}"
    }
  )
}

# Create iam role to jenkins instance to be able to do actions on ec2 instances
module "iam" {
  source = "./modules/iam"
}

#Create Ansible Instance
resource "aws_instance" "ansible_control_plane" {
  ami           = data.aws_ami.latest_amazon_linux_x86.id
  instance_type = "t3.micro"
  vpc_security_group_ids = [
    module.ssh_security.security_group_id,
  ]
  subnet_id                   = module.vpc.public_subnets[0]
  key_name                    = aws_key_pair.ec2_key_pair.key_name
  associate_public_ip_address = true

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(local.common_tags, {
    Name = "bastion-host-ansible"
  })

  user_data                   = file("scripts/ansible_setup.sh")
  user_data_replace_on_change = true
}

# Create Jenkins master and slave instances
resource "aws_instance" "jenkins_instance" {
  count         = var.jenkins_ec2_instance_count
  ami           = data.aws_ami.latest_amazon_linux_x86.id
  instance_type = "t3.micro"
  vpc_security_group_ids = [
    module.ssh_security.security_group_id,
    module.http_security.security_group_id
  ]
  subnet_id                   = module.vpc.public_subnets[0]
  key_name                    = aws_key_pair.ec2_key_pair.key_name
  iam_instance_profile        = module.iam.iam_jenkins_instance_profile_name
  associate_public_ip_address = true
  disable_api_termination     = true

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(local.common_tags, {
    Name = "${var.jenkins_instance_names[count.index]}"
  })

  depends_on = [aws_instance.ansible_control_plane ]
}


#Transfer private key to allow ansible control the nodes"
resource "null_resource" "transfer_private_key" {
  triggers = {
    always_run = "${timestamp()}"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(".private/ec2_key_pair")
    host        = aws_instance.ansible_control_plane.public_ip
  }

  provisioner "file" {
    source      = "${path.module}/.private/ec2_key_pair"
    destination = "/tmp/ec2_key_pair.pem"
  }

  # Move private key
  provisioner "remote-exec" {

    inline = [
      "sudo mv /tmp/ec2_key_pair.pem /opt/ec2_key_pair.pem",
      "sudo chown root:root /opt/ec2_key_pair.pem",
      "sudo chmod 400 /opt/ec2_key_pair.pem"
    ]
  }

  depends_on = [aws_instance.ansible_control_plane, aws_instance.jenkins_instance]
}

# Generate host file to register the managed nodes"
resource "null_resource" "generate_hosts_file" {

  triggers = {
    always_run = "${timestamp()}"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(".private/ec2_key_pair")
    host        = aws_instance.ansible_control_plane.public_ip
  }

  provisioner "local-exec" {
    command = "bash scripts/prepare_ansible_instance.sh"
    environment = {
      ANSIBLE_IP       = aws_instance.ansible_control_plane.public_ip
      JENKINS_IP       = aws_instance.jenkins_instance[0].private_ip
      JENKINS_SLAVE_IP = aws_instance.jenkins_instance[1].private_ip
    }
  }

  provisioner "file" {
    source      = "${path.module}/hosts"
    destination = "/tmp/hosts"
  }

  # Install ansible
  provisioner "remote-exec" {

    inline = [
      "sudo mv /tmp/hosts /opt/hosts",
      "sudo chown root:root /opt/hosts"
    ]
  }

  # "sudo chmod 400 /opt/ec2_key_pair.pem"
  depends_on = [aws_instance.ansible_control_plane, aws_instance.jenkins_instance[0], aws_instance.jenkins_instance[1]]
}


# Transfer playbooks 
resource "null_resource" "transfer_jenkins_master_playbook" {
  triggers = {
    always_run = "${timestamp()}"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(".private/ec2_key_pair")
    host        = aws_instance.ansible_control_plane.public_ip
  }

  # Transfer jenkins playbook
  provisioner "file" {
    source      = "${path.module}/ansible/playbooks/jenkins-master-setup.yml"
    destination = "/tmp/jenkins-master-setup.yml"
  }

  provisioner "remote-exec" {

    inline = [
      "sudo mv /tmp/jenkins-master-setup.yml /opt/jenkins-master-setup.yml",
      "sudo chown root:root /opt/jenkins-master-setup.yml",
    ]
  }

  depends_on = [aws_instance.ansible_control_plane]
}

resource "null_resource" "transfer_jenkins_slave_playbook" {
  triggers = {
    always_run = "${timestamp()}"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(".private/ec2_key_pair")
    host        = aws_instance.ansible_control_plane.public_ip
  }

  # Transfer jenkins playbook
  provisioner "file" {
    source      = "${path.module}/ansible/playbooks/jenkins-slave-setup.yml"
    destination = "/tmp/jenkins-slave-setup.yml"
  }

  provisioner "remote-exec" {

    inline = [
      "sudo mv /tmp/jenkins-slave-setup.yml /opt/jenkins-slave-setup.yml",
      "sudo chown root:root /opt/jenkins-slave-setup.yml",
    ]
  }

  depends_on = [aws_instance.ansible_control_plane]
}

resource "null_resource" "install_jenkins" {

  triggers = {
    always_run = "${timestamp()}"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(".private/ec2_key_pair")
    host        = aws_instance.ansible_control_plane.public_ip
  }

  #install jenkins
  provisioner "remote-exec" {

    inline = [
      "while [ ! -x $(command -v ansible-playbook) ]; do",
      "  echo 'Waiting for Ansible to become available...'",
      "  sleep 5",
      "done",
      "sudo ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i /opt/hosts /opt/jenkins-master-setup.yml",
      "echo 'Jenkins master installation Complete'"
    ]
  }

  depends_on = [
    aws_instance.ansible_control_plane,
    aws_instance.jenkins_instance[0],
    null_resource.generate_hosts_file,
    null_resource.transfer_jenkins_master_playbook
  ]
}

resource "null_resource" "install_jenkins_slave" {

  triggers = {
    always_run = "${timestamp()}"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(".private/ec2_key_pair")
    host        = aws_instance.ansible_control_plane.public_ip
  }

  #install jenkins slave librarires
  provisioner "remote-exec" {

    inline = [
      "while [ ! -x $(command -v ansible-playbook) ]; do",
      "  echo 'Waiting for Ansible to become available...'",
      "  sleep 5",
      "done",
      "sudo ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i /opt/hosts /opt/jenkins-slave-setup.yml",
      "echo 'Jenkins slave installation Complete'"
    ]
  }

  depends_on = [
    aws_instance.ansible_control_plane,
    aws_instance.jenkins_instance[1],
    null_resource.generate_hosts_file,
    null_resource.transfer_jenkins_slave_playbook
  ]
}

module "kubernetes_cluster" {
  source                           = "./modules/eks"
  environment                      = var.environment
  kubernetes_tags                  = local.kubernetes_tags
  cluster_master_role_arn          = module.iam.iam_eks_master_role_arn
  cluster_node_role_arn            = module.iam.iam_eks_worker_role_arn
  ec2_ssh_key                      = aws_key_pair.ec2_key_pair.key_name
  ec2_ssh_security_group_ids       = [module.ssh_security.security_group_id]
  node_group_name                  = "${local.kubernetes_tags.cluster_name}-node-group"
  subnet_ids                       = module.vpc.private_subnets
  eks_cluster_policy               = module.iam.eks_cluster_policy
  eks_service_policy               = module.iam.eks_service_policy
  eks_vpc_resource_controller      = module.iam.eks_vpc_resource_controller
  eks_worker_node_policy           = module.iam.eks_worker_node_policy
  eks_cni_policy                   = module.iam.eks_cni_policy
  eks_container_registry_read_only = module.iam.eks_container_registry_read_only
}

resource "null_resource" "transfer_jenkins_slave_install_clis_playbook_and_run" {

  triggers = {
    always_run = "${timestamp()}"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(".private/ec2_key_pair")
    host        = aws_instance.ansible_control_plane.public_ip
  }

  # Transfer jenkins playbook
  provisioner "file" {
    source      = "${path.module}/ansible/playbooks/jenkins-slave-install-clis.yml"
    destination = "/tmp/jenkins-slave-install-clis.yml"
  }

  provisioner "remote-exec" {

    inline = [
      "sudo mv /tmp/jenkins-slave-install-clis.yml /opt/jenkins-slave-install-clis.yml",
      "sudo chown root:root /opt/jenkins-slave-install-clis.yml",
    ]
  }

  provisioner "remote-exec" {

    inline = [
      "while [ ! -x $(command -v ansible-playbook) ]; do",
      "  echo 'Waiting for Ansible to become available...'",
      "  sleep 5",
      "done",
      "sudo ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i /opt/hosts /opt/jenkins-slave-install-clis.yml --extra-vars 'aws_region=${var.region} eks_cluster_name=${local.kubernetes_tags.cluster_name}'",
      "echo 'AWS CLI and Kubectl CLI installation on Jenkins slave instance is Complete'",
    ]
  }

  depends_on = [
    aws_instance.ansible_control_plane,
    aws_instance.jenkins_instance[1],
    module.iam, module.kubernetes_cluster,
    null_resource.install_jenkins_slave
  ]
}


resource "null_resource" "transfer_jenkins_slave_deploy_monitoring_stack" {

  triggers = {
    always_run = "${timestamp()}"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(".private/ec2_key_pair")
    host        = aws_instance.ansible_control_plane.public_ip
  }

  # Transfer jenkins playbook
  provisioner "file" {
    source      = "${path.module}/ansible/playbooks/monitoring/jenkins-slave-install-monitoring-stack.yml"
    destination = "/tmp/jenkins-slave-install-monitoring-stack.yml"
  }

  provisioner "remote-exec" {

    inline = [
      "sudo mv /tmp/jenkins-slave-install-monitoring-stack.yml /opt/jenkins-slave-install-monitoring-stack.yml",
      "sudo chown root:root /opt/jenkins-slave-install-monitoring-stack.yml",
    ]
  }

  provisioner "remote-exec" {

    inline = [
      "while [ ! -x $(command -v ansible-playbook) ]; do",
      "  echo 'Waiting for Ansible to become available...'",
      "  sleep 5",
      "done",
      "sudo ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i /opt/hosts /opt/jenkins-slave-install-monitoring-stack.yml --extra-vars 'aws_region=${var.region} eks_cluster_name=${local.kubernetes_tags.cluster_name}'",
      "echo 'Monitoring Stack installation is complete on slave instance'",
    ]
  }

  depends_on = [
    aws_instance.ansible_control_plane,
    aws_instance.jenkins_instance[1],
    module.iam, module.kubernetes_cluster,
    null_resource.generate_hosts_file,
    null_resource.install_jenkins_slave,
    null_resource.transfer_jenkins_slave_install_clis_playbook_and_run
  ]
}


# Create CodeArtifactory
module "code_artifactory" {
  source                         = "./modules/codeartifactory"
  artifact_domain_key            = "devops-domain-key-${var.environment}"
  artifact_domain                = "${var.domain_name}-${var.environment}"
  maven_artifact_repository_name = "${var.environment}-maven-repo-${var.codeartifact_repository_name}"
  npm_artifact_repository_name   = "${var.environment}-npm-repo-${var.codeartifact_repository_name}"
}

module "container_repository" {
  source                    = "./modules/container_repository"
  container_repository_name = "${var.environment}-devops-container-repository"
}

moved {
  from = aws_security_group.ec2_instance_ssh_sg
  to   = module.ssh_security.aws_security_group.security_group
}

moved {
  from = aws_vpc_security_group_ingress_rule.ec2_ssh_inbound
  to   = module.ssh_security.aws_vpc_security_group_ingress_rule.ingress_rule
}

moved {
  from = aws_security_group.ec2_instance_http_sg
  to   = module.http_security.aws_security_group.security_group
}

moved {
  from = aws_vpc_security_group_ingress_rule.ec2_tcp_inbound
  to   = module.http_security.aws_vpc_security_group_ingress_rule.ingress_rule
}

moved {
  from = aws_vpc_security_group_egress_rule.ec2_ssh_outbound
  to   = module.ssh_security.aws_vpc_security_group_egress_rule.eggress_rule
}

moved {
  from = aws_vpc_security_group_egress_rule.ec2_tcp_outbound
  to   = module.http_security.aws_vpc_security_group_egress_rule.eggress_rule
}

moved {
  from = module.iam_jenkins_role
  to   = module.iam
}
