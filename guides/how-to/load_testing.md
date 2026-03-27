# How to Run Load Tests

k6-based load testing with dedicated EC2 runner instances.

## Setup

```bash
mix deploy_ex.load_test.init my_app                         # scaffold test scripts
mix deploy_ex.load_test.create_instance [--instance-type t3.small]  # provision runner
```

## Upload and Execute

```bash
mix deploy_ex.load_test.upload --script load_test.js
mix deploy_ex.load_test.exec --target-url http://api.myapp.com --prometheus-url http://...
```

Metrics are pushed to Prometheus via k6's remote write integration.

## Manage Runners

```bash
mix deploy_ex.load_test.list                    # list active runners
mix deploy_ex.load_test.destroy_instance        # clean up
mix deploy_ex.load_test.destroy_instance --all  # clean up all
```

See also: [Mix Tasks Reference](../reference/mix_tasks.md)
