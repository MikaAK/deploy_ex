defmodule DeployEx.ChangePlannerTest do
  use ExUnit.Case, async: true

  alias DeployEx.ChangePlanner

  setup do
    base = Path.join(System.tmp_dir!(), "change_planner_test_#{System.unique_integer([:positive])}")
    upstream = Path.join(base, "upstream")
    user = Path.join(base, "user")
    File.mkdir_p!(upstream)
    File.mkdir_p!(user)
    on_exit(fn -> File.rm_rf!(base) end)
    %{upstream: upstream, user: user}
  end

  describe "plan/3" do
    test "empty directories produce empty plan", %{upstream: upstream, user: user} do
      assert {:ok, []} === ChangePlanner.plan(upstream, user)
    end

    test "identical files produce {:identical, path}", %{upstream: upstream, user: user} do
      content = "resource \"aws_instance\" \"web\" {\n  ami = \"ami-123\"\n}\n"

      write_file!(upstream, "terraform/ec2.tf", content)
      write_file!(user, "terraform/ec2.tf", content)

      assert {:ok, actions} = ChangePlanner.plan(upstream, user)
      assert {:identical, "terraform/ec2.tf"} in actions
    end

    test "same path different content produces {:update, path, path}", %{upstream: upstream, user: user} do
      write_file!(upstream, "terraform/ec2.tf", "resource \"aws_instance\" \"web\" {\n  ami = \"ami-456\"\n}\n")
      write_file!(user, "terraform/ec2.tf", "resource \"aws_instance\" \"web\" {\n  ami = \"ami-123\"\n}\n")

      assert {:ok, actions} = ChangePlanner.plan(upstream, user)
      assert {:update, "terraform/ec2.tf", "terraform/ec2.tf"} in actions
    end

    test "upstream-only file produces {:new, path}", %{upstream: upstream, user: user} do
      write_file!(upstream, "terraform/new_resource.tf", "resource \"aws_s3_bucket\" \"logs\" {}\n")

      assert {:ok, actions} = ChangePlanner.plan(upstream, user)
      assert {:new, "terraform/new_resource.tf"} in actions
    end

    test "user-only file produces {:user_only, path}", %{upstream: upstream, user: user} do
      write_file!(user, "terraform/my_custom.tf", "resource \"aws_custom\" \"thing\" {}\n")

      assert {:ok, actions} = ChangePlanner.plan(upstream, user)
      assert {:user_only, "terraform/my_custom.tf"} in actions
    end

    test "renamed file with high similarity produces {:rename, upstream, user}", %{upstream: upstream, user: user} do
      base_content = """
      resource "aws_instance" "web" {
        ami           = "ami-12345678"
        instance_type = "t2.micro"
        tags = {
          Name = "web-server"
          Environment = "production"
        }
      }

      resource "aws_security_group" "web" {
        name = "web-sg"
        ingress {
          from_port   = 80
          to_port     = 80
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }
      """

      # Slightly modified version (user renamed file and tweaked a value)
      user_content = """
      resource "aws_instance" "web" {
        ami           = "ami-12345678"
        instance_type = "t2.small"
        tags = {
          Name = "web-server"
          Environment = "production"
        }
      }

      resource "aws_security_group" "web" {
        name = "web-sg"
        ingress {
          from_port   = 80
          to_port     = 80
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }
      """

      write_file!(upstream, "terraform/ec2.tf", base_content)
      write_file!(user, "terraform/my_ec2.tf", user_content)

      assert {:ok, actions} = ChangePlanner.plan(upstream, user)
      assert {:rename, "terraform/ec2.tf", "terraform/my_ec2.tf"} in actions
    end

    test "low similarity upstream-only and user-only stay separate", %{upstream: upstream, user: user} do
      write_file!(upstream, "terraform/rds.tf", "resource \"aws_db_instance\" \"main\" {\n  engine = \"postgres\"\n}\n")
      write_file!(user, "ansible/custom_role.yml", "---\n- name: Install custom packages\n  apt:\n    name: htop\n")

      assert {:ok, actions} = ChangePlanner.plan(upstream, user)
      assert {:new, "terraform/rds.tf"} in actions
      assert {:user_only, "ansible/custom_role.yml"} in actions
    end

    test "dotfiles and .md files are skipped", %{upstream: upstream, user: user} do
      write_file!(upstream, ".gitignore", "*.tfstate\n")
      write_file!(upstream, "README.md", "# Deploy\n")
      write_file!(upstream, "terraform/main.tf", "provider \"aws\" {}\n")
      write_file!(user, "terraform/main.tf", "provider \"aws\" {}\n")

      assert {:ok, actions} = ChangePlanner.plan(upstream, user)
      assert length(actions) === 1
      assert {:identical, "terraform/main.tf"} in actions
    end

    test "results are sorted by action type", %{upstream: upstream, user: user} do
      # identical
      write_file!(upstream, "terraform/a.tf", "same content")
      write_file!(user, "terraform/a.tf", "same content")

      # update
      write_file!(upstream, "terraform/b.tf", "upstream version")
      write_file!(user, "terraform/b.tf", "user version")

      # new
      write_file!(upstream, "terraform/c.tf", "brand new file")

      # user_only
      write_file!(user, "terraform/d.tf", "user custom file")

      assert {:ok, actions} = ChangePlanner.plan(upstream, user)

      action_types = Enum.map(actions, &elem(&1, 0))

      # Verify ordering: identical < update < new < user_only
      identical_idx = Enum.find_index(action_types, &(&1 === :identical))
      update_idx = Enum.find_index(action_types, &(&1 === :update))
      new_idx = Enum.find_index(action_types, &(&1 === :new))
      user_only_idx = Enum.find_index(action_types, &(&1 === :user_only))

      assert identical_idx < update_idx
      assert update_idx < new_idx
      assert new_idx < user_only_idx
    end

    test "nested directory structure is handled", %{upstream: upstream, user: user} do
      write_file!(upstream, "terraform/modules/vpc/main.tf", "module content")
      write_file!(user, "terraform/modules/vpc/main.tf", "module content")

      assert {:ok, actions} = ChangePlanner.plan(upstream, user)
      assert {:identical, "terraform/modules/vpc/main.tf"} in actions
    end

    test "split detection when upstream content appears in multiple user files", %{upstream: upstream, user: user} do
      # Upstream has a combined file
      combined = """
      resource "aws_instance" "web" {
        ami           = "ami-12345678"
        instance_type = "t2.micro"
        tags = { Name = "web-server" }
      }

      resource "aws_security_group" "web" {
        name = "web-sg"
        ingress {
          from_port   = 80
          to_port     = 80
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }

      resource "aws_lb" "web" {
        name               = "web-lb"
        internal           = false
        load_balancer_type = "application"
      }
      """

      # User split it into parts (each containing substantial overlap)
      part1 = """
      resource "aws_instance" "web" {
        ami           = "ami-12345678"
        instance_type = "t2.micro"
        tags = { Name = "web-server" }
      }

      resource "aws_security_group" "web" {
        name = "web-sg"
        ingress {
          from_port   = 80
          to_port     = 80
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }
      """

      part2 = """
      resource "aws_lb" "web" {
        name               = "web-lb"
        internal           = false
        load_balancer_type = "application"
      }

      resource "aws_security_group" "web" {
        name = "web-sg"
        ingress {
          from_port   = 80
          to_port     = 80
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }
      """

      write_file!(upstream, "terraform/infra.tf", combined)
      write_file!(user, "terraform/compute.tf", part1)
      write_file!(user, "terraform/loadbalancer.tf", part2)

      assert {:ok, actions} = ChangePlanner.plan(upstream, user)

      split_action = Enum.find(actions, fn
        {:split, _, _} -> true
        _ -> false
      end)

      assert {:split, "terraform/infra.tf", user_paths} = split_action
      assert "terraform/compute.tf" in user_paths
      assert "terraform/loadbalancer.tf" in user_paths
    end
  end

  defp write_file!(dir, relative_path, content) do
    full_path = Path.join(dir, relative_path)

    full_path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(full_path, content)
  end
end
