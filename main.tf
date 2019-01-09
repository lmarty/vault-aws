terraform {
  required_version = ">= 0.11.6"
}

module "consul_auto_join_instance_role" {
  source = "github.com/hashicorp-modules/consul-auto-join-instance-role-aws"

  create = "${var.create ? 1 : 0}"
  name   = "${var.name}"
}

data "aws_ami" "vault" {
  count       = "${var.create && var.image_id == "" ? 1 : 0}"
  most_recent = true
  owners      = ["${var.ami_owner}"]
  name_regex  = "vault-image_${lower(var.release_version)}_vault_${lower(var.vault_version)}_consul_${lower(var.consul_version)}_${lower(var.os)}_${var.os_version}.*"

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "template_file" "vault_init" {
  count    = "${var.create ? 1 : 0}"
  template = "${file("${path.module}/templates/init-systemd.sh.tpl")}"

  vars = {
    name      = "${var.name}"
    user_data = "${var.user_data != "" ? var.user_data : "echo 'No custom user_data'"}"
  }
}

module "vault_server_sg" {
  source = "github.com/hashicorp-modules/vault-server-ports-aws"

  create      = "${var.create ? 1 : 0}"
  name        = "${var.name}-vault-server"
  vpc_id      = "${var.vpc_id}"
  cidr_blocks = ["${var.public_vault ? "0.0.0.0/0" : var.vpc_cidr}"] # If public_vault is true, open Vault ports for public access - DO NOT DO THIS IN PROD
}

module "consul_client_sg" {
  source = "github.com/hashicorp-modules/consul-client-ports-aws"

  create      = "${var.create ? 1 : 0}"
  name        = "${var.name}-vault-consul-client"
  vpc_id      = "${var.vpc_id}"
  cidr_blocks = ["${var.public_consul ? "0.0.0.0/0" : var.vpc_cidr}"] # If public_consul is true, open Consul ports for public access - DO NOT DO THIS IN PROD
}

resource "aws_security_group_rule" "ssh" {
  count = "${var.create ? 1 : 0}"

  security_group_id = "${module.vault_server_sg.vault_server_sg_id}"
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_blocks       = ["${var.public_vault_ssh ? "0.0.0.0/0" : var.vpc_cidr}"] # If public_vault_ssh is true, open port 22 for public access - DO NOT DO THIS IN PROD
}

resource "aws_launch_configuration" "vault" {
  count = "${var.create ? 1 : 0}"

  name_prefix                 = "${format("%s-vault-", var.name)}"
  associate_public_ip_address = "${var.public_vault}"
  ebs_optimized               = false
  instance_type               = "${var.instance_type}"
  image_id                    = "${var.image_id != "" ? var.image_id : element(concat(data.aws_ami.vault.*.id, list("")), 0)}"                     # TODO: Workaround for issue #11210
  iam_instance_profile        = "${var.instance_profile != "" ? var.instance_profile : module.consul_auto_join_instance_role.instance_profile_id}"
  user_data                   = "${data.template_file.vault_init.rendered}"
  key_name                    = "${var.ssh_key_name}"

  security_groups = [
    "${module.vault_server_sg.vault_server_sg_id}",
    "${module.consul_client_sg.consul_client_sg_id}",
  ]

  lifecycle {
    create_before_destroy = true
  }
}

module "vault_lb_aws" {
  source = "github.com/hashicorp-modules/vault-lb-aws"

  create             = "${var.create}"
  name               = "${var.name}"
  vpc_id             = "${var.vpc_id}"
  cidr_blocks        = ["${var.vault_loadbalancer_isinternal ? "0.0.0.0/0" : var.vpc_cidr}"] # If vault_loadbalancer_isinternal is set to true, don't assign a public ip 
  subnet_ids         = ["${var.subnet_ids}"]
  is_internal_lb     = "${!var.vault_loadbalancer_isinternal}"
  use_lb_cert        = "${var.use_lb_cert}"
  lb_cert            = "${var.lb_cert}"
  lb_private_key     = "${var.lb_private_key}"
  lb_cert_chain      = "${var.lb_cert_chain}"
  lb_ssl_policy      = "${var.lb_ssl_policy}"
  lb_bucket          = "${var.lb_bucket}"
  lb_bucket_override = "${var.lb_bucket_override}"
  lb_bucket_prefix   = "${var.lb_bucket_prefix}"
  lb_logs_enabled    = "${var.lb_logs_enabled}"
  tags               = "${var.tags}"
}

resource "aws_autoscaling_group" "vault" {
  count = "${var.create ? 1 : 0}"

  name_prefix          = "${aws_launch_configuration.vault.name}"
  launch_configuration = "${aws_launch_configuration.vault.id}"
  vpc_zone_identifier  = ["${var.subnet_ids}"]
  max_size             = "${var.count != -1 ? var.count : length(var.subnet_ids)}"
  min_size             = "${var.count != -1 ? var.count : length(var.subnet_ids)}"
  desired_capacity     = "${var.count != -1 ? var.count : length(var.subnet_ids)}"
  default_cooldown     = 30
  force_delete         = true

  target_group_arns = ["${compact(concat(
    list(
      module.vault_lb_aws.vault_tg_http_8200_arn,
      module.vault_lb_aws.vault_tg_https_8200_arn,
    ),
    var.target_groups
  ))}"]

  tags = ["${concat(
    list(
      map("key", "Name", "value", format("%s-vault-node", var.name), "propagate_at_launch", true),
      map("key", "Consul-Auto-Join", "value", var.name, "propagate_at_launch", true)
    ),
    var.tags_list
  )}"]

  lifecycle {
    create_before_destroy = true
  }
}
