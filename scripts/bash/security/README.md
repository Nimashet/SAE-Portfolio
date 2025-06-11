# Security Automation Scripts

## Why These Exist

Got tired of manually configuring the same security settings on every new lab VM. Spending 2+ hours per system clicking through SSH configs, firewall rules, and security tools gets old fast when you're building out a 6-VM environment for learning automation.

These scripts handle the boring, repetitive security hardening so I can focus on the interesting automation work.

## Scripts

| Script | Purpose | What It Does |
|--------|---------|--------------|
| `sae_lab_hardening.sh` | Automate security baseline | SSH hardening, fail2ban setup, UFW firewall, file permissions, security tools installation |
| `sae_lab_validation.sh` | Verify hardening worked | 30+ security checks with pass/fail results and detailed logging |

## Technical Notes

- **Tested on**: Ubuntu 24.04, Ubuntu 20.04, Rocky Linux 9
- **Lab scale**: 6 VMs (works great for homelab/learning environments)  
- **Error handling**: Backs up configs before changes, rollback on failures
- **Cross-platform**: Handles different package managers and service names

## What I Learned

SSH configuration syntax testing is critical - locked myself out once by restarting sshd with bad config. Now the script validates syntax before applying changes.

Different server roles need different firewall rules. Generic "secure everything the same way" doesn't work when your GitLab server needs ports 80/443 but your target systems don't.