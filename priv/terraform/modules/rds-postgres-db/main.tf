module "db" {
  source               = "terraform-aws-modules/rds/aws"
  identifier           = replace(var.db_name, "_", "-")
  family               = "postgres14"
  major_engine_version = "14"
  engine               = "postgres"
  engine_version       = "14.22"
  instance_class       = "db.t4g.medium"
  allocated_storage    = var.allocated_storage
  db_name              = var.db_name
  username             = "postgres"
  port                 = "5432"
  deletion_protection  = true
  maintenance_window   = "Sun:00:00-Sun:03:00"
  backup_window        = "03:00-06:00"

  iam_database_authentication_enabled = true

  vpc_security_group_ids = [var.security_group_id]
  create_db_subnet_group = true
  subnet_ids             = var.subnet_ids
}
