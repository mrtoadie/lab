# 🧪 lab

![Ansible](https://img.shields.io/badge/Ansible-automation-red)
![Bash](https://img.shields.io/badge/Bash-scripts-green)
![License](https://img.shields.io/badge/license-MIT-blue)

> A collection of Ansible playbooks, shell scripts, and configuration examples for Linux system administration — hands-on learning, tinkering, and reusing.

---

## 📋 Overview

This repository is my personal **lab environment** for automation and system administration. It contains reusable snippets and solutions covering:

- 🤖 **Automation** with Ansible
- 🐚 **Shell scripts** for everyday admin tasks
- ⚙️ **Configuration examples** for common services
- ☸️ **Kubernetes/YAML** examples
- 🦘 **Go** utilities and experiments

---

## 📁 Structure

```text
lab/
├── ansible/                      # Playbooks
│   ├── 01_simple_command.yaml    # First steps: simple commands
│   ├── 03_multiple_commands.yaml # Multiple tasks combined
│   ├── 04_variables-playbook.yml # Variables & Jinja2
│   ├── pi_health.yml             # Raspberry Pi health check
│   ├── diskspace_linux.yml       # Check disk space
│   ├── gather_facts_*.yml        # Gather facts & OS version
│   ├── check_running_vms_*.yml   # Check running VMs (libvirt)
│   ├── create_group_01.yml       # Create groups
│   ├── create_user_01.yml        # Create users
│   ├── install_basic_tools.yml   # Install basic tools
│   ├── remove_packages.yml       # Remove packages
│   ├── update.yml                # System update
│   ├── update_archlinux.yml      # Arch Linux update
│   ├── backup_local_*.yml        # Local backups
│   ├── git_0*.yml                # Automated Git tasks
│   ├── reboot.yml                # Reboot (with handler/wait-for)
│   └── shutdown_*.yml            # Shutdown (classic & systemd)
├── scripts/                      # Shell scripts
│   ├── auto-pacman-update.sh     # Arch/pacman auto-update
│   ├── auto-flatpak-update.sh    # Flatpak auto-update
│   ├── pacman_hook_pakets.sh     # pacman hook
│   └── package-config-inventory*.sh # Package/config inventory
├── configs/                      # Config examples
│   ├── smb.conf                  # Samba shares
│   ├── smb_toad.conf             # Samba (specific setup)
│   ├── squid*.conf               # Squid proxy (incl. auth)
│   ├── drbd.conf / drbd_example_config.txt  # DRBD storage replication
│   ├── cluster.conf              # Pacemaker cluster
│   └── br10.xml                  # libvirt network bridge
├── k8s/
│   ├── pdb-test-deployment.yaml  # Deployment example
│   └── pdb-test-pdb.yaml         # PodDisruptionBudget
├── go/
│   ├── database_example.go       # Database integration
│   ├── static_submenu.go         # Static submenu
│   └── start_bash_script.go      # Launch bash scripts from Go
├── master.yml                    # Master playbook (role overview)
└── README.md
```

> _Adjust paths to match your actual repo structure!_

---

## ⚡ Quick Start

### Prerequisites

- Linux (tested on Arch Linux & Debian-based systems)
- [Ansible](https://docs.ansible.com/) ≥ 2.10
- Optional: libvirt, Docker/Podman, Go

### Run a Playbook

```bash
# Update all hosts from the inventory
ansible-playbook -i hosts.ini update.yml

# Health check on a Raspberry Pi cluster
ansible-playbook -i hosts.ini pi_health.yml

# Run locally (without inventory)
ansible-playbook diskspace_linux.yml -i localhost,
```

### Use the Scripts

```bash
chmod +x scripts/auto-pacman-update.sh
./scripts/auto-pacman-update.sh
```

---

## 🗂️ Categories in Detail

| Category       | Purpose                                                                       |
| -------------- | ----------------------------------------------------------------------------- |
| **Ansible**    | Playbooks from beginner to advanced: facts, variables, handlers, templates    |
| **Scripts**    | Auto-updates, hooks & inventories for Arch/pacman & Flatpak                   |
| **Configs**    | Reference configurations for Samba, Squid (proxy incl. auth), DRBD, Pacemaker |
| **Kubernetes** | YAML examples for deployments & PodDisruptionBudgets                          |
| **Go**         | Small utilities: DB integration, bash interop                                 |

---

## 🔧 Troubleshooting & Tips

- Watch out for `become: true` — some playbooks require root privileges.
- Test SSH access to target systems first: `ansible all -m ping -i hosts.ini`
- `check_running_vms_*.yml` requires libvirt (`virsh`) on the host.

---

## 📄 License

MIT — free to use, copy, and adapt.

---

> 🛠️ **Note:** This repo primarily serves as a learning and reference collection. Always adapt anything in `configs/` to your own environment before production use!
