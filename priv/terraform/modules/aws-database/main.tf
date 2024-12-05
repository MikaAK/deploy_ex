locals {
  db_identifier          = lower(replace(format("%s_%s_%s", var.name, "db", var.environment), " ", "_"))
  db_identifier_kebab    = lower(replace(format("%s-%s-%s", var.name, "db", var.environment), " ", "-"))
  db_subnet_name         = format("%s-%s", local.db_identifier_kebab, "subnet")
  db_parameter_name      = format("%s-%s", local.db_identifier_kebab, "params")
  db_snapshot_identifier = format("%s-final-%s", local.db_identifier_kebab, random_integer.rds_snapshot_postfix.result)
}

resource "random_password" "rds_database_password" {
  length           = 16
  special          = true
  override_special = "-_"
}

### Database Engine ###
######################

data "aws_rds_engine_version" "rds_postgres" {
  engine = "postgres"
}

### Subnet Group ###
###################

resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = local.db_subnet_name
  subnet_ids = var.subnet_ids

  tags = merge({
    Name        = format("%s Database Subnet Group", var.resource_group)
    Group       = var.resource_group
    Environment = var.environment
    Vendor      = "Postgres"
    Type        = "Database"
  }, var.tags)
}

### Parameter Group ###
######################

resource "aws_db_parameter_group" "rds_database_parameter_group" {
  name   = local.db_parameter_name
  family = "${data.aws_rds_engine_version.rds_postgres.engine}${floor(data.aws_rds_engine_version.rds_postgres.version)}"

  description = format("%s %s Database Parameter Group", var.resource_group, var.environment)

  parameter {
    name  = "rds.force_ssl"
    value = "0"
  }

  tags = merge({
    Name        = format("%s Database Parameter Group", var.resource_group)
    Group       = var.resource_group
    Environment = var.environment
    Vendor      = "Postgres"
    Type        = "Database"
  }, var.tags)
}

### Snapshot Identifier ###
##########################

resource "random_integer" "rds_snapshot_postfix" {
  min = 1
  max = 50000
}

### RDS Instance ###
###################

resource "aws_db_instance" "rds_database" {
  # Basic Configuration
  identifier     = local.db_identifier_kebab
  db_name        = local.db_identifier
  engine         = data.aws_rds_engine_version.rds_postgres.engine
  engine_version = data.aws_rds_engine_version.rds_postgres.version
  instance_class = var.instance_type

  # Storage Configuration
  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb

  # Network Configuration
  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [var.security_group_id]

  # Authentication
  username = var.database_username
  password = random_password.rds_database_password.result

  # Parameter Groups
  parameter_group_name = aws_db_parameter_group.rds_database_parameter_group.name

  # Backup Configuration
  final_snapshot_identifier = local.db_snapshot_identifier
  backup_retention_period  = var.backup_retention_period
  backup_window           = var.backup_window
  maintenance_window      = var.maintenance_window

  # High Availability
  multi_az = var.multi_az

  # Monitoring
  performance_insights_enabled          = true
  performance_insights_retention_period = var.performance_insights_retention_period_days

  tags = merge({
    Name        = format("%s DB", var.name)
    Group       = var.resource_group
    Environment = var.environment
    Vendor      = "Postgres"
    Type        = "Database"
  }, var.tags)
}

