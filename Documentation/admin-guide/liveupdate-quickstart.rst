.. SPDX-License-Identifier: GPL-2.0

==========================================
Live Update Orchestrator (LUO) Quick Start
==========================================

:Author: Pasha Tatashin <pasha.tatashin@soleen.com>

This is a quick reference guide for using the Live Update Orchestrator (LUO).
For detailed information, see :doc:`liveupdate-usage`.

Prerequisites
=============

1. Kernel compiled with::

    CONFIG_KEXEC_HANDOVER=y
    CONFIG_LIVEUPDATE=y
    CONFIG_KEXEC_FILE=y

2. Kernel command line includes::

    kho=on liveupdate=on

3. Install kexec-tools package on your distribution

Quick Workflow
==============

Stage 1: Before Reboot (Current Kernel)
----------------------------------------

**1. Write your preservation code**::

    int luo_fd = open("/dev/liveupdate", O_RDWR);
    
    // Create session
    struct liveupdate_ioctl_create_session create_args = {
        .size = sizeof(create_args),
    };
    strncpy((char *)create_args.name, "my-session", sizeof(create_args.name) - 1);
    ioctl(luo_fd, LIVEUPDATE_IOCTL_CREATE_SESSION, &create_args);
    int session_fd = create_args.fd;
    
    // Preserve your file descriptor
    struct liveupdate_session_preserve_fd preserve_args = {
        .size = sizeof(preserve_args),
        .fd = your_memfd,
        .token = 0x1234,
    };
    ioctl(session_fd, LIVEUPDATE_SESSION_PRESERVE_FD, &preserve_args);
    
    close(session_fd);
    close(luo_fd);

**2. Load new kernel**::

    sudo kexec -l -s --reuse-cmdline /boot/vmlinuz

**3. Trigger reboot**::

    sudo kexec -e

Stage 2: After Reboot (New Kernel)
-----------------------------------

**1. Write your restoration code**::

    int luo_fd = open("/dev/liveupdate", O_RDWR);
    
    // Retrieve session
    struct liveupdate_ioctl_retrieve_session retrieve_args = {
        .size = sizeof(retrieve_args),
    };
    strncpy((char *)retrieve_args.name, "my-session", sizeof(retrieve_args.name) - 1);
    ioctl(luo_fd, LIVEUPDATE_IOCTL_RETRIEVE_SESSION, &retrieve_args);
    int session_fd = retrieve_args.fd;
    
    // Restore your file descriptor
    struct liveupdate_session_retrieve_fd restore_args = {
        .size = sizeof(restore_args),
        .token = 0x1234,
    };
    ioctl(session_fd, LIVEUPDATE_SESSION_RETRIEVE_FD, &restore_args);
    int restored_fd = restore_args.fd;
    
    // Use your restored file descriptor
    // ...
    
    // Finish session
    struct liveupdate_session_finish finish_args = {
        .size = sizeof(finish_args),
    };
    ioctl(session_fd, LIVEUPDATE_SESSION_FINISH, &finish_args);
    
    close(session_fd);
    close(luo_fd);

Command Line Reference
======================

**Enable LUO at boot**::

    kho=on liveupdate=on

**Optional: Set scratch size**::

    kho_scratch=1G

**Load new kernel**::

    kexec -l -s --reuse-cmdline /boot/vmlinuz [--initrd=/boot/initramfs]

**Execute kexec**::

    kexec -e

**Check if LUO is enabled**::

    cat /proc/cmdline | grep liveupdate
    ls -l /dev/liveupdate

IOCTLs Quick Reference
======================

Main Device (/dev/liveupdate)
------------------------------

* ``LIVEUPDATE_IOCTL_CREATE_SESSION`` - Create a new session
* ``LIVEUPDATE_IOCTL_RETRIEVE_SESSION`` - Retrieve preserved session

Session File Descriptor
------------------------

* ``LIVEUPDATE_SESSION_PRESERVE_FD`` - Preserve a file descriptor
* ``LIVEUPDATE_SESSION_RETRIEVE_FD`` - Restore a file descriptor
* ``LIVEUPDATE_SESSION_FINISH`` - Complete session restoration

Headers to Include
==================

::

    #include <linux/liveupdate.h>
    #include <sys/ioctl.h>
    #include <fcntl.h>

Testing
=======

**Run kernel self-tests**::

    cd tools/testing/selftests/liveupdate
    make
    sudo ./liveupdate
    sudo ./luo_kexec_simple

**Use test script**::

    cd tools/testing/selftests/liveupdate
    sudo ./do_kexec.sh

Common Pitfalls
===============

1. **Forgetting to close session_fd before kexec** - Not critical but good practice
2. **Using different session names** - Names must match exactly
3. **Not calling FINISH** - Session resources won't be released
4. **Using same token for different FDs** - Tokens must be unique per session

Troubleshooting
===============

**Problem**: /dev/liveupdate doesn't exist

**Solution**: Check CONFIG_LIVEUPDATE=y and rebuild kernel

----

**Problem**: kexec fails to load

**Solution**: Ensure kho=on in cmdline and CONFIG_KEXEC_FILE=y

----

**Problem**: Kernel signature verification failed (-129)

**Solution**: Either sign kernel image or rebuild with CONFIG_KEXEC_SIG_FORCE disabled

----

**Problem**: Session not found (ENOENT)

**Solution**: Verify session was created and kexec completed successfully

----

**Problem**: Enable kernel debug output

**Solution**::

    echo 8 > /proc/sys/kernel/printk
    dmesg -w

See Also
========

* :doc:`liveupdate-usage` - Complete LUO usage guide
* Documentation/core-api/liveupdate.rst - Core API documentation
* Documentation/userspace-api/liveupdate.rst - Userspace API reference
* Documentation/core-api/kho/concepts.rst - KHO concepts
