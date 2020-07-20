=========================
Modern Linux Boot Process
=========================

In the last year or two, I've spent more time than I like frantically
trying to fix Linux laptops where I've broken the boot process one way
or another.  The biggest obstacle, in each case, has been that I
didn't really understand what was going on, so I was stuck doing web
searches until I found something that solved my immediate problem.  A
lot has changed in the x86 and Linux boot process since I last spent
much time looking at it, so I'm writing this down after spending some
time investigating how it works now.

This is specifically for the installation that I have on my own
laptop, which boots 64-bit Fedora 32 from an NVMe SSD via UEFI and
Grub 2.

Boot is complicated, even more complicated than I'd realized.  This
discussion is nowhere near complete.

The SSD
-------

My SSD's NVMe device is ``/dev/nvme0``.  NVMe devices are divided into
"namespaces".  Mine has just one namespace ``/dev/nvme0n1``.  That
appears to be the normal number of namespaces.  This namespace is
where all the data is.  The ``nvme list`` command shows some basic
stats.  You can see that it's a 1 TB drive, for example::

  $ sudo nvme list
  Node             SN                   Model                                    Namespace Usage                      Format           FW Rev  
  ---------------- -------------------- ---------------------------------------- --------- -------------------------- ---------------- --------
  /dev/nvme0n1     MI93T003610303E06    PC401 NVMe SK hynix 1TB                  1         324.04  GB /   1.02  TB    512   B +  0 B   80007E00

(The ``nvme`` utility isn't installed by default.  On Fedora:
``sudo dnf install nvme-cli``.)

The 324 GB number above might be the amount of storage in use from the
drive's own perspective.  I wasn't able to find any documentation
explaining that number.

Partitions
----------

I used Fedora's default partitioning for an encrypted boot drive.
This yielded three partitions using a GPT disklabel::

  $ sudo fdisk -l /dev/nvme0n1
  Disk /dev/nvme0n1: 953.89 GiB, 1024209543168 bytes, 2000409264 sectors
  Disk model: PC401 NVMe SK hynix 1TB                 
  Units: sectors of 1 * 512 = 512 bytes
  Sector size (logical/physical): 512 bytes / 512 bytes
  I/O size (minimum/optimal): 512 bytes / 512 bytes
  Disklabel type: gpt
  Disk identifier: 225DB613-867D-4004-9C94-4822154BA204

  Device           Start        End    Sectors   Size Type
  /dev/nvme0n1p1    2048     411647     409600   200M EFI System
  /dev/nvme0n1p2  411648    2508799    2097152     1G Linux filesystem
  /dev/nvme0n1p3 2508800 2000408575 1997899776 952.7G Linux filesystem

I hadn't known much about GPT before.  It stands for "GUID partition
table", is an advancement over the previous MBR scheme in multiple
ways: it supports up to 128 partitions (instead of just 4 physical
partitions), it uses a GUID to identify partition types (instead of a
byte), it supports very large disks via 64-bit LBA addresses, it has a
CRC32 checksum for safety, and it is stored at both the beginning and
the end of the disk for redundancy.  It preserves some compatibility
with the traditional MBR by using an MBR that declares the whole disk
to be a single partition of type 0xee.

The partitions above are:

* ``/dev/nvme0n1p1``: This is the `EFI system partition
  <https://en.wikipedia.org/wiki/EFI_system_partition>`_.  It is
  formatted as a FAT file system.  Ultimately, it ends up mounted at
  ``/boot/efi``.  It is small (by today's standards!), only 200 MB.
  It contains the bootloader.  Here's another way to see this::

    $ ls -l /dev/disk/by-partlabel/
    total 0
    lrwxrwxrwx. 1 root root 15 Jul 10 16:19 'EFI\x20System\x20Partition' -> ../../nvme0n1p1

* ``/dev/nvme0n1p2``: This is an ext4 partition ultimately mounted at
  ``/boot``.  It is a little bigger than the EFI system partition.  It
  contains kernels and their configurations and modules.

* ``/dev/nvme0n1p3``: This is a LUKS2 encrypted partition.  It takes
  up the bulk of the disk space.

  (LUKS stands for Linux Unified Key Setup.  It's the Linux standard
  for disk encryption.)

Even though GPT uses a whole 128-bit GUID to identify the type of each
partition, Linux only uses a single GUID for all types of data
partition.  Thus, the second and third partitions above have the same
GUID for their types, rather than different GUIDs for ext4 versus
LUKS2 encryption.  We can ask ``fdisk`` to show us the "Type-UUID"s as
well as the partitions' UUIDs::

  $ sudo fdisk -l -o +uuid,type-uuid /dev/nvme0n1
  ...
  Device           Start        End    Sectors   Size Type UUID                                 Type-UUID
  /dev/nvme0n1p1    2048     411647     409600   200M EFI  10F28736-7EB9-48A8-BB37-AC2FDBACAC3F C12A7328-F81F-11D2-BA4B-00A0C93EC93B
  /dev/nvme0n1p2  411648    2508799    2097152     1G Linu 1D24A3B1-3131-4365-A3A7-DADAE8DDF6FD 0FC63DAF-8483-4772-8E79-3D69D8477DE4
  /dev/nvme0n1p3 2508800 2000408575 1997899776 952.7G Linu 7A2DC291-4F3C-4DE5-B1C9-DC6351863A89 0FC63DAF-8483-4772-8E79-3D69D8477DE4

(Linux doesn't use GPT partition UUIDs much.  They do not appear in
for example, ``/dev/disk/by-uuid``; rather, the UUIDs embedded in the
filesystems' superblocks appear there.  GPT partition UUIDs do appear
in ``/dev/disk/by-partuuid``.)

Early Boot
----------

In UEFI, boot starts out from a boot manager embedded in the machine's
firmware.  Boot managers use a standardized set of variables.  The
most important of these for our purposes is ``BootOrder``.  Its value
is a list of numbers, each of which identifies a ``Boot<XXXX>`` entry,
where <XXXX> is the number from ``BootOrder``.

The ``efivar`` utility manipulates EFI variables.  It's not installed
by default.  On Fedora, you can install it with ``sudo dnf install
efivar``.  (The ``/sys/firmware/efi/efivars`` directory also provides
an interface to EFI variables.  These are binary files.  Ignore the
first four bytes of each file to get the raw data.)

We can get a list of EFI variables with ``efivar -l``.  The ``efivar``
program makes us specify variable names along with an obnoxious UUID,
so this is useful for finding out those UUIDs.  On my system::

  $ sudo efivar -l|grep BootOrder
  8be4df61-93ca-11d2-aa0d-00e098032b8c-BootOrder
  45cf35f6-0d6e-4d04-856a-0370a5b16f53-DefaultBootOrder
  $ sudo efivar -p --name 8be4df61-93ca-11d2-aa0d-00e098032b8c-BootOrder
  GUID: 8be4df61-93ca-11d2-aa0d-00e098032b8c
  Name: "BootOrder"
  Attributes:
	  Non-Volatile
	  Boot Service Access
	  Runtime Service Access
  Value:
  00000000  09 00 06 00 02 00 03 00  04 00 05 00 07 00 0a 00  |................|

The value is 16-bit little-endian numbers in hex, so this is 9, 6, 2,
3, 4, 5, 7, 10.  We can then dump the first boot order entry::

  $ sudo efivar -l|grep Boot0009
  8be4df61-93ca-11d2-aa0d-00e098032b8c-Boot0009
  $ sudo efivar -p --name 8be4df61-93ca-11d2-aa0d-00e098032b8c-Boot0009
  GUID: 8be4df61-93ca-11d2-aa0d-00e098032b8c
  Name: "Boot0009"
  Attributes:
	  Non-Volatile
	  Boot Service Access
	  Runtime Service Access
  Value:
  00000000  01 00 00 00 62 00 46 00  65 00 64 00 6f 00 72 00  |....b.F.e.d.o.r.|
  00000010  61 00 00 00 04 01 2a 00  01 00 00 00 00 08 00 00  |a.....*.........|
  00000020  00 00 00 00 00 40 06 00  00 00 00 00 36 87 f2 10  |.....@......6...|
  00000030  b9 7e a8 48 bb 37 ac 2f  db ac ac 3f 02 02 04 04  |.~.H.7./...?....|
  00000040  34 00 5c 00 45 00 46 00  49 00 5c 00 66 00 65 00  |4.\.E.F.I.\.f.e.|
  00000050  64 00 6f 00 72 00 61 00  5c 00 73 00 68 00 69 00  |d.o.r.a.\.s.h.i.|
  00000060  6d 00 78 00 36 00 34 00  2e 00 65 00 66 00 69 00  |m.x.6.4...e.f.i.|
  00000070  00 00 7f ff 04 00                                 |......          |

The filename embedded in this is evidently in UTF-16LE.  In ASCII, it
says ``\EFI\fedora\shimx64.efi``.  This refers to a file in the EFI
system partition.  Since, as mentioned before, this is mounted at
``/boot/efi``, we can look at this file and the rest of the
directory::

  $ sudo ls /boot/efi/EFI/fedora -l
  total 15604
  -rwx------. 1 root root     112 Oct  2  2018 BOOTIA32.CSV
  -rwx------. 1 root root     110 Oct  2  2018 BOOTX64.CSV
  drwx------. 2 root root    4096 Jun  5 18:01 fonts
  drwx------. 2 root root    4096 Jun  5 18:07 fw
  -rwx------. 1 root root   62832 May 22 04:32 fwupdx64.efi
  -rwx------. 1 root root 1587528 May 26 09:23 gcdia32.efi
  -rwx------. 1 root root 2513224 May 26 09:23 gcdx64.efi
  -rwx------. 1 root root    5471 Sep  8  2019 grub.cfg
  -rwx------. 1 root root    1024 Jul 10 16:22 grubenv
  -rwx------. 1 root root 1587528 May 26 09:23 grubia32.efi
  -rwx------. 1 root root 2513224 May 26 09:23 grubx64.efi
  -rwx------. 1 root root  927824 Oct  2  2018 mmia32.efi
  -rwx------. 1 root root 1159560 Oct  2  2018 mmx64.efi
  -rwx------. 1 root root 1210776 Oct  2  2018 shim.efi
  -rwx------. 1 root root  975536 Oct  2  2018 shimia32.efi
  -rwx------. 1 root root  969264 Oct  2  2018 shimia32-fedora.efi
  -rwx------. 1 root root 1210776 Oct  2  2018 shimx64.efi
  -rwx------. 1 root root 1204496 Oct  2  2018 shimx64-fedora.efi

``shimx64.efi`` is an executable program that sits between the UEFI
boot manager and Grub 2.  True to its name, it acts as a "shim" for
Secure Boot.  We can see that it's an executable::

  $ sudo file /boot/efi/EFI/fedora/shimx64.efi
  /boot/efi/EFI/fedora/shimx64.efi: PE32+ executable (EFI application) x86-64 (stripped to external PDB), for MS Windows

It's not really a Windows program, it's just in the Windows PE
"Portable Executable" format.  Intel designed EFI and it's heavily
Windows-flavored.  If you run ``strings`` on the shim binary, you see
a lot of OpenSSL references.  That is presumably the "Secure" part.

Grub
----

The ``shimx64.efi`` program runs ``grubx64.efi``, which is the actual
Grub 2 bootloader.  In turn, ``grubx64.efi`` reads and executes
``grub.cfg``, which is a script written in a Grub-specific language
that resembles Bourne shell with some special features for booting.

``grub.cfg`` has lots of ``insmod`` commands.  These do not load Linux
kernel modules, they load Grub modules.  Grub has a *lot* of modules:
I see 295 of them in ``/usr/lib/grub/i386-pc``.  The modules are not
consistently documented.  A lot of modules exist to implement a
particular command; for example, ``hexdump.mod`` implements the
``hexdump`` command.

``grub.cfg`` loads environment variables from ``grubenv``, which is
mostly a text file but has a special format.  Use ``grub-editenv`` to
edit ``grubenv`` if you really need to.  See `The GRUB environment
block
<https://www.gnu.org/software/grub/manual/grub/html_node/Environment-block.html>`,
for more information.

In earlier versions of Grub, ``grub.cfg`` usually contained a list of
``menuentry`` commands that said how to boot various kernels you might
have.  This isn't the case for my Fedora installation.  Instead,
``grub.cfg`` has a single ``blscfg`` command::

  # The blscfg command parses the BootLoaderSpec files stored in /boot/loader/entries and
  # populates the boot menu. Please refer to the Boot Loader Specification documentation
  # for the files format: https://www.freedesktop.org/wiki/Specifications/BootLoaderSpec/.
  ⋮
  insmod blscfg
  blscfg

In turn, I have several ``.conf`` files in ``/boot/loader/entries``::

  $ sudo ls /boot/loader/entries/
  b4e66474bf8f4ab997720a7bd0d83628-0-rescue.conf
  b4e66474bf8f4ab997720a7bd0d83628-5.3.12-300.fc31.x86_64.conf
  b4e66474bf8f4ab997720a7bd0d83628-5.4.13-201.fc31.x86_64.conf
  b4e66474bf8f4ab997720a7bd0d83628-5.5.17-200.fc31.x86_64.conf
  b4e66474bf8f4ab997720a7bd0d83628-5.6.15-300.fc32.x86_64.conf

Each of the ``.conf`` files describes one menu entry.  My default
entry is::

  $ sudo cat /boot/loader/entries/b4e66474bf8f4ab997720a7bd0d83628-5.6.15-300.fc32.x86_64.conf
  title Fedora (5.6.15-300.fc32.x86_64) 32 (Thirty Two)
  version 5.6.15-300.fc32.x86_64
  linux /vmlinuz-5.6.15-300.fc32.x86_64
  initrd /initramfs-5.6.15-300.fc32.x86_64.img
  options $kernelopts
  grub_users $grub_users
  grub_arg --unrestricted
  grub_class kernel

In my installation, the ``$kernelopts`` variable above comes from
``/boot/efi/EFI/fedora/grubenv``::

  kernelopts=root=/dev/mapper/fedora-root ro resume=/dev/mapper/fedora-swap rd.lvm.lv=fedora/root rd.luks.uuid=luks-3acca984-01a3-4c67-b9c6-94433f667b88 rd.lvm.lv=fedora/swap rhgb quiet systemd.unified_cgroup_hierarchy=0

(I added the ``systemd.unified_cgroup_hierarchy=0`` variable assigment
at the end to disable cgroups v2.  This is needed to run Docker.)

One may compare these kernel options to the ones in the running
kernel.  The only difference in the ``BOOT_IMAGE`` at the beginning
(Grub adds this itself)::

  $ cat /proc/cmdline 
  BOOT_IMAGE=(hd0,gpt2)/vmlinuz-5.6.15-300.fc32.x86_64 root=/dev/mapper/fedora-root ro resume=/dev/mapper/fedora-swap rd.lvm.lv=fedora/root rd.luks.uuid=luks-3acca984-01a3-4c67-b9c6-94433f667b88 rd.lvm.lv=fedora/swap rhgb quiet systemd.unified_cgroup_hierarchy=0

Finally, I noticed that ``grub.cfg`` itself has a similar assignment
to ``$default_kernelopts``.  I don't know whether or how this is
connected to ``$kernelopts`` that all of the ``.conf`` files use::

  set default_kernelopts="root=/dev/mapper/fedora-root ro resume=/dev/mapper/fedora-swap rd.lvm.lv=fedora/root rd.luks.uuid=luks-3acca984-01a3-4c67-b9c6-94433f667b88 rd.lvm.lv=fedora/swap rhgb quiet "

Grub Root File Systems
----------------------

Grub needs to find the ``root`` file system, the one that contains the
Linux kernel and initrd files, which in my case is the ext4 partition
``/dev/nvme0n1p2``.  ``grub.cfg`` tells it to find this partition by
searching for it by UUID::

  search --no-floppy --fs-uuid --set=root 71baeefe-e3d2-45e1-a0ff-bf651d4a7591

``grub.cfg`` also tells Grub to find the ``boot`` partition, i.e. the
EFI system partition in FAT format on ``/dev/nvme0n1p1``, by its
UUID::

  search --no-floppy --fs-uuid --set=boot 2AB5-7C0C

It's not clear to me what Grub uses the latter information for, if
anything, since at the time this ``search`` command runs Grub has
already read all the files it really needs.

Kernel Loading
--------------

We've covered everything necessary for Grub to allow the user to
select a kernel.  Suppose the user selects the Fedora 32 entry
detailed above.  This will cause the associated commands to run.  The
important ones are::

  linux /vmlinuz-5.6.15-300.fc32.x86_64
  initrd /initramfs-5.6.15-300.fc32.x86_64.img
  options $kernelopts

The ``linux`` command points to the kernel image to load. The path is
relative to the Grub root established above, which on a booted system
is mounted at ``/boot``::

  $ ls -l /boot/vmlinuz-5.6.15-300.fc32.x86_64
  -rwxr-xr-x. 1 root root 10795112 May 29 07:42 /boot/vmlinuz-5.6.15-300.fc32.x86_64
  $ file /boot/vmlinuz-5.6.15-300.fc32.x86_64
  /boot/vmlinuz-5.6.15-300.fc32.x86_64: Linux kernel x86 boot executable bzImage, version 5.6.15-300.fc32.x86_64 (mockbuild@bkernel03.phx2.fedoraproject.org) #1 SMP Fri May 29 14:23:59 , RO-rootFS, swap_dev 0xA, Normal VGA

The ``initrd`` command points to an additional file that Grub loads
into memory and makes available to the kernel.

Now Grub turns over control to the kernel.  The kernel does basic
system setup.  We will ignore that, as detailed and exciting as it is.

Initrd
------

After the kernel does basic system setup, it finds userspace to run.
To do that, it needs a file system.  Initially, nothing is mounted,
except for an empty root directory (a ``ramfs`` file system).

The initial file system can come from a few places.  The following
sections explore the possibilities.

Built-In ``cpio`` Archive
~~~~~~~~~~~~~~~~~~~~~~~~~

The kernel can get its initial file system from a few places.  There
is always a ``cpio`` archive built into the kernel itself.  (``cpio``
has the same purpose as ``tar``, but its command-line interface is
very different.)  We should look at it.  It is kind of hard to get it
out, and some of the recipes I found online did not work.  Eventually,
I got the uncompressed kernel image using ``extract-vmlinux``, then
the start and end address of the archive from ``System.map``, then the
offset in the file from ``objdump``, then the contents via ``dd``::

  $ /usr/src/kernels/5.6.15-300.fc32.x86_64/scripts/extract-vmlinux /boot/vmlinuz-5.6.15-300.fc32.x86_64 > vmlinux
  $ sudo grep initramfs /boot/System.map-5.6.15-300.fc32.x86_64 
  ffffffff831d2228 D __initramfs_start
  ffffffff831d2428 D __initramfs_size
  $ sudo objdump --file-offsets -s --start-address=0xffffffff831d2228 --stop-address=0xffffffff831d2428 vmlinux | head -4

  vmlinux:     file format elf64-x86-64

  Contents of section .init.data:  (Starting at file offset: 0x25d2228)
  $ sudo dd if=vmlinux bs=1 skip=$((0x25d2228)) count=$((0xffffffff831d2428 - 0xffffffff831d2228)) status=none | cpio -vt
  drwxr-xr-x   2 root     root            0 May 29 07:24 dev
  crw-------   1 root     root       5,   1 May 29 07:24 dev/console
  drwx------   2 root     root            0 May 29 07:24 root
  1 block


As you can see above, there's barely anything in the kernel's built-in
``cpio`` archive.  This is clearly not how this system is booting.

Initrd cpio Archive
~~~~~~~~~~~~~~~~~~~

Consider the ``initrd`` command that was given to Grub.  Its name
stands for "initial RAM disk".  This is what this kernel is actually
using to boot.

Earlier versions of Linux (though not the very earliest!)  pointed
``initrd`` to a small disk image that the kernel would mount and use
as the first stage of userland.  These days, ``initrd`` points to a
``cpio`` archive::

  $ ls -l /boot/initramfs-5.6.15-300.fc32.x86_64.img
  -rw-------. 1 root root 35496138 Jun  5 18:05 /boot/initramfs-5.6.15-300.fc32.x86_64.img
  $ file /boot/initramfs-5.6.15-300.fc32.x86_64.img
  /boot/initramfs-5.6.15-300.fc32.x86_64.img: regular file, no read permission
  $ sudo file /boot/initramfs-5.6.15-300.fc32.x86_64.img
  /boot/initramfs-5.6.15-300.fc32.x86_64.img: ASCII cpio archive (SVR4 with no CRC)

We can look inside the archive::

  $ sudo cat /boot/initramfs-5.6.15-300.fc32.x86_64.img | cpio -tv
  drwxr-xr-x   3 root     root            0 May 29 11:35 .
  -rw-r--r--   1 root     root            2 May 29 11:35 early_cpio
  drwxr-xr-x   3 root     root            0 May 29 11:35 kernel
  drwxr-xr-x   3 root     root            0 May 29 11:35 kernel/x86
  drwxr-xr-x   2 root     root            0 May 29 11:35 kernel/x86/microcode
  -rw-r--r--   1 root     root        99328 May 29 11:35 kernel/x86/microcode/GenuineIntel.bin
  196 blocks

This is also clearly not anything that can be booted.  This archive is
just for CPU microcode.  It's not clear to me exactly how and when the
kernel finds and sets up this microcode.  Nothing related to it shows
up in ``dmesg``.

The above is less than 100 kB in size (``cpio`` uses 512-byte blocks).
The previous ``ls -l`` shows that the initrd is tens of megabytes in
size, so there must be more following the ``cpio`` archive.  Indeed::

  $ sudo cat /boot/initramfs-5.6.15-300.fc32.x86_64.img | (cpio -t >/dev/null 2>&1; file -)
  /dev/stdin: gzip compressed data, max compression, from Unix
  $ sudo cat /boot/initramfs-5.6.15-300.fc32.x86_64.img | (cpio -t >/dev/null 2>&1; zcat | file -)
  /dev/stdin: ASCII cpio archive (SVR4 with no CRC)
  $ sudo cat /boot/initramfs-5.6.15-300.fc32.x86_64.img | (cpio -t >/dev/null 2>&1; zcat | cpio -t)
  drwxr-xr-x  12 root     root            0 May 29 11:35 .
  lrwxrwxrwx   1 root     root            7 May 29 11:35 bin -> usr/bin
  drwxr-xr-x   2 root     root            0 May 29 11:35 dev
  crw-r--r--   1 root     root       5,   1 May 29 11:35 dev/console
  crw-r--r--   1 root     root       1,  11 May 29 11:35 dev/kmsg
  crw-r--r--   1 root     root       1,   3 May 29 11:35 dev/null
  crw-r--r--   1 root     root       1,   8 May 29 11:35 dev/random
  crw-r--r--   1 root     root       1,   9 May 29 11:35 dev/urandom
  drwxr-xr-x  11 root     root            0 May 29 11:35 etc
  -rw-r--r--   1 root     root           92 May 29 11:35 etc/block_uuid.map
  …2468 files and directories omitted…
  -rw-r--r--   1 root     root         1730 Jan 29 08:57 usr/share/terminfo/l/linux
  drwxr-xr-x   2 root     root            0 May 29 11:35 usr/share/terminfo/v
  -rw-r--r--   1 root     root         1190 Jan 29 08:57 usr/share/terminfo/v/vt100
  -rw-r--r--   1 root     root         1184 Jan 29 08:57 usr/share/terminfo/v/vt102
  -rw-r--r--   1 root     root         1377 Jan 29 08:57 usr/share/terminfo/v/vt220
  lrwxrwxrwx   1 root     root           20 May 29 11:35 usr/share/unimaps -> /usr/lib/kbd/unimaps
  drwxr-xr-x   3 root     root            0 May 29 11:35 var
  lrwxrwxrwx   1 root     root           11 May 29 11:35 var/lock -> ../run/lock
  lrwxrwxrwx   1 root     root            6 May 29 11:35 var/run -> ../run
  drwxr-xr-x   2 root     root            0 May 29 11:35 var/tmp

Now we're getting somewhere!  We can extract the archive into a
temporary directory for further examination::

  $ mkdir initrd
  $ cd initrd/
  $ sudo cat /boot/initramfs-5.6.15-300.fc32.x86_64.img | (cpio -t >/dev/null 2>&1; zcat | cpio -i)
  cpio: dev/console: Cannot mknod: Operation not permitted
  cpio: dev/kmsg: Cannot mknod: Operation not permitted
  cpio: dev/null: Cannot mknod: Operation not permitted
  cpio: dev/random: Cannot mknod: Operation not permitted
  cpio: dev/urandom: Cannot mknod: Operation not permitted
  156121 blocks
  $ ls
  bin  etc   lib    proc  run   shutdown  sysroot  usr
  dev  init  lib64  root  sbin  sys       tmp      var

(One may also ``sudo chroot`` into the initrd, which has a shell and
basic libraries and command-line tools.  It is not a comfortable
environment in other ways, though; for example, Backspace and Ctrl+U
didn't behave in a sane way for me.)

After the kernel extracts this archive into RAM, it starts ``/init``,
which is actually ``systemd``::

  $ ls -l init 
  lrwxrwxrwx. 1 bpfaff bpfaff 23 Jul 11 11:37 init -> usr/lib/systemd/systemd
  $ file usr/lib/systemd/systemd
  usr/lib/systemd/systemd: ELF 64-bit LSB shared object, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, BuildID[sha1]=a427da4e4bd4db8b6aac43245f8da742e1994076, for GNU/Linux 3.2.0, stripped

After I discovered this and started looking through the systemd
documentation for information on startup, I came across bootup(7).  It
is full of great information (although it further references boot(7),
which doesn't exist), including a diagram.  There is particularly a
section titled "Bootup in the Initial RAM Disk (initrd)" which is
relevant now.  dracut.bootup(7) also has a wonderful diagram
illustrating the bootup sequence.

bootup(7) says that the default target is ``initrd.target`` if
``/etc/initrd-release`` exists, which it does in my case.  (Kernel
command-line setting ``rd.systemd.unit=…`` could override the default,
but it is not set.)  Even if ``/etc/initrd-release`` did not exist, my
initrd symlinks from ``/etc/systemd/system/default.target`` to
``/usr/lib/systemd/system/initrd.target``.  The latter file contains,
in part::

  ConditionPathExists=/etc/initrd-release
  Requires=basic.target
  Wants=initrd-root-fs.target initrd-root-device.target initrd-fs.target initrd-parse-etc.service
  After=initrd-root-fs.target initrd-root-device.target initrd-fs.target basic.target rescue.service rescue.target

In my initrd, ``/etc/initrd-release`` is a symlink to
``/usr/lib/initrd-release``.  By either name, it contains a series of
key-value pairs in a format suitable for the Bourne shell.  Grepping
around the initrd tree shows that the ``/usr/bin/dracut-cmdline``
shell script sources these pairs (via ``/usr/lib/initrd-release``).
This will come up later, in `Dracut Command Line Parsing`_.

Early systemd Startup
---------------------

It would be possible to figure out what's going on at boot by manually
looking through all of the systemd unit files in
``/etc/systemd/system`` and ``/usr/lib/systemd/system``.  This would
be a slow process because there are a lot of them and it's not easy to
follow all the dependency chains.  I didn't want to do that.

Luckily, systemd comes with the ``systemd-analyze`` program to
help out.  It has a number of subcommands.  The best one for this
purpose seems to be the ``plot`` subcommand.  I invoked it like this::

  systemd-analyze plot > bootup.svg

The output was `<bootup.svg>`_.  You might want to load this in
another tab or another window so you can flip back and forth, because
the rest of boot follows along with it.  (This diagram is very tall
and wide!  You will probably have to pan to the right or shrink it
down with Ctrl+− to see anything meaningful.)

Multiple programs on my system can view SVG files but I ended up using
Firefox the most because it allows cut-and-paste of text whereas the
other viewers I tried do not.

The SVG output is a 2-d plot where the x axis is time and the y axis
is a series of rows, each of which is a bar that represents a
timespan.  There are a few gray bars at the top that represent a few
important stages of kernel loading: "firmware", "loader", "kernel",
"initrd".  Time is in seconds, with zero at the transition from
"loader" to "kernel".  The rest of the rows are red and represent
units, spanning from the unit's start time to its exit time.  Some
units finish quickly, so they only have short bars; some run as long
as the system is up, so their bars run past the right end of the x
axis.

On my system, "kernel" takes about 2 seconds to initialize and then
"initrd" (and thus systemd) takes over.  About 300 ms later, systemd
starts launching units.  The first few units it launches are built-in
and I think they happen automatically without considering any
dependency chains.  All of them appear to remain active as long as the
system itself does. These are documented in systemd.special(7):

* ``-.mount``: This represents the root mount point.

  systemd has a naming convention for mounts (and slices, below), that
  uses ``-`` as the root (instead of ``/``) and as the delimiter
  between levels, so that a mount ``/home/foo`` would be called
  ``home-foo.mount``.  Details in systemd.unit(5) under "String
  Escaping for Inclusion in Unit Names".

* ``-.slice``: Root of the "slice hierarchy" documented in
  systemd.slice(7).

  A slice is a cgroup that systemd manages.  Slices may contain slices
  (recursively), services, and scopes.  Slices don't directly contain
  processes (but services and scopes nested within them do).  More
  information in systemd.slice(5).

  Slices have a hierarchy expressed the same way as for mounts
  (although slices don't correspond to files), so that
  ``foo-bar.slice`` is a child under ``foo.slice``.

  systemd.slice(7) says that ``-.slice`` doesn't usually contain
  units, that instead it is used to set defaults for the slice tree.

* ``init.scope``: Scope unit that contains PID 1.

  Scopes contain processes that are started by arbitrary processes (as
  opposed to processes within services, which systemd itself starts).

  https://www.freedesktop.org/wiki/Software/systemd/ControlGroupInterface/
  has useful documentation on slices and scopes and especially at
  https://www.freedesktop.org/wiki/Software/systemd/ControlGroupInterface/#systemdsresourcecontrolconcepts

  I discovered the ``systemd-cgls`` command and used it to list the
  contents of ``init.scope``.  Indeed, it only contained ``systemd``
  itself::

    $ systemd-cgls -u init.scope
    Unit init.scope (/init.scope):
    └─1 /usr/lib/systemd/systemd --switched-root --system --deserialize 30

* ``system.slice``: Default slice for service and scope units.

  When I ran ``systemd-cgls -u system.slice``, I saw 44 services
  running under it ranging from ``abrtd.service`` to
  ``wpa_supplicant.service``, with no sub-slices or sub-scopes.

Encrypted Disk Setup
--------------------

The next row in the ``systemd-analyze plot`` output is for
``system-systemd\x2dcryptsetup.slice``.  The name illustrates
systemd's escaping convention: ``\x2d`` is hexified ASCII for ``-``.
This gets used a lot and it makes the names hard to read, so for the
rest of this document I'm going to replace ``\x2d`` by ``-`` without
mentioning it further.

systemd-cryptsetup(8) says that systemd uses
``systemd-cryptsetup-generator`` to translate ``/etc/crypttab`` into
units.  Reading systemd-cryptsetup-generator(8), it mentions that it
also uses some kernel command line options with ``luks`` in their
names, including the one that appears on my kernel command line::

  rd.luks.uuid=luks-3acca984-01a3-4c67-b9c6-94433f667b88

The ``/etc/crypttab`` in my initrd says::

  luks-3acca984-01a3-4c67-b9c6-94433f667b88 /dev/disk/by-uuid/3acca984-01a3-4c67-b9c6-94433f667b88 none discard

Putting the device in both places appears to be "belt-and-suspenders"
redundancy, because ``rd.luks.uuid`` is documented to "activate the
specified device as part of the boot process as if it was listed in
``/etc/crypttab``".

Documentation for ``systemd-cryptsetup-generator`` pointed to
systemd.generator(7).  This revealed that systemd has a general
concept of "generators", which are programs that run early in boot to
translate file formats foreign to systemd into units.  The manpage
gave an example for debugging a generator, so I ran::

  $ dir=$(mktemp -d)
  $ sudo SYSTEMD_LOG_LEVEL=debug /usr/lib/systemd/system-generators/systemd-cryptsetup-generator "$dir" "$dir" "$dir"

This generated a tree of directories and symlinks and some unit files.
The most interesting one was
``systemd-cryptsetup@luks-3acca984-01a3-4c67-b9c6-94433f667b88.service``,
which contained, among other things::

  ExecStart=/usr/lib/systemd/systemd-cryptsetup attach 'luks-3acca984-01a3-4c67-b9c6-94433f667b88' '/dev/disk/by-uuid/3acca984-01a3-4c67-b9c6-94433f667b88' 'none' 'discard'
  ExecStop=/usr/lib/systemd/systemd-cryptsetup detach 'luks-3acca984-01a3-4c67-b9c6-94433f667b88'

Looking around, the same file was in my running system in
``/run/systemd/generator``, so that's presumably the place that
systemd keeps it at runtime.

I noticed that ``systemd-cgls`` didn't list this slice, even though
the plot output showed it as living "forever".  I found the ``--all``
option to ``systemd-cgls``, for listing empty groups.  With that, I
found the slice.  Presumably, it could have new service units at
runtime if I connected a new encrypted disk, or as part of system
shutdown.

This service doesn't immediately prompt for the password.  Bootup
(from the initrd) continues.

Hibernate/Resume
----------------

The next row lists ``system-systemd-hibernate-resume.slice``.
This is for resume from hibernation.  I don't use this feature, so I
didn't look any deeper.

Journal Sockets
---------------

The next three lines in the plot are all for journal sockets::

  systemd-journald-audit.socket
  systemd-journald-dev-log.socket
  systemd-journald.socket

Each of these has a unit file in the initrd,
e.g. ``/usr/lib/systemd/system/systemd-journald.socket``.  Each of
these unit files causes systemd to listen on a socket listed in the
file (e.g. as ``ListenStream=/run/systemd/journal/stdout``) and then
pass any accepted connections to ``systemd-journald`` (because all of
them say ``Service=systemd-journald.service``).  See systemd.socket(5)
for details.

The "journal" is what systemd calls the log.  I don't know why it uses
that name.

Virtual Console Setup
---------------------

The next row is for ``systemd-vconsole-setup.service``.
systemd-vconsole-setup(8) documents that this reads
``/etc/vconsole.conf``.  In my initrd that file contains::

  KEYMAP="us"
  FONT="eurlatgr"

The documentation says that kernel command-line options can override
this file.  Mine don't.

I wish systemd were smarter about console fonts (or maybe it's Dracut
or Fedora that's responsible).  The one that it chooses on my system
is almost unreadable small (on a 4k screen).

Dracut Command Line Parsing
---------------------------

Dracut (see dracut(8)) is a program written in Bash that generates the
initrd that I'm using.  The next few rows in the startup plot relate
to Dracut.

The first one is ``dracut-cmdline.service``.  This service is
underdocumented: dracut-cmdline.service(8) just says that it runs
hooks to parse the kernel command line.  The service turns out to just
be a shell script ``/usr/bin/dracut-cmdline``.  When run, it sources
``/dracut-state.sh`` (yes, in the root!), if it exists, then
``/usr/lib/initrd-release`` (as we saw in `Initrd cpio Archive`_
earlier).  Each of these is a set of shell variable assignments.

Then the shell script looks at various parameters that might be
present in the kernel command line.  The kernel command options I have
set that Dracut or its hooks cares about are::

  root=/dev/mapper/fedora-root
  rd.luks.uuid=luks-3acca984-01a3-4c67-b9c6-94433f667b88
  rd.lvm.lv=fedora/root
  rd.lvm.lv=fedora/swap

Dracut itself looks at the ``root`` command-line parameter.  It also
invokes a string of hook scripts in ``/usr/lib/dracut/hooks/cmdline``.
These turn out to be important for my case:

* ``30-parse-crypt.sh`` looks at ``rd.luks.uuid`` and creates a rule
  in ``/etc/udev/rules.d/70-luks.rules``.  (I think so; if so, the
  rule doesn't make it into the booted system.)

* ``30-parse-lvm.sh`` looks at the ``rd.lvm.lv`` variables above.

These hooks create shell scripts in
``/lib/dracut/hooks/initqueue/finished``.  Each of these exits
successfully only if the appropriate device file exists (i.e. in
``/dev/disk`` or ``/dev/fedora``).  This enables the `Dracut Initqueue
Service`_, later, to know that initialization is complete.

Finally, it dumps the generated variables back into
``/dracut-state.sh``.  Other Dracut scripts that run later both source
this and update it.

(I wasn't able to get a sample of ``/dracut-state.sh`` from my own
system.  It disappears after boot is complete, as part of the
pivot_root operation, I believe.)

This script is, I believe, where the Dracut kernel command-line
options, which are listed in dracut.cmdline(7), get parsed, although
most of them actually take effect in a later stage.

Dracut Pre-udev service
-----------------------

The new row in the startup plot shows ``dracut-pre-udev.service``,
which runs ``/usr/bin/dracut-pre-udev``, which is a Bash script.  I
don't see anything significant that this does on my system.

configfs Mounting
-----------------

The next three rows appear to be related.  The third row is
``sys-kernel-configfs.mount``, which makes sure that ``configfs`` is
mounted at ``/sys/kernel/config``.  This unit depends on
``systemd-modules-load.service``; the second row reports starting
this.

The first row is for ``sys-module-fuse.device``, that is, loading the
``fuse`` module into the kernel as if with ``modprobe fuse``.  I don't
know why this gets loaded: it is listed in
``/usr/lib/modules-load.d/open-vm-tools.conf``, but the order is wrong
for that, and if the ``systemd-modules-load`` were loading it then it
would presumably also load the modules listed in
``/usr/lib/modules-load.d/VirtualBox.conf``, which it doesn't.

Dracut Initqueue Service
------------------------

The next row in the plot is for ``dracut-initqueue.service``.  Until
now, everything that has been started has either started and run
forever, or run to completion deterministically.  This new service is
different: it runs in a loop until it detects that initialization is
done.  On my system, this takes a long time overall (over 8 seconds in
the run I'm looking at) because it requires prompting me for a
password.

The loop does this:

* Checks whether startup is finished, by running all of the scripts
  in ``/lib/dracut/hooks/initqueue/finished/*.sh``.  If all of them
  exit successfully, startup is finished.

* Does various things to help startup along.  It's not clear to me
  that any of these trigger on my system.

* Eventually times out and offers an emergency shell to the user.

Plymouth Service
----------------

The ``plymouth-start.service`` unit, on the next row, covers up the
kernel initialization message with a graphical splash screen.  The
``plymouthd`` program only does that if the kernel command line
contains ``rhgb``, which stands for "Red Hat Graphical Boot".
(Plymouth is the successor to an older program named ``rhgb``.)

The next row is for ``systemd-ask-password-plymouth.path``.  This is a
new kind of unit to me, a "path" unit.  systemd.path(7) explains that
each of these units monitors a file or directory and triggers when
something happens.  In this case the path unit says::

  [Path]
  DirectoryNotEmpty=/run/systemd/ask-password
  MakeDirectory=yes

This means that when ``/run/systemd/ask-password`` is nonempty,
systemd triggers the corresponding service unit.  There is no ``Unit``
setting, so by default the service unit is
``systemd-ask-password-plymouth.service``.  There's nothing in the
directory being watched yet, so systemd defers starting the service.

Device Setup
------------

The next 64 (!) rows set up 32 (!) different ``ttyS<number>`` serial
devices, in random order.  I don't know why, since the laptop has no
traditional serial ports at all.  This doesn't take any real amount of
time, just an annoying number of useless entries in ``/dev``.

Then the next several rows set up all the devices for the SSD.  There
are four of them for the device itself (and its "namespace" ``n1``)::

  dev-disk-by-path-pci-0000:3d:00.0-nvme-1.device
  dev-disk-by-id-nvme-eui.ace42e0090114c8b.device
  dev-disk-by-id-nvme-PC401_NVMe_SK_hynix_1TB_MI93T003610303E06.device
  dev-nvme0n1.device
  sys-devices-pci0000:00-0000:00:1d.0-0000:3d:00.0-nvme-nvme0-nvme0n1.device

Then seven for the GRUB partition::

  dev-disk-by-id-nvme-PC401_NVMe_SK_hynix_1TB_MI93T003610303E06-part2.device
  dev-disk-by-id-nvme-eui.ace42e0090114c8b-part2.device
  dev-disk-by-partuuid-1d24a3b1-3131-4365-a3a7-dadae8ddf6fd.device
  dev-disk-by-path-pci-0000:3d:00.0-nvme-1-part2.device
  dev-disk-by-uuid-71baeefe-e3d2-45e1-a0ff-bf651d4a7591.device
  dev-nvme0n1p2.device
  sys-devices-pci0000:00-0000:00:1d.0-0000:3d:00.0-nvme-nvme0-nvme0n1-nvme0n1p2.device

and the same pattern carries on for the other two partitions.
Partition 1 is last; maybe the order is random.

Password Prompting
------------------

Amid the disk device setup, just after the setup for the encrypted
nvme0n1p2 device, a row lists
``systemd-cryptsetup@luks-3acca984-01a3-4c67-b9c6-94433f667b88.service``.
This is the service unit created by the generator described under
`Encrypted Disk Setup`_ earlier.  As shown before, this service runs
``systemd-cryptsetup`` to attach the encrypted volume::

  ExecStart=/usr/lib/systemd/systemd-cryptsetup attach 'luks-3acca984-01a3-4c67-b9c6-94433f667b88' '/dev/disk/by-uuid/3acca984-01a3-4c67-b9c6-94433f667b88' 'none' 'discard'

The ``systemd-cryptsetup`` helper is underdocumented, but running it
without arguments gives a little bit of help::

  $ /usr/lib/systemd/systemd-cryptsetup
  systemd-cryptsetup attach VOLUME SOURCEDEVICE [PASSWORD] [OPTIONS]
  systemd-cryptsetup detach VOLUME

  Attaches or detaches an encrypted block device.

  See the systemd-cryptsetup@.service(8) man page for details.

Peeking into the helper's source code, it calls into
ask_password_agent() in systemd's ``src/shared/ask-password-api.c``.
In turn, this creates a file
``/run/systemd/ask-password/ask.<random>`` with some information about
the password to be prompted for.

Now, the path unit described in `Plymouth Service`_ triggers its
corresponding service unit ``systemd-ask-password-plymouth.service``,
which is the next row in the plot.

In turn, the service unit gets systemd to ask for the password::

  [Service]
  ExecStart=/usr/bin/systemd-tty-ask-password-agent --watch --plymouth

About 7 seconds later, I've finished typing the password, which allows
the ``systemd-cryptsetup@…`` unit to finish up.  The
``systemd-ask-password-plymouth.service`` unit exits about a second
later, I believe because it is killed by ``initrd-cleanup.service``
(see `Switching Roots`_).

The next row in the plot is for
``sys-devices-pci0000:00-0000:00:02.0-drm-card0-card0-eDP-1-intel_backlight.device``.
I guess this is just random ordering.

Inner Encrypted Device Setup
----------------------------

The successful unlocking of the encrypted block device made everything
inside visible to the device manager.  The first set of rows shows the
top-level device, which becomes ``/dev/dm-0``.  Note that the system
considers this device's UUID so fantastic that one of the device nodes
contains it **twice**::

  dev-disk-by-id-dm-name-luks-3acca984-01a3-4c67-b9c6-94433f667b88.device
  dev-disk-by-id-lvm-pv-uuid-yFbXNn-DjBz-J9c1-c7Pj-QIKZ-JoiH-k5wQWR.device
  dev-mapper-luks-3acca984-01a3-4c67-b9c6-94433f667b88.device
  dev-disk-by-id-dm-uuid-CRYPT-LUKS2-3acca98401a34c67b9c694433f667b88-luks-3acca984-01a3-4c67-b9c6-94433f667b88.device
  dev-dm-0.device
  sys-devices-virtual-block-dm-0.device

The next series of rows makes the root device within the encrypted
block device visible as ``/dev/dm-1`` aka ``/dev/fedora/root``::

  dev-mapper-fedora-root.device
  dev-disk-by-uuid-45501fb7-be9f-4f11-97ba-b2c2046fd746.device
  dev-disk-by-id-dm-uuid-LVM-mMVYE2s7gIvVmpHUl0cvxbfn8i8NODO8bRKuGAOpNVTVjPrca5QTzb5F3eXjOglK.device
  dev-fedora-root.device
  dev-disk-by-id-dm-name-fedora-root.device
  dev-dm-1.device
  sys-devices-virtual-block-dm-1.device

systemd notes in the next row that ``initrd-root-device.target`` is
now satisfied, because the root file system's device is now available.
It isn't mounted yet.

The next series of rows makes the swap device visible as ``/dev/dm-2``
aka ``/dev/fedora/swap``.  It isn't being used for swap yet::

  dev-disk-by-id-dm-name-fedora-swap.device
  dev-mapper-fedora-swap.device
  dev-disk-by-id-dm-uuid-LVM-mMVYE2s7gIvVmpHUl0cvxbfn8i8NODO8qImL9xOU61DWKST2SpEEw3aF0kARK3oK.device
  dev-disk-by-uuid-71cdb103-4791-4d43-aa4c-49743c36be6e.device
  dev-fedora-swap.device
  dev-dm-2.device
  sys-devices-virtual-block-dm-2.device

Root Filesystem
---------------

The next row is ``systemd-fsck-root.service``, which is
underdocumented.  It looks like a special systemd service, but it
isn't documented in systemd.special(7).  I guess it fscks
``/dev/fedora/root``.

Next, ``sysroot.mount`` mounts ``/dev/fedora/root`` on ``/sysroot``.
Later, this will become the root of the file system.  The
``sysroot.mount`` unit was previously generated automatically by
``systemd-fstab-generator``.  This generation is hardcoded into the C
code of ``systemd-fstab-generator``.

Final initrd Targets
--------------------

The next row is for ``initrd-parse-etc.service``.  This invokes
``initrd-fs.target``, the next row, which is followed by
``initrd.target``.  None of these seem to do anything significant on
my machine.

Switching Roots
---------------

Now it's time for ``/sysroot`` to become ``/`` and everything not
under ``/sysroot`` to go away.

The next row is ``dracut-pre-pivot.service``.  This runs Dracut's
"pre-pivot" and "cleanup" hooks.  These don't seem to do anything
important on my system.  (I've ignored the scripts that Dracut has
run, across its various hooks, related to keeping network interface
names persistent across boots.  I'm continuing to ignore them here.
Maybe I'll look into them in later revisions of this document.)

The next row is ``initrd-cleanup.service``, which is defined as::

  [Service]
  Type=oneshot
  ExecStart=systemctl --no-block isolate initrd-switch-root.target

The ``isolate`` command was new to me.  systemctl(1) says that it
starts the argument unit and stops everything else, with an exception
for units marked as ``IgnoreOnIsolate=yes``.  For me, the latter units
(based on ``grep``) are ``systemd-journald-dev-log.socket`` and
``systemd-journald.socket``.  I see that
``systemd-journald-audit.socket`` also continues, so perhaps sockets
are generally excepted.  In practice, only a few units terminate right
at this point (possibly some of these are by coincidence)::

  dracut-cmdline.service
  dracut-pre-udev.service
  dracut-initqueue.service
  systemd-ask-password-plymouth.service
  initrd-root-device.target
  initrd.target

Two services are marked as ``Before=initrd-switch-root.target``.
These are the next two rows:

* ``plymouth-switch-root.service``, which runs ``/usr/bin/plymouth
  update-root-fs --new-root-dir=/sysroot``.  plymouth(1) says that
  this tells the ``plymouth`` daemon about the upcoming root file
  system change.  It doesn't say anything about the implications of
  the root change or the notification, though.

* ``initrd-udevadm-cleanup-db.service``, which runs ``udevadm info
  --cleanup-db``.  udevadm(1) says that this makes ``udev`` clean up
  its database.  It does not explain what this means, but udev(7)
  gives the hint that the ``db_persist`` flag on a database event
  means that it will be kept even after ``--cleanup-db``.  A ``grep``
  shows that ``db_persist`` only shows up in
  ``/etc/udev/rules.d/11-dm.rules``.  This would seem to mean that
  only device manager nodes would be kept across ``--cleanup-db``.
  This is wrong (the ``ttyS<number>`` nodes, at least, are also kept),
  so there must be more going on.  I didn't investigate further.

After that, ``initrd-switch-root.target`` triggers.  It runs
``systemctl --no-block switch-root /sysroot``.  This does the actual
switch of root directories inside systemd's at PID 1 process:

* Creates a memory-based file using ``memfd_create()`` and serializes
  all the systemd state to it.

* Un-set some limits, etc., so that the new systemd knows what the
  defaults should be.

* Switches root.  There's a ``pivot_root`` system call that it tries
  to use first, followed by unmounting the old root in its new
  location.  This approach won't necessarily work, so as an
  alternative it does the system call equivalent of
  ``mount --move /sysroot /``.

* Deletes all of the old initrd using the equivalent of ``rm -rf
  old_root``.  This mildly scares the crap out of me, but it *should*
  only destroy files that were extracted from the initrd cpio image.

* Re-execs itself as
  ``/usr/lib/systemd/systemd --switched-root --system --deserialize
  <fd>``, where <fd> is a file descriptor for the state serialized
  earlier.

* The new systemd starts and initializes itself using the serialized
  state from <fd>.
