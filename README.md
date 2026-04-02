# ansible-lab
> Ad-Hoc Automation on Azure — 4 VMs, Inventory & Passwordless SSH — DMI Cohort-2 Assignment 33

![DMI](https://img.shields.io/badge/DMI-Cohort--2-orange?logo=bookstack)
![DevOps](https://img.shields.io/badge/DevOps-Micro--Internship-blue?logo=azure-devops)
![Terraform](https://img.shields.io/badge/Terraform-v1.14.6-purple?logo=terraform)
![Ansible](https://img.shields.io/badge/Ansible-2.17.14-red?logo=ansible)
![Azure](https://img.shields.io/badge/Azure-canadacentral-blue?logo=microsoftazure)
![SSH](https://img.shields.io/badge/SSH-Passwordless-green?logo=openssh)

---

## Overview

This repository provisions Azure Linux VMs using Terraform, configures passwordless SSH, builds a custom Ansible inventory, and runs ad-hoc commands across hosts and groups. Anyone following this guide can replicate the entire deployment from scratch.

**Architecture:**
```
WSL2 Ubuntu 22.04 (Control Node)
        |
        |  Ansible ad-hoc commands over SSH (id_rsa)
        |
        |-- vm-web1 (52.139.45.152) -- web1 + app1 roles
        |-- vm-web2 (20.220.15.185) -- web2 + db1 roles
        
        Region: canadacentral
        Size: Standard_B2ats_v2 (2 vCPUs, 1 GiB RAM)
```

> **Free Tier Note:** Azure free subscription enforces a 4 vCPU regional quota in canadacentral. Since `Standard_B2ats_v2` uses 2 vCPUs, only 2 VMs fit within quota. Solution: 2 physical VMs serve 4 logical roles — a common real-world pattern for dev/sandbox environments.

---

## Prerequisites

- WSL2 Ubuntu 22.04 with Ansible venv from Assignment 1 (`~/ansible-onboarding/.venv`)
- Azure CLI authenticated with correct tenant and subscription
- Terraform v1.14+ installed
- SSH key at `~/.ssh/id_rsa`

---

## PHASE 1 — Azure CLI Authentication (Clean Slate)

### Step 1 — Check for old ARM environment variables
```bash
env | grep ARM
```
If any `ARM_*` variables appear, clear them immediately:
```bash
unset ARM_CLIENT_ID
unset ARM_CLIENT_SECRET
unset ARM_TENANT_ID
unset ARM_SUBSCRIPTION_ID
```
Also remove permanently from `~/.bashrc`:
```bash
sed -i '/ARM_CLIENT_ID/d' ~/.bashrc
sed -i '/ARM_CLIENT_SECRET/d' ~/.bashrc
sed -i '/ARM_TENANT_ID/d' ~/.bashrc
sed -i '/ARM_SUBSCRIPTION_ID/d' ~/.bashrc
```

> **Critical challenge:** Old `ARM_*` environment variables from a previous Azure setup were overriding all Terraform authentication — causing `InvalidAuthenticationTokenTenant` errors even after `az login`. Always check `env | grep ARM` before running Terraform on a new subscription.

### Step 2 — Login with device code
```bash
az logout
az account clear
az login --use-device-code --tenant <YOUR_TENANT_ID>
```
Open browser → **https://microsoft.com/devicelogin** → enter code → sign in.

### Step 3 — Set correct subscription
```bash
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"
az account show --output table
```
Confirm: `State = Enabled`, `IsDefault = True`

---

## PHASE 2 — Terraform Setup

### Step 1 — Install Terraform (if not installed)
```bash
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | \
  sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform -y
terraform --version
```

### Step 2 — Create project folder
```bash
mkdir -p ~/ansible-lab/terraform && cd ~/ansible-lab/terraform
```

### Step 3 — Create main.tf
```bash
cat > main.tf << 'EOF'
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id            = "<YOUR_SUBSCRIPTION_ID>"
  tenant_id                  = "<YOUR_TENANT_ID>"
  skip_provider_registration = true
}

resource "azurerm_resource_group" "main" {
  name     = "rg-ansible-lab"
  location = "canadacentral"
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-ansible-lab"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_subnet" "main" {
  name                 = "subnet-ansible-lab"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_network_security_group" "main" {
  name                = "nsg-ansible-lab"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-http"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_public_ip" "main" {
  count               = 2
  name                = "pip-${var.vm_roles[count.index]}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "main" {
  count               = 2
  name                = "nic-${var.vm_roles[count.index]}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.main[count.index].id
  }
}

resource "azurerm_network_interface_security_group_association" "main" {
  count                     = 2
  network_interface_id      = azurerm_network_interface.main[count.index].id
  network_security_group_id = azurerm_network_security_group.main.id
}

resource "azurerm_linux_virtual_machine" "main" {
  count               = 2
  name                = "vm-${var.vm_roles[count.index]}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = "Standard_B2ats_v2"
  admin_username      = "azureuser"

  network_interface_ids = [
    azurerm_network_interface.main[count.index].id
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}
EOF
```

> **Important:** Replace `<YOUR_SUBSCRIPTION_ID>` and `<YOUR_TENANT_ID>` with your actual values. Adding these explicitly to the provider block avoids authentication errors from cached credentials.

### Step 4 — Create variables.tf
```bash
cat > variables.tf << 'EOF'
variable "vm_roles" {
  default = ["web1", "web2"]
}
EOF
```

### Step 5 — Create outputs.tf
```bash
cat > outputs.tf << 'EOF'
output "public_ips" {
  value = {
    web1_app1 = azurerm_linux_virtual_machine.main[0].public_ip_address
    web2_db1  = azurerm_linux_virtual_machine.main[1].public_ip_address
  }
}

output "vm_names" {
  value = [for vm in azurerm_linux_virtual_machine.main : vm.name]
}

output "inventory_note" {
  value = "vm-web1 serves web1+app1 roles | vm-web2 serves web2+db1 roles"
}
EOF
```

---

## PHASE 3 — Deploy VMs with Terraform

### Step 1 — Initialize Terraform
```bash
terraform init
```
Expected: `Terraform has been successfully initialized!`

### Step 2 — Preview the plan
```bash
terraform plan
```
Confirms resources to be created: RG, VNet, Subnet, NSG, 2 Public IPs, 2 NICs, 2 NSG associations, 2 VMs.

### Step 3 — Register required Azure providers
```bash
az provider register --namespace Microsoft.Compute
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.Storage
```

### Step 4 — Apply
```bash
terraform apply -auto-approve
```
Expected completion:
```
Apply complete! Resources: X added, 0 changed, 0 destroyed.

Outputs:
public_ips = {
  "web1_app1" = "xx.xx.xx.xx"
  "web2_db1"  = "xx.xx.xx.xx"
}
```

Note both public IPs — you will need them for inventory.

![Terraform apply complete](screenshots/terraform-apply.png)

### Step 5 — Get IPs anytime
```bash
terraform output
```

![Terraform output showing public IPs](screenshots/terraform-output.png)

> **Challenges faced during Terraform:**
> - `ReadOnlyDisabledSubscription` — old subscription cached → fix: `az account set --subscription`
> - `InvalidAuthenticationTokenTenant` — wrong tenant cached → fix: add `tenant_id` to provider block
> - Provider registration timeout → fix: `skip_provider_registration = true`
> - `IPv4BasicSkuPublicIpCountLimitReached` → fix: use `sku = "Standard"` for public IPs
> - `PublicIPCountLimitReached` (max 3 in canadacentral) → fix: use 2 VMs with 4 logical roles
> - NSG already exists from partial run → fix: `terraform import azurerm_network_security_group.main <resource_id>`

---

## PHASE 4 — Passwordless SSH Verification

### Step 1 — Test SSH to both VMs
```bash
ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no azureuser@<VM1_IP> "hostname"
ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no azureuser@<VM2_IP> "hostname"
```
Expected:
```
vm-web1
vm-web2
```

> **Note:** You may see `Warning: Permanently added 'IP' (ED25519) to known_hosts`. This is normal — ED25519 refers to the **server's host key type**, not your authentication key. Your `id_rsa` private key is still being used for authentication.

![Passwordless SSH verification](screenshots/ssh-verification.png)

---

## PHASE 5 — Create Ansible Inventory

```bash
cd ~/ansible-lab
cat > inventory.ini << 'EOF'
[web]
<VM1_IP>
<VM2_IP>

[app]
<VM1_IP>

[db]
<VM2_IP>

[all:vars]
ansible_user=azureuser
ansible_ssh_private_key_file=~/.ssh/id_rsa
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF
```

Replace `<VM1_IP>` with `web1_app1` IP and `<VM2_IP>` with `web2_db1` IP from terraform output.

![inventory.ini contents](screenshots/inventory.png)

---

## PHASE 6 — Ansible Ad-Hoc Commands

### Activate venv first
```bash
source ~/ansible-onboarding/.venv/bin/activate
cd ~/ansible-lab
```

### Command 1 — Ping all hosts
```bash
ansible all -i inventory.ini -m ping
```
Expected: `SUCCESS` with `"ping": "pong"` for both hosts.

![ansible ping SUCCESS](screenshots/ansible-ping.png)

### Command 2 — Check identity
```bash
ansible all -i inventory.ini -m command -a "whoami"
```
Expected: `azureuser` on both hosts.

### Command 3 — Check uptime
```bash
ansible all -i inventory.ini -m command -a "uptime"
```

### Command 4 — Install nginx on web group
```bash
ansible web -i inventory.ini -m apt -a "update_cache=yes name=nginx state=present" --become
```

> **Challenge:** First attempt failed with `libtiff5 404 Not Found` — stale apt cache on fresh VMs. Fix: added `update_cache=yes` to refresh package cache before installing.

![nginx install CHANGED](screenshots/nginx-install.png)

### Command 5 — Start and enable nginx
```bash
ansible web -i inventory.ini -m service -a "name=nginx state=started enabled=yes" --become
```
Expected: `"state": "started"`, `"enabled": true`, `"ActiveState": "active"`

![nginx service started](screenshots/nginx-service.png)

### Command 6 — Install htop on all hosts
```bash
ansible all -i inventory.ini -m apt -a "update_cache=yes name=htop state=present" --become
```

![htop install SUCCESS](screenshots/htop-install.png)

### Command 7 — Disk usage on db group
```bash
ansible db -i inventory.ini -m command -a "df -h"
```

![df -h db group](screenshots/df-h.png)

### Command 8 — Memory check on all hosts
```bash
ansible all -i inventory.ini -m command -a "free -m"
```

![free -m all hosts](screenshots/free-m.png)

---

## PHASE 7 — Cleanup Azure Resources

When done, destroy all resources to avoid charges:

```bash
cd ~/ansible-lab/terraform
terraform destroy -auto-approve
```

Verify deletion:
```bash
az group show --name rg-ansible-lab --query "properties.provisioningState" -o tsv
```
Expected: `ResourceGroupNotFound`

---

## Ad-Hoc vs Playbook — When to Use Which

| Ad-Hoc Commands | Ansible Playbooks |
|---|---|
| Quick one-time tasks | Repeatable, complex deployments |
| Ping checks, uptime, whoami | Production server configuration |
| Package install during setup | Role-based multi-step automation |
| Troubleshooting and verification | Requires idempotency and version control |
| No repeatability needed | Must be peer-reviewed and tracked |

---

## Full Challenges & Deviations Log

| Challenge | Root Cause | Fix Applied |
|---|---|---|
| Old ARM_* env vars overriding Terraform | Previous Azure setup exported credentials to shell | `unset ARM_*` + removed from `~/.bashrc` |
| `ReadOnlyDisabledSubscription` after 18 mins | Old expired subscription `790f02c1` cached in Terraform | Explicitly set `subscription_id` in provider block |
| `InvalidAuthenticationTokenTenant` | Wrong tenant `4045d134` in cached token | Added `tenant_id` to provider block + re-login with `az login --use-device-code` |
| Browser login returned HTTP 404 | Azure login page issue | Used device code flow: `az login --use-device-code` |
| Provider registration timeout | Fresh subscription auto-registering all providers | Added `skip_provider_registration = true` |
| `source_ip_address_prefix` unsupported | Accidentally added wrong argument | Removed with `sed -i` |
| `IPv4BasicSkuPublicIpCountLimitReached` | Basic SKU IPs not allowed on free subscription | Changed to `sku = "Standard"` |
| Max 3 public IPs in canadacentral | Free tier global limit | Used 2 VMs serving 4 logical inventory roles |
| `Standard_B1s` not available | No capacity in canadacentral or eastus | Used `Standard_B2ats_v2` — only free-eligible size |
| vCPU quota exceeded (4 cores max) | 4 VMs × 2 vCPUs = 8 cores needed | Deployed 2 VMs × 2 roles each |
| NSG already exists from partial run | Previous failed apply created partial resources | `terraform import` to bring NSG into state |
| nginx install failed — `libtiff5` 404 | Stale apt cache on fresh VMs | Added `update_cache=yes` to apt module |
| Assignment requires `id_ed25519` | Key not present at expected path | Used existing `id_rsa` throughout |

---

## DMI Micro-Internship

This project was completed as part of the **DevOps Micro-Internship (DMI) Cohort-2** program.

| Detail | Info |
|---|---|
| Program | DevOps Micro-Internship (DMI) Cohort-2 |
| Assignment | Assignment 2 — Ad-Hoc Automation on Azure: 4 VMs, Inventory & Passwordless SSH |
| Candidate | Greg Odi |
| GitHub | [@gregodprogrammer](https://github.com/gregodprogrammer) |
| LinkedIn | [linkedin.com/in/gregodi](https://linkedin.com/in/gregodi) |
