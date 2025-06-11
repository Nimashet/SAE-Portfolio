# Security Automation Engineer Portfolio

After 25+ years in cybersecurity, I'm diving deep into automation to solve the problems that keep security teams up at night. This repo shows real automation I'm building to eliminate tedious manual work.

## About

I spent decades managing security infrastructure manually. Now I'm learning to automate it properly. This portfolio tracks my journey building practical automation that actually works in complex environments - not just proof-of-concepts, but solutions I'd trust in production.

## Core Technologies

**Automation & Configuration Management**
- Ansible (inventory design, playbooks, roles)
- Terraform (infrastructure as code, multi-cloud)

**Infrastructure & Platforms**
- Linux administration (Ubuntu, Rocky Linux)
- Windows Server (Active Directory integration)
- Docker containerization
- Multi-platform automation

**Development & Integration**
- Git workflows and version control
- CI/CD pipeline development
- Python scripting for automation
- Cross-platform security hardening

## What I'm Building

### Infrastructure Automation
- **[Ansible Inventory Implementation](docs/automation-workflows/ansible-inventory-implementation.md)** - Learned the hard way that scaling inventory requires good architecture from day one

### Configuration Management
- **Security Baseline Automation** - Tired of clicking through the same 50 security settings on every new VM *(currently working on this)*

### Infrastructure as Code
- **Multi-Cloud Security Infrastructure** - Because managing AWS and Azure security manually is painful *(next up)*

## My Lab Setup

Running a 6-VM homelab where I break things and fix them:
- Windows domain controller (because someone has to test AD automation)
- Mixed Ubuntu/Rocky Linux systems (learning the differences the hard way)
- Container platform for development 
- Security monitoring stack (ELK)
- Everything connected across VLANs to simulate real network complexity

## Documentation

- **[Automation Workflows](docs/automation-workflows/)** - Implementation guides and technical decisions
- **[Setup Guides](docs/setup-guides/)** - Environment configuration and deployment procedures
- **[Troubleshooting](docs/troubleshooting/)** - Problem resolution and lessons learned

## Current Focus

I'm working on automation that I'd actually want to use:
- Cutting VM setup time from "most of my afternoon" to "grab coffee while it runs"
- Making security compliance something that just happens, not a monthly panic
- Building deployment processes that work the same way twice
- Learning to write automation that doesn't require a PhD to maintain

---

*This portfolio shows actual automation I'm building, not theoretical examples. Everything here runs in my lab and solves problems I've personally dealt with.*