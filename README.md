KVM import/export (kvmie) tool
---

It analyzes XML VM definition file, takes ALL disks under consideration, along with NVRAM and imports / exports them.

---


**Syntax:**

```bash
./kvmie.sh 
Usage:
  ./kvmie.sh export <vm_name> <export_dir>
  ./kvmie.sh import <vm_name> <export_dir> [<new_disk_dir>]
```

---

**Export:**

```bash
./kvmie.sh export win10 win10
Exporting VM 'win10' to 'win10'...
Copying disk image: /mnt/libvirt/win10.qcow2
Copying NVRAM file: /var/lib/libvirt/qemu/nvram/win10_VARS.fd
Exporting snapshot definitions...
Export completed.

```

**Import:**

```bash
./kvmie.sh import win10 win10
Importing VM 'win10' from 'win10'...
Copying disk image to /mnt/libvirt/win10.qcow2
Copying NVRAM file to /var/lib/libvirt/qemu/nvram/win10_VARS.fd
Copying VM XML definition to /etc/libvirt/qemu/win10.xml
Defining VM with virsh...
Domain 'win10' defined from /etc/libvirt/qemu/win10.xml

Importing snapshot definitions...
Import completed. VM 'win10' is defined.
```
