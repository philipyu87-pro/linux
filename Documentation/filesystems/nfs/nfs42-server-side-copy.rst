.. SPDX-License-Identifier: GPL-2.0

=====================================
NFSv4.2 Server-Side Copy Operations
=====================================

This document describes how to configure and test NFSv4.2 server-side copy
(SSC) operations, particularly the asynchronous copy feature that triggers
the ``nfsd4_cb_offload_release`` callback function.

Overview
========

NFSv4.2 (RFC 7862) introduces server-side copy operations that allow data
to be copied between files on the server without transferring data through
the client. This includes:

- **Intra-server copy**: Copy data between files on the same NFS server
- **Inter-server copy**: Copy data between files on different NFS servers

The server-side copy operation can be either:

- **Synchronous**: The COPY operation completes immediately and returns
  the result
- **Asynchronous**: The COPY operation returns immediately with a stateid,
  and the server notifies the client via CB_OFFLOAD callback when complete

The ``nfsd4_cb_offload_release`` function is called when an asynchronous
copy operation completes and the CB_OFFLOAD callback has been sent to
the client.

Prerequisites
=============

Kernel Configuration
--------------------

Ensure the following kernel configuration options are enabled::

    CONFIG_NFS_V4_2=y
    CONFIG_NFSD_V4=y

You can verify these settings::

    grep -E "CONFIG_NFS_V4_2|CONFIG_NFSD_V4" /boot/config-$(uname -r)

Required Packages
-----------------

Install the necessary NFS utilities::

    # For Debian/Ubuntu
    apt-get install nfs-kernel-server nfs-common

    # For RHEL/CentOS/Fedora
    dnf install nfs-utils

Configuring the NFS Server
==========================

Step 1: Create Export Directory
-------------------------------

Create a directory to export and set appropriate permissions::

    mkdir -p /export/data
    chown nobody:nogroup /export/data
    chmod 755 /export/data

Step 2: Configure Exports
-------------------------

Edit ``/etc/exports`` to add the export with NFSv4.2 support::

    /export/data *(rw,sync,no_subtree_check)

.. note::
   For testing purposes only, you may add ``no_root_squash`` to allow
   root access, but this creates a security risk in production environments.

Step 3: Enable NFSv4.2
----------------------

Ensure NFSv4.2 is enabled. Check ``/etc/nfs.conf`` or create it::

    [nfsd]
    vers4.2=y

Alternatively, you can configure the NFS server to support version 4.2
by editing ``/etc/default/nfs-kernel-server`` (on Debian-based systems)::

    RPCNFSDARGS="--nfs-version 4.2"

Step 4: Start the NFS Server
----------------------------

Start and enable the NFS server::

    systemctl start nfs-server
    systemctl enable nfs-server

Step 5: Verify Server Configuration
-----------------------------------

Verify that NFSv4.2 is enabled::

    cat /proc/fs/nfsd/versions

The output should include ``+4.2`` indicating NFSv4.2 is enabled.

Export the filesystem::

    exportfs -ra
    exportfs -v

Mounting the NFS Client
=======================

Step 1: Mount with NFSv4.2
--------------------------

Mount the NFS export on the client with NFSv4.2::

    mkdir -p /mnt/nfs
    mount -t nfs -o vers=4.2 <server-ip>:/export/data /mnt/nfs

Replace ``<server-ip>`` with your NFS server's IP address or hostname.

Step 2: Verify Mount Options
----------------------------

Verify that NFSv4.2 is being used::

    mount | grep nfs
    nfsstat -m

The output should show ``vers=4.2``.

Triggering Asynchronous Copy Operations
=======================================

The ``copy_file_range()`` system call is used to trigger server-side copy
operations. To trigger an **asynchronous** copy operation that calls
``nfsd4_cb_offload_release``, the copy must be large enough that the
server decides to perform it asynchronously.

Method 1: Using copy_file_range() System Call
---------------------------------------------

Create a C program to trigger the copy::

    #define _GNU_SOURCE
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>

    int main(int argc, char *argv[])
    {
        int fd_in, fd_out;
        off64_t off_in = 0, off_out = 0;
        ssize_t len, ret;

        if (argc != 4) {
            fprintf(stderr, "Usage: %s <source> <dest> <length>\n", argv[0]);
            exit(EXIT_FAILURE);
        }

        fd_in = open(argv[1], O_RDONLY);
        if (fd_in < 0) {
            perror("open source");
            exit(EXIT_FAILURE);
        }

        fd_out = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd_out < 0) {
            perror("open dest");
            exit(EXIT_FAILURE);
        }

        len = atoll(argv[3]);

        ret = copy_file_range(fd_in, &off_in, fd_out, &off_out, len, 0);
        if (ret < 0) {
            perror("copy_file_range");
            exit(EXIT_FAILURE);
        }

        printf("Copied %zd bytes\n", ret);

        close(fd_in);
        close(fd_out);
        return 0;
    }

Compile and run::

    gcc -o copy_test copy_test.c
    # Create a large test file (e.g., 1GB) using fallocate for speed
    fallocate -l 1G /mnt/nfs/source_file
    # Alternatively, use dd (slower): dd if=/dev/zero of=/mnt/nfs/source_file bs=1M count=1024
    # Perform the copy
    ./copy_test /mnt/nfs/source_file /mnt/nfs/dest_file 1073741824

Method 2: Using cp with Reflink Support
---------------------------------------

Some versions of ``cp`` support server-side copy via reflink::

    # Create a large test file using fallocate
    fallocate -l 1G /mnt/nfs/source_file

    # Copy using reflink (falls back to copy_file_range)
    cp --reflink=auto /mnt/nfs/source_file /mnt/nfs/dest_file

Ensuring Asynchronous Copy Triggers nfsd4_cb_offload_release
============================================================

For an asynchronous copy to occur and trigger ``nfsd4_cb_offload_release``,
the following conditions must be met:

1. **Large Copy Size**: The decision for sync vs async is made on the
   **client side**. The Linux NFS client uses this logic in
   ``fs/nfs/nfs4file.c``::

       /* if the copy size if smaller than 2 RPC payloads, make it
        * synchronous
        */
       if (count <= 2 * NFS_SERVER(file_inode(file_in))->rsize)
           sync = true;

   This means **async copy is triggered when**: ``count > 2 * rsize``

   The ``rsize`` (read size) is negotiated during NFS mount and depends on
   server capabilities. You can check the current value with::

       cat /proc/mounts | grep nfs
       # or
       nfsstat -m

   **Typical thresholds for async copy**:

   - Default rsize (4KB): Files > 8KB trigger async
   - Typical rsize (512KB): Files > 1MB trigger async
   - Maximum rsize (1MB): Files > 2MB trigger async

   Most modern NFS servers negotiate rsize around 512KB-1MB, so files
   larger than approximately **1MB** will typically trigger async copy.

2. **Client Requests Async Mode**: The NFSv4.2 COPY operation includes
   a ``ca_synchronous`` flag. The client sets this based on the size
   check above, and the server respects the client's preference.

3. **Server Thread Capacity**: The server may limit the number of pending
   async copies based on the number of NFS threads.

Tracing and Verification
------------------------

Enable kernel tracing to verify the async copy flow::

    # Enable tracepoints
    echo 1 > /sys/kernel/debug/tracing/events/nfsd/nfsd_copy_async/enable
    echo 1 > /sys/kernel/debug/tracing/events/nfsd/nfsd_copy_done/enable
    echo 1 > /sys/kernel/debug/tracing/events/nfsd/nfsd_cb_offload/enable

    # Clear trace buffer
    echo > /sys/kernel/debug/tracing/trace

    # Perform the copy operation
    ./copy_test /mnt/nfs/source_file /mnt/nfs/dest_file 1073741824

    # View trace output
    cat /sys/kernel/debug/tracing/trace

The trace should show:

- ``nfsd_copy_async``: Indicates an async copy was started
- ``nfsd_copy_done``: Indicates the copy operation completed
- ``nfsd_cb_offload``: Indicates the CB_OFFLOAD callback was sent

Using Dynamic Debug
-------------------

You can also enable dynamic debug messages for more detailed output::

    echo 'module nfsd +p' > /sys/kernel/debug/dynamic_debug/control
    dmesg -w

Code Flow for Asynchronous Copy
===============================

When an asynchronous copy is triggered, the following code path is executed
on the NFS server:

1. ``nfsd4_copy()`` - Entry point for COPY operation
2. ``nfsd4_do_async_copy()`` - Kthread function for background copy
3. ``nfsd4_send_cb_offload()`` - Sends CB_OFFLOAD callback to client
4. ``nfsd4_cb_offload_done()`` - Callback completion handler
5. ``nfsd4_cb_offload_release()`` - Releases callback resources

The ``nfsd4_cb_offload_release()`` function is registered in the
``nfsd4_cb_offload_ops`` structure::

    static const struct nfsd4_callback_ops nfsd4_cb_offload_ops = {
        .release = nfsd4_cb_offload_release,
        .done = nfsd4_cb_offload_done,
        .opcode = OP_CB_OFFLOAD,
    };

This function is called after the CB_OFFLOAD callback has been sent and
acknowledged by the client, or after retry attempts have been exhausted.

Troubleshooting
===============

Copy Falls Back to Read/Write
-----------------------------

If ``copy_file_range()`` falls back to normal read/write operations,
check:

1. Verify NFSv4.2 is enabled on both client and server
2. Ensure both source and destination files are on the same NFS mount
3. Check that the underlying filesystem supports ``copy_file_range()``

No Async Copy Triggered
-----------------------

If copies are always synchronous:

1. Try larger file sizes (multiple GB)
2. Check the number of pending async copies vs NFS threads::

       cat /proc/fs/nfsd/threads

   The server limits async copies based on thread count.

Callback Failures
-----------------

If CB_OFFLOAD callbacks fail:

1. Ensure the client's callback service is reachable from the server
2. Check firewall rules allow callback traffic
3. Verify the client's callback port is accessible

References
==========

- RFC 7862: Network File System (NFS) Version 4 Minor Version 2 Protocol
- ``fs/nfsd/nfs4proc.c`` - Server-side COPY implementation
- ``fs/nfs/nfs42proc.c`` - Client-side COPY implementation
