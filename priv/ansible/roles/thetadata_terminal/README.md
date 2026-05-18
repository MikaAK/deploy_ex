# thetadata_terminal

Installs the [ThetaData Terminal](https://www.thetadata.net) JAR on a Debian
host and runs it under systemd. The terminal exposes:

| Port  | Protocol  | Purpose                       |
|-------|-----------|-------------------------------|
| 25510 | HTTP REST | Query API                     |
| 25520 | WebSocket | Real-time streaming           |
| 11000 | TCP MDDS  | Query-based market data       |
| 10000 | TCP FPSS  | Streaming market data         |

## Required variables

| Variable                          | Description                              |
|-----------------------------------|------------------------------------------|
| `thetadata_terminal_username`     | ThetaData account email                  |
| `thetadata_terminal_password`     | ThetaData account password               |

Inject from the deploy pipeline (the project's `deploy.yml` uses
`./bin/load-1pw.sh` to pull `op://prod_ex/thetadata/{username,password}` into
the environment before `mix ansible.setup` runs).

## Optional variables

| Variable                          | Default                                          |
|-----------------------------------|--------------------------------------------------|
| `thetadata_terminal_jdk_package`  | `openjdk-21-jre-headless`                        |
| `thetadata_terminal_jar_url`      | `https://download-stable.thetadata.us/ThetaTerminal.jar` |
| `thetadata_terminal_java_opts`    | `-Xms2G -Xmx6G`                                  |
| `thetadata_terminal_home`         | `/opt/theta`                                     |
| `thetadata_terminal_tz`           | `UTC`                                            |

## Hardware

ThetaData recommends 8 GB RAM minimum (16 GB ideal). Match the EC2 size in
`mix terraform.build` when creating a host group for this role.

## Verifying

```bash
systemctl status thetadata-terminal
tail -f /opt/theta/logs/terminal.log
curl http://localhost:25510/v2/list/dates/option/quote
```
