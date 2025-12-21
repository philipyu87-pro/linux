.. SPDX-License-Identifier: GPL-2.0

========================================
Live Update Orchestrator (LUO) Usage Guide
========================================

:Author: Pasha Tatashin <pasha.tatashin@soleen.com>

What is LUO (Live Update Orchestrator)?
========================================

Live Update Orchestrator (LUO) is a kexec-based kernel live update mechanism that
allows a running Linux kernel to be updated from one version to another while
preserving the state of selected resources and keeping designated hardware devices
operational.

Key Use Cases
-------------

* **Virtualization environments**: Update hypervisor kernel without interrupting VMs
* **Memory cache services**: Maintain cache data in systems like memcached
* **High-performance databases**: Keep database memory state during kernel updates
* **Network services**: Preserve connection states for network services

Important Limitations
---------------------

LUO is a **data preservation mechanism**, not process migration or live migration.
Understanding what is and isn't preserved is critical:

**What LUO Preserves:**

* Physical memory contents (e.g., data in memfd pages)
* File descriptor state for supported types (memfd, device FDs with driver support)
* Hardware device states (with driver support)

**What LUO Does NOT Preserve:**

* **Process state**: Processes must restart; LUO doesn't preserve running processes
* **Page tables**: Virtual address mappings are not preserved; the new kernel creates new page tables
* **Virtual addresses**: Physical pages are preserved, but virtual addresses may change
* **Process memory (stack, heap, code)**: Only explicitly preserved FDs (like memfd) retain data
* **Register state, CPU context**: Processes start fresh in the new kernel

**Workflow Required:**

1. **Before kexec**: Application saves critical data to memfd (or other supported FD types)
2. **After kexec**: Application restarts and uses LUO API to retrieve preserved data
3. Application reconstructs its state using the preserved data

This design allows kernel updates while preserving application data, but requires
applications to be "LUO-aware" and actively participate in the preservation/restoration
process.

Kernel Configuration
====================

To use LUO, enable the following kernel configuration options::

    CONFIG_KEXEC_HANDOVER=y         # Kexec HandOver support
    CONFIG_LIVEUPDATE=y             # Live Update Orchestrator
    CONFIG_KEXEC_FILE=y             # Kexec file loading
    CONFIG_MEMBLOCK_KHO_SCRATCH=y   # KHO scratch region support

Optional configurations::

    CONFIG_KEXEC_HANDOVER_DEBUG=y           # Enable extra debugging checks
    CONFIG_KEXEC_HANDOVER_DEBUGFS=y         # DebugFS interface
    CONFIG_KEXEC_HANDOVER_ENABLE_DEFAULT=y  # Enable KHO by default

Kernel Command Line Parameters
===============================

Reserving Memory for the New Kernel
------------------------------------

**1. Enable Kexec HandOver (KHO)**

KHO is the underlying mechanism that LUO uses to transfer memory state between
kernels::

    kho=on

If ``CONFIG_KEXEC_HANDOVER_ENABLE_DEFAULT`` is enabled at compile time, KHO is
enabled by default and can be disabled with ``kho=off``.

**2. Enable Live Update**

Add to kernel command line::

    liveupdate=on

**3. Configure Scratch Region Size (Optional)**

Scratch regions are physically contiguous memory areas used for loading the new
kernel and initrd. By default, the system automatically calculates scratch region
size based on boot-time memory allocation. To explicitly specify the size::

    kho_scratch=<size>

Where <size> can be a number in bytes, or use K/M/G suffix (e.g., 512M, 1G).

**Complete Command Line Examples**::

    linux /boot/vmlinuz root=/dev/sda1 kho=on liveupdate=on

Or with explicit scratch size::

    linux /boot/vmlinuz root=/dev/sda1 kho=on liveupdate=on kho_scratch=1G

Memory Layout
-------------

When KHO is enabled, the system allocates the following memory regions:

1. **Scratch regions**: Physically contiguous memory for kexec loading
   
   - One scratch region per NUMA node
   - One scratch region for non-NUMA-specific allocations
   - These regions are declared as CMA after page allocator initialization

2. **Preserved regions**: Memory for storing serialized system state and data
   that must be retained across kexec

How to Initiate Live Update from Userspace
===========================================

LUO provides a userspace interface through the ``/dev/liveupdate`` character device.

Device File
-----------

::

    /dev/liveupdate

This device can only be opened by one process at a time (exclusive access).

Basic Workflow
--------------

A live update consists of two stages:

**Stage 1: Preparation Phase (Current Kernel)**

1. Open ``/dev/liveupdate`` device
2. Create session(s)
3. Preserve file descriptors that need to be retained
4. Execute kexec to load new kernel
5. Trigger kexec reboot

**Stage 2: Recovery Phase (New Kernel)**

1. After new kernel boots, open ``/dev/liveupdate`` device
2. Retrieve previously created session(s)
3. Restore preserved file descriptors
4. Finish session(s)

Detailed API Reference
======================

Opening the Device
------------------

::

    int luo_fd = open("/dev/liveupdate", O_RDWR);
    if (luo_fd < 0) {
        perror("Failed to open /dev/liveupdate");
        exit(1);
    }

Creating a Session
------------------

Use the ``LIVEUPDATE_IOCTL_CREATE_SESSION`` ioctl to create a session::

    #include <linux/liveupdate.h>
    
    struct liveupdate_ioctl_create_session args = {
        .size = sizeof(args),
    };
    strncpy((char *)args.name, "my-session", sizeof(args.name) - 1);
    
    if (ioctl(luo_fd, LIVEUPDATE_IOCTL_CREATE_SESSION, &args) < 0) {
        perror("Failed to create session");
        exit(1);
    }
    
    int session_fd = args.fd;

Preserving File Descriptors
----------------------------

Use the ``LIVEUPDATE_SESSION_PRESERVE_FD`` ioctl to preserve a file descriptor::

    struct liveupdate_session_preserve_fd preserve_args = {
        .size = sizeof(preserve_args),
        .fd = memfd,        // File descriptor to preserve
        .token = 0x1234,    // User-defined unique identifier
    };
    
    if (ioctl(session_fd, LIVEUPDATE_SESSION_PRESERVE_FD, &preserve_args) < 0) {
        perror("Failed to preserve fd");
        exit(1);
    }

Currently supported file descriptor types:

* memfd (memory file descriptors)
* Other types require driver support (e.g., KVM, VFIO)

Retrieving Sessions (In New Kernel)
------------------------------------

After the new kernel boots, use ``LIVEUPDATE_IOCTL_RETRIEVE_SESSION`` to retrieve
a session::

    struct liveupdate_ioctl_retrieve_session retrieve_args = {
        .size = sizeof(retrieve_args),
    };
    strncpy((char *)retrieve_args.name, "my-session", sizeof(retrieve_args.name) - 1);
    
    if (ioctl(luo_fd, LIVEUPDATE_IOCTL_RETRIEVE_SESSION, &retrieve_args) < 0) {
        perror("Failed to retrieve session");
        exit(1);
    }
    
    int session_fd = retrieve_args.fd;

Restoring File Descriptors
---------------------------

Use the ``LIVEUPDATE_SESSION_RETRIEVE_FD`` ioctl to restore a file descriptor::

    struct liveupdate_session_retrieve_fd restore_args = {
        .size = sizeof(restore_args),
        .token = 0x1234,    // Token used when preserving
    };
    
    if (ioctl(session_fd, LIVEUPDATE_SESSION_RETRIEVE_FD, &restore_args) < 0) {
        perror("Failed to retrieve fd");
        exit(1);
    }
    
    int restored_fd = restore_args.fd;

Finishing Sessions
------------------

Use the ``LIVEUPDATE_SESSION_FINISH`` ioctl to complete a session::

    struct liveupdate_session_finish finish_args = {
        .size = sizeof(finish_args),
        .reserved = 0,
    };
    
    if (ioctl(session_fd, LIVEUPDATE_SESSION_FINISH, &finish_args) < 0) {
        perror("Failed to finish session");
        exit(1);
    }

Where to Place the New Kernel
==============================

Kernel Image Location
---------------------

The new kernel image should be placed in an accessible location on the filesystem.
Common locations include:

* ``/boot/vmlinuz`` - Default kernel image location
* ``/boot/bzImage`` - Compressed kernel image
* Custom path - Any readable filesystem path

Loading the New Kernel with kexec
----------------------------------

Use the kexec tool to load the new kernel::

    # Basic usage
    kexec -l /boot/vmlinuz --reuse-cmdline
    
    # With initramfs
    kexec -l /boot/vmlinuz --initrd=/boot/initramfs --reuse-cmdline
    
    # Specifying new command line parameters
    kexec -l /boot/vmlinuz --append="root=/dev/sda1 kho=on liveupdate=on"

**Important Parameters**:

* ``-l`` or ``--load``: Load new kernel into memory
* ``-s`` or ``--kexec-file-syscall``: Use kexec_file_load syscall (recommended for LUO)
* ``--reuse-cmdline``: Reuse current kernel's command line parameters
* ``--append``: Specify new kernel command line parameters
* ``--initrd``: Specify initramfs image

Executing the kexec Reboot
---------------------------

After loading the new kernel, trigger the reboot::

    kexec -e

Or::

    systemctl kexec

Complete Examples
=================

Simple Live Update Script
--------------------------

.. code-block:: bash

    #!/bin/bash
    # Simple kernel live update script
    
    set -e
    
    KERNEL="${KERNEL:-/boot/vmlinuz}"
    INITRAMFS="${INITRAMFS:-/boot/initramfs}"
    
    echo "Loading new kernel: $KERNEL"
    
    # Load new kernel
    if [ -f "$INITRAMFS" ]; then
        kexec -l -s --reuse-cmdline "$KERNEL" --initrd="$INITRAMFS"
    else
        kexec -l -s --reuse-cmdline "$KERNEL"
    fi
    
    echo "Kernel loaded successfully"
    echo "Executing kexec..."
    
    # Execute kexec reboot
    kexec -e

C Program Example
-----------------

Complete C program example::

    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <fcntl.h>
    #include <unistd.h>
    #include <sys/ioctl.h>
    #include <sys/mman.h>
    #include <linux/liveupdate.h>
    #include <linux/memfd.h>
    
    #define SESSION_NAME "example-session"
    #define MEMFD_TOKEN 0x1234
    #define TEST_DATA "Hello Live Update!"
    
    int main(int argc, char *argv[])
    {
        int luo_fd, session_fd, memfd;
        struct liveupdate_ioctl_create_session create_args;
        struct liveupdate_ioctl_retrieve_session retrieve_args;
        struct liveupdate_session_preserve_fd preserve_args;
        struct liveupdate_session_retrieve_fd restore_args;
        struct liveupdate_session_finish finish_args;
        char buffer[256];
        ssize_t n;
        
        // Open /dev/liveupdate
        luo_fd = open("/dev/liveupdate", O_RDWR);
        if (luo_fd < 0) {
            perror("open /dev/liveupdate");
            return 1;
        }
        
        if (argc > 1 && strcmp(argv[1], "restore") == 0) {
            // Restore phase (in new kernel)
            printf("Restoring session...\n");
            
            memset(&retrieve_args, 0, sizeof(retrieve_args));
            retrieve_args.size = sizeof(retrieve_args);
            strncpy((char *)retrieve_args.name, SESSION_NAME, 
                    sizeof(retrieve_args.name) - 1);
            
            if (ioctl(luo_fd, LIVEUPDATE_IOCTL_RETRIEVE_SESSION, 
                      &retrieve_args) < 0) {
                perror("LIVEUPDATE_IOCTL_RETRIEVE_SESSION");
                return 1;
            }
            
            session_fd = retrieve_args.fd;
            printf("Session retrieved, fd=%d\n", session_fd);
            
            // Restore memfd
            memset(&restore_args, 0, sizeof(restore_args));
            restore_args.size = sizeof(restore_args);
            restore_args.token = MEMFD_TOKEN;
            
            if (ioctl(session_fd, LIVEUPDATE_SESSION_RETRIEVE_FD, 
                      &restore_args) < 0) {
                perror("LIVEUPDATE_SESSION_RETRIEVE_FD");
                return 1;
            }
            
            memfd = restore_args.fd;
            printf("memfd restored, fd=%d\n", memfd);
            
            // Verify data
            lseek(memfd, 0, SEEK_SET);
            n = read(memfd, buffer, sizeof(buffer));
            if (n > 0) {
                buffer[n] = '\0';
                printf("Read data: %s\n", buffer);
            }
            
            close(memfd);
            
            // Finish session
            memset(&finish_args, 0, sizeof(finish_args));
            finish_args.size = sizeof(finish_args);
            
            if (ioctl(session_fd, LIVEUPDATE_SESSION_FINISH, &finish_args) < 0) {
                perror("LIVEUPDATE_SESSION_FINISH");
                return 1;
            }
            
            printf("Session finished successfully\n");
            close(session_fd);
            
        } else {
            // Preserve phase (current kernel)
            printf("Creating session...\n");
            
            memset(&create_args, 0, sizeof(create_args));
            create_args.size = sizeof(create_args);
            strncpy((char *)create_args.name, SESSION_NAME, 
                    sizeof(create_args.name) - 1);
            
            if (ioctl(luo_fd, LIVEUPDATE_IOCTL_CREATE_SESSION, 
                      &create_args) < 0) {
                perror("LIVEUPDATE_IOCTL_CREATE_SESSION");
                return 1;
            }
            
            session_fd = create_args.fd;
            printf("Session created, fd=%d\n", session_fd);
            
            // Create memfd and write data
            memfd = memfd_create("test-memfd", 0);
            if (memfd < 0) {
                perror("memfd_create");
                return 1;
            }
            
            write(memfd, TEST_DATA, strlen(TEST_DATA));
            printf("Created memfd=%d with data: %s\n", memfd, TEST_DATA);
            
            // Preserve memfd
            memset(&preserve_args, 0, sizeof(preserve_args));
            preserve_args.size = sizeof(preserve_args);
            preserve_args.fd = memfd;
            preserve_args.token = MEMFD_TOKEN;
            
            if (ioctl(session_fd, LIVEUPDATE_SESSION_PRESERVE_FD, 
                      &preserve_args) < 0) {
                perror("LIVEUPDATE_SESSION_PRESERVE_FD");
                return 1;
            }
            
            printf("memfd preserved with token 0x%llx\n", 
                   (unsigned long long)MEMFD_TOKEN);
            
            close(memfd);
            close(session_fd);
            
            printf("\nNow you can execute kexec:\n");
            printf("  kexec -l -s --reuse-cmdline /boot/vmlinuz\n");
            printf("  kexec -e\n");
            printf("\nAfter reboot, run: %s restore\n", argv[0]);
        }
        
        close(luo_fd);
        return 0;
    }

Testing and Verification
=========================

Kernel Self-Tests
-----------------

The Linux kernel source includes a complete LUO test suite::

    cd tools/testing/selftests/liveupdate
    make
    
    # Run basic tests
    ./liveupdate
    
    # Run kexec tests (requires root privileges)
    sudo ./luo_kexec_simple

Test Script
-----------

Use the kernel's built-in kexec test script::

    cd tools/testing/selftests/liveupdate
    sudo ./do_kexec.sh

This script will:

1. Set environment variables ``KERNEL`` and ``INITRAMFS`` (if not already set)
2. Load the new kernel using kexec
3. Execute kexec reboot

Troubleshooting
===============

Common Issues
-------------

**1. /dev/liveupdate does not exist**

Check that kernel configuration ``CONFIG_LIVEUPDATE=y`` is enabled and rebuild
the kernel.

**2. kexec load fails**

Ensure:

- ``CONFIG_KEXEC_FILE=y`` is enabled
- Kernel command line includes ``kho=on``
- Sufficient memory is available for scratch regions

**3. Kernel signature verification failed**

Error message: ``kexec_file: Enforced kernel signature verification failed (-129)``

This occurs when ``CONFIG_KEXEC_SIG_FORCE`` is enabled, requiring all kexec'd
kernels to have valid signatures.

Solutions:

- Sign the kernel image with a valid key in the kernel keyring, or
- Rebuild the kernel with ``CONFIG_KEXEC_SIG_FORCE`` disabled (keep ``CONFIG_KEXEC_FILE=y``)
- If using signed kernels, ensure the signing key is in the system keyring

To check if signature enforcement is enabled::

    grep CONFIG_KEXEC_SIG_FORCE /boot/config-$(uname -r)

**4. Session retrieval fails (ENOENT)**

Ensure:

- Session was successfully created in old kernel
- Session name matches exactly
- kexec successfully transferred KHO data

**5. File descriptor preservation fails**

Ensure:

- FD type is supported (e.g., memfd)
- Related drivers are loaded and support LUO
- No out-of-memory condition

Debugging Methods
-----------------

**Enable Debug Output**::

    echo 8 > /proc/sys/kernel/printk
    dmesg -w

**Check KHO Status**:

If ``CONFIG_KEXEC_HANDOVER_DEBUGFS`` is enabled::

    mount -t debugfs none /sys/kernel/debug
    cat /sys/kernel/debug/kho/status

**Verify Kernel Parameters**::

    cat /proc/cmdline | grep -E "kho|liveupdate"

References
==========

* Documentation/core-api/liveupdate.rst - LUO core API documentation
* Documentation/userspace-api/liveupdate.rst - Userspace API documentation
* Documentation/core-api/kho/concepts.rst - KHO concepts
* tools/testing/selftests/liveupdate/ - Test code examples
* include/uapi/linux/liveupdate.h - UAPI header file

Related System Calls
====================

LUO primarily works through the ioctl interface and involves the following
system calls:

* ``open()`` - Open ``/dev/liveupdate`` device
* ``ioctl()`` - Perform various LUO operations
* ``close()`` - Close file descriptors
* ``kexec_file_load()`` - Load new kernel (called by kexec tool)
* ``reboot()`` - Execute kexec reboot (called by kexec tool)

Summary
=======

LUO provides a powerful mechanism for kernel live updates. The main steps are:

1. **Configure kernel**: Enable ``CONFIG_LIVEUPDATE`` and related options
2. **Set command line**: Add ``kho=on liveupdate=on`` parameters
3. **Prepare upgrade**: Create sessions and preserve state via ``/dev/liveupdate``
4. **Load new kernel**: Use ``kexec -l`` to load kernel from ``/boot/vmlinuz`` or similar
5. **Execute switch**: Use ``kexec -e`` to switch to new kernel
6. **Restore state**: Retrieve sessions and restore preserved state in new kernel

This approach enables kernel updates without interrupting critical services, making
it particularly suitable for cloud environments with virtualized hosts and other
high-availability scenarios.
