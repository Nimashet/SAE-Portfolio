# Ansible Inventory Implementation

## Overview
Built multi-group inventory structure for 6-VM homelab. Separates IP addresses from reusable configurations to enable version control without exposing network details.

## Directory Structure
```
ansible/inventory/
├── hosts.yml                    # Group definitions and host assignments
├── group_vars/
│   ├── all.yml                 # Global Ansible settings
│   ├── roles/                  # Role-based configurations
│   │   ├── control_nodes.yml
│   │   ├── automation_targets.yml
│   │   ├── devops_infrastructure.yml
│   │   └── security_infrastructure.yml
│   ├── platforms/              # OS-specific settings
│   │   ├── ubuntu.yml
│   │   └── windows.yml
│   ├── networks/               # Network-based configurations
│   │   └── management.yml
│   └── environments/           # Environment-specific (gitignored)
│       ├── lab.yml            # Contains actual IP addresses (gitignored)
│       └── .gitkeep           # Preserves directory structure
└── host_vars/                  # Individual host configurations
    ├── ws22-dc-01.yml         # Domain controller specifics
    └── .gitkeep               # Preserves directory structure
```

## Design Decisions

### Group-Based Architecture
- Used group_vars instead of individual host files for better scalability
- Multi-dimensional grouping: environment + role + platform + network
- Variable precedence: host_vars > roles > platforms > networks > environments > all

### Security Implementation
- IP addresses stored in gitignored environment files
- Public configurations use variable references: `{{ lab_hosts['hostname'] }}`
- Sensitive data excluded from version control

### Minimal host_vars
- Only created host-specific files for true snowflakes
- Domain controller requires unique FSMO role configurations
- All other hosts inherit from group hierarchies

## Current Lab Environment
- **control-01**: Ansible/Terraform execution
- **git-01**: GitLab CI/CD platform
- **docker-01**: Container development environment
- **ws22-dc-01**: Windows domain controller
- **siem-01**: Security monitoring (ELK stack)
- **ub24-tgt-01**: Automation testing target

## Host Targeting Examples

### Basic Operations
```bash
# Target by platform
ansible-playbook ubuntu-updates.yml --limit ubuntu_systems

# Target by role
ansible-playbook security-baseline.yml --limit automation_targets

# Target by environment
ansible-playbook lab-maintenance.yml --limit lab_environment
```

### Advanced Combinations
```bash
# Intersection: Ubuntu automation targets only
ansible-playbook deploy-agent.yml --limit 'ubuntu_systems:&automation_targets'

# Exclusion: All lab systems except domain controller
ansible-playbook patching.yml --limit 'lab_environment:!domain_controllers'
```

## Variable Inheritance Pattern
Each host inherits variables from multiple groups:

```yaml
# Example: control-01 receives configurations from:
- lab_environment          # Environment IPs and settings
- control_nodes           # Ansible/Terraform packages
- ubuntu_systems          # Platform-specific configurations  
- management_network      # Network security rules
- automation_controllers  # Controller-specific settings
```

## Network Integration
- **Domain**: Active Directory integration
- **DNS**: Multi-tier DNS architecture with Pi-hole and domain controller
- **VLANs**: Management access across multiple network segments
- **Security**: Firewall rules allowing cross-VLAN automation access

## Challenges and Solutions

### Issues Encountered
- YAML syntax errors with variable references in firewall rules
- Balancing public repository structure vs private IP protection
- Understanding Ansible variable precedence across multiple dimensions

### Solutions Implemented
- Created validation scripts for syntax and security compliance
- Implemented comprehensive gitignore patterns for sensitive data
- Documented variable precedence rules for team understanding

## Scaling Considerations
- Adding new VMs: Update group membership, inherit existing configs
- New environments: Create environment file, copy group structure
- Should handle 10-50 hosts before requiring dynamic inventory

## Next Steps
1. Test inventory with actual automation playbooks
2. Implement Ansible Vault for credential management
3. Create inventory validation playbook
4. Document automation development patterns

## Lessons Learned
- Group inheritance reduces configuration duplication significantly
- Security practices require careful separation of public/private data
- Multi-dimensional grouping provides flexibility but adds complexity
- Need testing framework to validate inventory changes