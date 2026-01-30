# SSL Certificate Migration to Let's Encrypt

This document describes the migration from Elixir's SiteEncrypt to system-managed Let's Encrypt certificates using DNS challenge for load balancer compatibility.

## Overview

The SSL certificate management has been moved from the Elixir application to the system level using:
- Let's Encrypt with certbot
- DNS challenge via Cloudflare (for load balancer compatibility)
- Ansible for automation
- systemd for automatic renewal

## DNS Challenge for Load Balancer Setups

Since nodes are behind a load balancer and share the same domain (e.g., app.cheddarflow.com), the HTTP challenge method won't work reliably. Instead, we use:

**DNS Challenge with Cloudflare**:
- Any node can obtain/renew certificates independently
- No need for direct HTTP access to individual nodes
- Works seamlessly with load balancer configurations
- Requires Cloudflare API token with Zone:DNS:Edit permissions

## Changes Made

### 1. Ansible Role: letsencrypt
Created a new Ansible role at `/deploys/ansible/roles/letsencrypt/` that:
- Installs certbot and Cloudflare DNS plugin
- Creates Cloudflare credentials file for DNS challenge
- Creates certificate renewal scripts
- Sets up systemd service and timer for automatic renewal
- Checks certificates on boot and obtains/renews as needed

### 2. Endpoint Configuration Updates
Updated all Phoenix endpoints to:
- Remove `SiteEncrypt.Phoenix.Endpoint` usage
- Use standard `Phoenix.Endpoint`
- Configure HTTPS with system certificate paths
- Remove SiteEncrypt certification callback

### 3. Dependencies Removed
Removed from all affected `mix.exs` files:
- `{:site_encrypt, "~> 0.6"}`
- `{:x509, "~> 0.9", override: true}`

### 4. Runtime Configuration
Updated `config/runtime.exs` to use system certificates:
```elixir
https: [
  port: 443,
  cipher_suite: :strong,
  otp_app: :app_name,
  keyfile: System.get_env("SSL_KEY_PATH", "/etc/letsencrypt/live/#{hostname}/privkey.pem"),
  certfile: System.get_env("SSL_CERT_PATH", "/etc/letsencrypt/live/#{hostname}/fullchain.pem"),
  transport_options: [socket_opts: [:inet6]]
]
```

## Deployment

### Prerequisites
1. Cloudflare account with the domain managed
2. Cloudflare API token with Zone:DNS:Edit permissions
3. Cloudflare API token stored in Ansible vault:
   - `vault_cloudflare_api_token`

### Testing with CMS First

To test the SSL setup, deploy to CMS first:
```bash
ansible-playbook -i inventory playbooks/cfx_cms.yaml
```

After deployment, verify the SSL setup on the CMS server:
```bash
/usr/local/bin/verify-ssl.sh
```

This script will check:
- Certificate files exist and are valid
- Certificate matches the domain
- Route53 credentials are properly configured
- Systemd services are running
- CMS service status

Once verified working on CMS, the same approach can be applied to other web services.

### Production Deployment

The deployment playbooks include the letsencrypt role:
- `cfx_cms.yaml` (test target)
- `cfx_web.yaml`
- `cfx_hooks_web.yaml`

### Certificate Management

### Certificate Locations
Certificates are stored at:
- Private key: `/etc/letsencrypt/live/<domain>/privkey.pem`
- Full chain: `/etc/letsencrypt/live/<domain>/fullchain.pem`
- Cloudflare credentials: `/etc/letsencrypt/cloudflare-credentials.ini` (600 permissions)

### DNS Challenge Process
1. Certbot creates a TXT record in Cloudflare for domain validation
2. Let's Encrypt validates via DNS (not HTTP)
3. Certificate is issued and stored locally
4. TXT record is automatically cleaned up

### Automatic Renewal
- systemd timer checks daily for certificate renewal
- Certificates are renewed if expiring within 7 days
- Services are automatically restarted after renewal

### Manual Renewal
To manually renew certificates:
```bash
/usr/local/bin/renew-certificates.sh
```

### Environment Variables
Optional environment variables can override certificate paths:
- `SSL_KEY_PATH`: Path to private key
- `SSL_CERT_PATH`: Path to certificate chain
- `HOSTNAME`: Domain name for certificates

## Verification

1. Check certificate status:
   ```bash
   openssl x509 -in /etc/letsencrypt/live/cheddarflow.com/fullchain.pem -noout -dates
   ```

2. Check renewal timer:
   ```bash
   systemctl status cert-renewal.timer
   ```

3. View renewal logs:
   ```bash
   journalctl -u cert-renewal
   ```

## Troubleshooting

### Certificate Issues
- Check nginx configuration: `/etc/nginx/sites-available/default`
- Verify certificate permissions: `ls -la /etc/letsencrypt/live/`
- Check certbot logs: `journalctl -u certbot`

### Service Issues
- Restart services after certificate changes:
  ```bash
  systemctl restart cfx-web
  systemctl restart cfx-cms
  systemctl restart cfx-hooks
  ```

## Security Notes

- Certificates are stored with restricted permissions (root only)
- Cloudflare credentials file has 600 permissions and is owned by root
- Let's Encrypt accounts use email: admin@cheddarflow.com
- DNS challenge avoids exposing services directly to the internet
- Only strong cipher suites are enabled
- Cloudflare API token should have minimum necessary permissions:

**Required API Token Permissions:**
- Zone:Zone:Read
- Zone:DNS:Edit
- Zone:Zone Settings:Read

**Token Scope:**
- Zone Resources: Include specific zones or all zones
- Account Resources: Not needed for DNS validation only
