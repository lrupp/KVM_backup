# KVM backup
Create backups of virtual machines

This script allows to create backups of virtual machines managed by libvirt and running on LVM volumes.

# DESCRIPTION
This script creates a Live-Backup via lvm snapshot from virtual machines running on the host.
In general, the script works like this:

* Get list of running machines

  virsh list

* Create an XML dump of the machines

  virsh dumpxml $machine

* Create a LVM snapshot of the used volumes

  lvcreate -s -L 2G -n $machine-snap /dev/vg1/$machine

* Dump the snapshot into a local file (might take time!)

  cat /dev/vg1/$machine-snap > $blockid-name.img

* Remove the snapshot

  lvremove -f /dev/vg1/$machine-snap

# RESTORE
If you want to restore the backup, just have a look in the (sub-)directory of your backup directories with the machine name. Here you should find the images and the xml:
* Restore file systems (repeat for all image files):

  cat $backupdir/$blockid-name.img > /dev/vg1/$machine

* Re-create the virtual machine

  virsh define $backupdir/$machine.xml

or

  virsh create --console $backupdir/$machine.xmo
  
# AUTHORS
This script was written by Lars Vogdt <lars@linux-schulserver.de> for own purposes, but maybe used by others.

