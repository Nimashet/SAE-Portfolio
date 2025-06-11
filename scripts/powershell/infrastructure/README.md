# Infrastructure Orchestration Scripts

## Purpose

Centralized orchestration of security automation across multiple Linux systems from a Windows management workstation. Handles the "deploy and validate across 6 systems" problem that comes up when you need consistent security baselines.

## Script

| Script | Purpose | What It Does |
|--------|---------|--------------|
| `Deploy-SecurityHardening.ps1` | Orchestrate security deployment | Copies bash scripts to target systems, executes hardening, runs validation, provides summary reporting |

## Why PowerShell for Linux Management

**Cross-platform reality**: Most enterprise environments are mixed Windows/Linux. Being able to orchestrate Linux automation from Windows tooling shows practical hybrid skills.

**Centralized control**: Rather than SSH into each system individually, this handles the deployment workflow across multiple targets with proper error handling and reporting.

## Usage Examples

```powershell
# Harden all default systems
.\Deploy-SecurityHardening.ps1

# Harden specific systems only
.\Deploy-SecurityHardening.ps1 -TargetSystems @("control", "docker")

# Validate existing hardening without changes
.\Deploy-SecurityHardening.ps1 -ValidateOnly

# Deploy hardening but skip validation
.\Deploy-SecurityHardening.ps1 -SkipValidation
```

## What It Actually Does

1. **Connectivity testing** - Verifies SSH access to each target system
2. **Script deployment** - Copies bash security scripts to target systems
3. **Execution orchestration** - Runs hardening scripts with proper error handling
4. **Validation workflow** - Automatically validates security configuration
5. **Summary reporting** - Provides overall success/failure status

## Technical Notes

- **SSH integration**: Uses OpenSSH client from Windows to Linux systems
- **Error handling**: Comprehensive error checking with detailed logging
- **Parallel-ready**: Structure supports future parallel execution enhancement
- **Flexible targeting**: Can specify which systems to include/exclude