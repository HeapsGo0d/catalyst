# Docker Security Recommendations

This document outlines the security configurations and best practices recommended for running the Catalyst Docker container.

## Core Security Options

When running the container, always include these security flags:

```bash
docker run \
  --security-opt=no-new-privileges \  # Prevent privilege escalation
  --cap-drop=ALL \                   # Drop all capabilities
  # ... other parameters ...
```

### Explanation of Flags:
- `--security-opt=no-new-privileges`: Prevents the container from gaining additional privileges during runtime, mitigating privilege escalation attacks.
- `--cap-drop=ALL`: Drops all Linux capabilities by default. If specific capabilities are required, use `--cap-add` to grant them individually.

## Security Environment Variables

The Dockerfile supports these security-related environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `PARANOID_MODE` | `false` | Enables maximum security restrictions (future implementation) |
| `SECURITY_LEVEL` | `normal` | Sets security level (`normal`, `high`, `maximum`) |
| `NETWORK_MODE` | `public` | Controls network accessibility (`public`, `restricted`, `isolated`) |
| `ENABLE_FORENSIC_CLEANUP` | `false` | Enables secure wipe of sensitive data at shutdown |
| `SECURITY_TOKEN_VAULT_PATH` | "" | Path to encrypted token storage (future implementation) |

## Security Best Practices

1. **Non-root User Execution**:
   - The container runs as `comfyuser` (UID 1000) by default
   - Implemented via `USER comfyuser` in Dockerfile

2. **File Permissions**:
   - Application files are owned by `comfyuser`
   - Sensitive directories have strict permissions:
     ```dockerfile
     RUN chown -R comfyuser:comfyuser /home/comfyuser
     RUN chown -R comfyuser:comfyuser /workspace
     ```

3. **Build-time Security**:
   - Minimal base image (`nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04`)
   - APT cache cleanup to reduce attack surface:
     ```dockerfile
     RUN rm -rf /var/lib/apt/lists/*
     ```

## Future Security Enhancements

The following security features are planned for future implementation:

1. **Capability Management**:
   - Identify and document minimal capability set
   - Replace `--cap-drop=ALL` with specific `--cap-add` flags

2. **Seccomp Profiles**:
   - Implement custom seccomp profiles to restrict syscalls

3. **AppArmor/SELinux**:
   - Develop application-specific security profiles

4. **Token Vault Integration**:
   - Secure storage for API keys and credentials using `SECURITY_TOKEN_VAULT_PATH`

5. **Network Hardening**:
   - Implementation of `NETWORK_MODE=isolated` using custom network policies

6. **Forensic Cleanup**:
   - Secure data wipe implementation triggered by `ENABLE_FORENSIC_CLEANUP=true`

## Health Monitoring

The container includes a health check to detect failures:
```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=45s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8188/ || exit 1
```

## Security Auditing

Regularly audit container security using:
```bash
docker scan catalyst-image
trivy image catalyst-image
