# cloudsh-init

This project aims to provide simpler and faster instance initialization compared to cloud-init in pure shell. Note that it's currently tested only on Debian Bookworm and requires Dash.

> **NOTE**: cloudsh-init is not suitable for production usage. It's been developed as an experiment to accelerate creation of local development instances.

# Why?

cloud-init can take as much as 3 seconds to do a basic operations like writing an APT sources files and setting up an administrative account, e.g.:

First boot:

```
root@debian:~# systemd-analyze critical-chain
graphical.target @6.493s
└─multi-user.target @6.492s
  └─ssh.service @6.399s +85ms
    └─basic.target @6.365s
      └─sockets.target @6.364s
        └─uuidd.socket @6.364s
          └─sysinit.target @6.359s
            └─cloud-init.service @3.744s +2.609s
              └─systemd-networkd-wait-online.service @2.299s +1.427s
                └─systemd-networkd.service @2.256s +39ms
                  └─network-pre.target @2.238s
                    └─cloud-init-local.service @626ms +1.611s
                      └─systemd-remount-fs.service @549ms +56ms
                        └─systemd-journald.socket @438ms
                          └─-.mount @365ms
                            └─-.slice @365ms
```

Next boots:

```
root@debian:~# systemd-analyze critical-chain
graphical.target @4.711s
└─multi-user.target @4.710s
  └─systemd-logind.service @4.576s +104ms
    └─basic.target @4.543s
      └─sockets.target @4.542s
        └─uuidd.socket @4.541s
          └─sysinit.target @4.525s
            └─cloud-init.service @3.744s +777ms
              └─systemd-networkd-wait-online.service @2.003s +1.719s
                └─systemd-networkd.service @1.960s +39ms
                  └─network-pre.target @1.942s
                    └─cloud-init-local.service @612ms +1.328s
                      └─systemd-remount-fs.service @543ms +53ms
                        └─systemd-journald.socket @432ms
                          └─system.slice @359ms
                            └─-.slice @361ms
```

With cloudsh-init:

First and next boots(with only slight deviations):

```
root@debian:~# systemd-analyze critical-chain
graphical.target @2.543s
└─multi-user.target @2.541s
  └─cloudsh-init-final.service @2.381s +158ms
    └─network-online.target @2.365s
      └─systemd-networkd-wait-online.service @1.205s +1.158s
        └─systemd-networkd.service @1.153s +32ms
          └─network-pre.target @1.136s
            └─cloudsh-init-local.service @402ms +732ms
              └─systemd-remount-fs.service @339ms +46ms
                └─systemd-journald.socket @229ms
                  └─-.mount @160ms
                    └─-.slice @160ms
```

Above measurements are by no means exhaustive nor definitive. While using QEMU, author have found out that instances without `-nodefaults` flag start slower due to [cloud-init repeatedly invoking blkid](https://github.com/canonical/cloud-init/blob/441d8f818de7e08836f43d1b9a1a4418f341b1a5/cloudinit/sources/DataSourceNoCloud.py#L40). Switching to a single `blkid --output export` and parsing output in shell yielded over 1 second improvement on startup. Root cause for slowdown seems to be accessing CD devices, e.g.:

On QEMU instance without `-nodefaults`:

```
root@debian:~# strace -f -T blkid 2>&1 >/dev/null | while read -r line; do a=$(printf "%s" "$line" | rev | cut -f 1 -d " " | rev); printf "%s %s\n" "$a" "$line"; done | sort -rn | head                            
<0.060240> openat(AT_FDCWD, "/dev/sr0", O_RDONLY|O_NONBLOCK|O_CLOEXEC) = 6 <0.060240>
<0.038833> ioctl(6, CDROM_DRIVE_STATUS, 0x7fffffff) = 1 <0.038833>
<0.036078> close(6)                                = 0 <0.036078>
<0.000602> read(6, "\377CD001\1", 7)               = 7 <0.000602>
<0.000361> fadvise64(6, 0, 0, POSIX_FADV_RANDOM)   = 0 <0.000361>
<0.000347> read(3, "<device DEVNO=\"0xfe10\" TIME=\"169"..., 4096) = 510 <0.000347>
<0.000292> read(6, "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"..., 512) = 512 <0.000292>
<0.000289> lseek(6, 32768, SEEK_SET)               = 32768 <0.000289>
<0.000226> execve("/usr/sbin/blkid", ["blkid"], 0x7fff3ad27ab0 /* 11 vars */) = 0 <0.000226>
```

On QEMU instance with `-nodefaults`:

```
root@debian:~# strace -f -T blkid 2>&1 >/dev/null | while read -r line; do a=$(printf "%s" "$line" | rev | cut -f 1 -d " " | rev); printf "%s %s\n" "$a" "$line"; done | sort -rn | head
<0.000890> read(6, "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"..., 1024) = 1024 <0.000890>
<0.000655> read(6, "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"..., 1024) = 1024 <0.000655>
<0.000593> read(6, "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"..., 512) = 512 <0.000593>
<0.000529> read(6, "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"..., 262144) = 262144 <0.000529>
<0.000290> execve("/usr/sbin/blkid", ["blkid"], 0x7ffc082d8960 /* 11 vars */) = 0 <0.000290>
<0.000267> read(6, "l\372\310\\\0\336w8m\235>\2625\324#3:>\357\370\371\324\242\371\31\266\326\346\2419#U"..., 1024) = 1024 <0.000267>
<0.000218> read(6, "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"..., 1024) = 1024 <0.000218>
<0.000211> read(6, "\353<\220mkfs.fat\0\2\4\4\0\2\0\2\0\0\370\370\0?\0\200\0\0 \0\0"..., 262144) = 262144 <0.000211>
<0.000189> read(6, "\377CD001\1", 7)               = 7 <0.000189>
```

# Limitations

Only nocloud data source is supported. It expects to find 2 executable files on cidata disk:

- local - Launched before networking
- final - Launched as late as possible

Unlike cloud-init, no systemd target is created using generators, so compatibility can't be guaranteed. cloudsh-init attempts to fit into multi-user target. Also no modules from cloud-init are implemented here. User is expected to provide self-contained executables.
