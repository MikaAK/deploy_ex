"""
Lambda function to setup autoscaled instances using Ansible via SSM
Triggered by SNS when new instance boots
"""
import json
import boto3
import time
import os

ssm = boto3.client('ssm')
ec2 = boto3.client('ec2')
s3 = boto3.client('s3')

def lambda_handler(event, context):
    """Handle instance setup request"""
    
    # Parse SNS message
    message = json.loads(event['Records'][0]['Sns']['Message'])
    instance_id = message['instance_id']
    app_name = message['app_name']
    environment = message['environment']
    
    print(f"Setting up instance {instance_id} for {app_name} in {environment}")
    
    # Wait for instance to be ready
    wait_for_instance_ready(instance_id)
    
    # Wait for SSM agent to be online
    wait_for_ssm_ready(instance_id)
    
    # Get configuration from environment
    deploy_ex_version = os.environ.get('DEPLOY_EX_VERSION', 'latest')
    ansible_roles = json.loads(os.environ.get('ANSIBLE_ROLES', '[]'))
    
    # Build roles list for playbook
    roles_yaml = '\n'.join([f'    - {role}' for role in ansible_roles])
    
    setup_commands = f"""
#!/bin/bash
set -e

# Install Ansible
apt-get update
apt-get install -y ansible curl jq

# Download ansible roles from DeployEx GitHub release
mkdir -p /tmp/ansible_setup
cd /tmp/ansible_setup

# Get latest or specific DeployEx release
if [ "{deploy_ex_version}" = "latest" ]; then
  RELEASE_URL=$(curl -s https://api.github.com/repos/MikaAK/deploy_ex/releases/latest | jq -r '.assets[] | select(.name=="ansible-roles.tar.gz") | .browser_download_url')
else
  RELEASE_URL="https://github.com/MikaAK/deploy_ex/releases/download/{deploy_ex_version}/ansible-roles.tar.gz"
fi

echo "Downloading Ansible roles from: $RELEASE_URL"
curl -L -o /tmp/ansible-roles.tar.gz "$RELEASE_URL"
tar -xzf /tmp/ansible-roles.tar.gz -C /tmp/ansible_setup

# Create local playbook with configured roles
cat > /tmp/setup_playbook.yml <<'EOF'
---
- hosts: localhost
  connection: local
  become: true
  vars:
    app_name: "{app_name}"
    environment: "{environment}"
  roles:
{roles_yaml}
    - deploy_node
EOF

# Run ansible locally
cd /tmp/ansible_setup
ansible-playbook -i localhost, /tmp/setup_playbook.yml

# Create completion marker
touch /tmp/lambda_setup_complete

echo "Setup complete"
"""
    
    # Execute setup via SSM
    response = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName='AWS-RunShellScript',
        Parameters={'commands': [setup_commands]},
        TimeoutSeconds=600
    )
    
    command_id = response['Command']['CommandId']
    print(f"Sent SSM command {command_id} to {instance_id}")
    
    # Wait for completion
    wait_for_command_completion(command_id, instance_id)
    
    return {
        'statusCode': 200,
        'body': json.dumps(f'Setup completed for {instance_id}')
    }

def wait_for_instance_ready(instance_id, max_wait=300):
    """Wait for instance to be in running state"""
    print(f"Waiting for instance {instance_id} to be ready...")
    start = time.time()
    
    while time.time() - start < max_wait:
        response = ec2.describe_instance_status(InstanceIds=[instance_id])
        if response['InstanceStatuses']:
            status = response['InstanceStatuses'][0]
            if status['InstanceState']['Name'] == 'running':
                print(f"Instance {instance_id} is running")
                return
        time.sleep(5)
    
    raise Exception(f"Instance {instance_id} not ready after {max_wait}s")

def wait_for_ssm_ready(instance_id, max_wait=300):
    """Wait for SSM agent to be online"""
    print(f"Waiting for SSM agent on {instance_id}...")
    start = time.time()
    
    while time.time() - start < max_wait:
        try:
            response = ssm.describe_instance_information(
                Filters=[{'Key': 'InstanceIds', 'Values': [instance_id]}]
            )
            if response['InstanceInformationList']:
                print(f"SSM agent online on {instance_id}")
                return
        except:
            pass
        time.sleep(5)
    
    raise Exception(f"SSM agent not ready on {instance_id} after {max_wait}s")

def wait_for_command_completion(command_id, instance_id, max_wait=600):
    """Wait for SSM command to complete"""
    print(f"Waiting for command {command_id} to complete...")
    start = time.time()
    
    while time.time() - start < max_wait:
        response = ssm.get_command_invocation(
            CommandId=command_id,
            InstanceId=instance_id
        )
        
        status = response['Status']
        print(f"Command status: {status}")
        
        if status == 'Success':
            print("Setup completed successfully")
            return
        elif status in ['Failed', 'Cancelled', 'TimedOut']:
            output = response.get('StandardErrorContent', '')
            raise Exception(f"Setup failed: {status}\n{output}")
        
        time.sleep(10)
    
    raise Exception(f"Command {command_id} timed out after {max_wait}s")
