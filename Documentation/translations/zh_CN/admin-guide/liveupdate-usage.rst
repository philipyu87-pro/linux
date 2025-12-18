.. SPDX-License-Identifier: GPL-2.0

.. include:: ../disclaimer-zh_CN.rst

:Original: Documentation/admin-guide/liveupdate-usage.rst

:翻译:

 司延腾 Yanteng Si <siyanteng@loongson.cn>

:校译:


========================================
内核实时更新（Live Update）使用指南
========================================

:作者: Pasha Tatashin <pasha.tatashin@soleen.com>

什么是 LUO (Live Update Orchestrator)
=======================================

Live Update Orchestrator (LUO) 是一个基于 kexec 的内核实时更新机制，它允许正在运行的
Linux 内核在保持特定资源状态和硬件设备运行的情况下，从一个版本更新到另一个版本。

主要应用场景
------------

* **虚拟化环境**: 在云环境中作为 hypervisor 运行时，可以在不中断虚拟机运行的情况下更新内核
* **内存缓存服务**: 运行如 memcached 等大容量内存缓存服务的系统，可以保持缓存数据
* **高性能数据库**: 数据库服务器可以在内核更新过程中保持内存状态
* **网络服务**: 需要保持连接状态的网络服务

内核配置要求
============

要使用 LUO 功能，需要启用以下内核配置选项::

    CONFIG_KEXEC_HANDOVER=y         # Kexec HandOver 支持
    CONFIG_LIVEUPDATE=y             # Live Update Orchestrator
    CONFIG_KEXEC_FILE=y             # Kexec file loading
    CONFIG_MEMBLOCK_KHO_SCRATCH=y   # KHO scratch 区域支持

可选配置::

    CONFIG_KEXEC_HANDOVER_DEBUG=y   # 启用额外的调试检查
    CONFIG_KEXEC_HANDOVER_DEBUGFS=y # DebugFS 接口
    CONFIG_KEXEC_HANDOVER_ENABLE_DEFAULT=y  # 默认启用 KHO

内核命令行参数配置
==================

为新内核预留内存
----------------

**1. 启用 Kexec HandOver (KHO)**

KHO 是 LUO 的基础机制，用于在内核间传递内存状态::

    kho=on

如果编译时启用了 ``CONFIG_KEXEC_HANDOVER_ENABLE_DEFAULT``，则 KHO 默认开启，
可以通过 ``kho=off`` 关闭。

**2. 启用 Live Update**

在内核命令行中添加::

    liveupdate=on

**3. 配置 Scratch 区域大小（可选）**

Scratch 区域是用于加载新内核和 initrd 的物理连续内存区域。默认情况下，系统会根据
启动时分配的内存量自动计算 scratch 区域的大小。如果需要显式指定，可以使用::

    kho_scratch=<size>

其中 <size> 可以是以字节为单位的数字，或使用 K/M/G 后缀（如 512M, 1G）。

**完整的命令行示例**::

    linux /boot/vmlinuz root=/dev/sda1 kho=on liveupdate=on

或带 scratch 大小指定::

    linux /boot/vmlinuz root=/dev/sda1 kho=on liveupdate=on kho_scratch=1G

内存布局说明
------------

启用 KHO 后，系统会分配以下内存区域：

1. **Scratch 区域**: 用于 kexec 加载新内核的物理连续内存
   
   - 每个 NUMA 节点一个 scratch 区域
   - 一个用于非特定 NUMA 节点分配的 scratch 区域
   - 这些区域在页分配器初始化后声明为 CMA，保证不会有 handover 页面落在该区域

2. **保留区域**: 用于存储序列化的系统状态和需要跨 kexec 保留的内存数据

用户态如何发起热升级
====================

LUO 通过 ``/dev/liveupdate`` 字符设备提供用户态接口。

设备文件
--------

::

    /dev/liveupdate

该设备一次只能被一个进程打开（独占访问）。

基本工作流程
------------

热升级分为以下几个阶段：

**阶段 1：准备阶段（当前内核）**

1. 打开 ``/dev/liveupdate`` 设备
2. 创建会话（Session）
3. 保存需要保留的文件描述符
4. 执行 kexec 加载新内核
5. 触发 kexec 重启

**阶段 2：恢复阶段（新内核）**

1. 新内核启动后，打开 ``/dev/liveupdate`` 设备
2. 检索之前创建的会话
3. 恢复保存的文件描述符
4. 完成会话

详细 API 说明
=============

打开设备
--------

::

    int luo_fd = open("/dev/liveupdate", O_RDWR);
    if (luo_fd < 0) {
        perror("Failed to open /dev/liveupdate");
        exit(1);
    }

创建会话
--------

使用 ``LIVEUPDATE_IOCTL_CREATE_SESSION`` ioctl 创建会话::

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

保存文件描述符
--------------

使用 ``LIVEUPDATE_SESSION_PRESERVE_FD`` ioctl 保存 FD::

    struct liveupdate_session_preserve_fd preserve_args = {
        .size = sizeof(preserve_args),
        .fd = memfd,        // 要保存的文件描述符
        .token = 0x1234,    // 用户定义的唯一标识符
    };
    
    if (ioctl(session_fd, LIVEUPDATE_SESSION_PRESERVE_FD, &preserve_args) < 0) {
        perror("Failed to preserve fd");
        exit(1);
    }

当前支持保存的文件描述符类型：

* memfd（内存文件描述符）
* 其他类型需要驱动支持（如 KVM、VFIO 等）

检索会话（新内核中）
--------------------

在新内核启动后，使用 ``LIVEUPDATE_IOCTL_RETRIEVE_SESSION`` 检索会话::

    struct liveupdate_ioctl_retrieve_session retrieve_args = {
        .size = sizeof(retrieve_args),
    };
    strncpy((char *)retrieve_args.name, "my-session", sizeof(retrieve_args.name) - 1);
    
    if (ioctl(luo_fd, LIVEUPDATE_IOCTL_RETRIEVE_SESSION, &retrieve_args) < 0) {
        perror("Failed to retrieve session");
        exit(1);
    }
    
    int session_fd = retrieve_args.fd;

恢复文件描述符
--------------

使用 ``LIVEUPDATE_SESSION_RETRIEVE_FD`` ioctl 恢复 FD::

    struct liveupdate_session_retrieve_fd restore_args = {
        .size = sizeof(restore_args),
        .token = 0x1234,    // 之前保存时使用的 token
    };
    
    if (ioctl(session_fd, LIVEUPDATE_SESSION_RETRIEVE_FD, &restore_args) < 0) {
        perror("Failed to retrieve fd");
        exit(1);
    }
    
    int restored_fd = restore_args.fd;

完成会话
--------

使用 ``LIVEUPDATE_SESSION_FINISH`` ioctl 完成会话::

    struct liveupdate_session_finish finish_args = {
        .size = sizeof(finish_args),
        .reserved = 0,
    };
    
    if (ioctl(session_fd, LIVEUPDATE_SESSION_FINISH, &finish_args) < 0) {
        perror("Failed to finish session");
        exit(1);
    }

新内核放在哪里
==============

内核镜像位置
------------

新内核镜像应放置在文件系统中可访问的位置，常见的位置包括：

* ``/boot/vmlinuz`` - 默认的内核镜像位置
* ``/boot/bzImage`` - 压缩的内核镜像
* 自定义路径 - 任何可读的文件系统路径

使用 kexec 加载新内核
---------------------

使用 kexec 工具加载新内核::

    # 基本用法
    kexec -l /boot/vmlinuz --reuse-cmdline
    
    # 带 initramfs
    kexec -l /boot/vmlinuz --initrd=/boot/initramfs --reuse-cmdline
    
    # 指定新的命令行参数
    kexec -l /boot/vmlinuz --append="root=/dev/sda1 kho=on liveupdate=on"

**重要参数说明**:

* ``-l`` 或 ``--load``: 加载新内核到内存
* ``-s`` 或 ``--kexec-file-syscall``: 使用 kexec_file_load 系统调用（推荐用于 LUO）
* ``--reuse-cmdline``: 重用当前内核的命令行参数
* ``--append``: 指定新的内核命令行参数
* ``--initrd``: 指定 initramfs 镜像

执行 kexec 重启
---------------

加载新内核后，使用以下命令触发重启::

    kexec -e

或者::

    systemctl kexec

完整示例脚本
============

简单的热升级脚本
----------------

.. code-block:: bash

    #!/bin/bash
    # 简单的内核热升级脚本
    
    set -e
    
    KERNEL="${KERNEL:-/boot/vmlinuz}"
    INITRAMFS="${INITRAMFS:-/boot/initramfs}"
    
    echo "Loading new kernel: $KERNEL"
    
    # 加载新内核
    if [ -f "$INITRAMFS" ]; then
        kexec -l -s --reuse-cmdline "$KERNEL" --initrd="$INITRAMFS"
    else
        kexec -l -s --reuse-cmdline "$KERNEL"
    fi
    
    echo "Kernel loaded successfully"
    echo "Executing kexec..."
    
    # 执行 kexec 重启
    kexec -e

C 程序示例
----------

完整的 C 程序示例::

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
        
        // 打开 /dev/liveupdate
        luo_fd = open("/dev/liveupdate", O_RDWR);
        if (luo_fd < 0) {
            perror("open /dev/liveupdate");
            return 1;
        }
        
        if (argc > 1 && strcmp(argv[1], "restore") == 0) {
            // 恢复阶段（新内核中）
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
            
            // 恢复 memfd
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
            
            // 验证数据
            lseek(memfd, 0, SEEK_SET);
            n = read(memfd, buffer, sizeof(buffer));
            if (n > 0) {
                buffer[n] = '\0';
                printf("Read data: %s\n", buffer);
            }
            
            close(memfd);
            
            // 完成会话
            memset(&finish_args, 0, sizeof(finish_args));
            finish_args.size = sizeof(finish_args);
            
            if (ioctl(session_fd, LIVEUPDATE_SESSION_FINISH, &finish_args) < 0) {
                perror("LIVEUPDATE_SESSION_FINISH");
                return 1;
            }
            
            printf("Session finished successfully\n");
            close(session_fd);
            
        } else {
            // 保存阶段（当前内核）
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
            
            // 创建 memfd 并写入数据
            memfd = memfd_create("test-memfd", 0);
            if (memfd < 0) {
                perror("memfd_create");
                return 1;
            }
            
            write(memfd, TEST_DATA, strlen(TEST_DATA));
            printf("Created memfd=%d with data: %s\n", memfd, TEST_DATA);
            
            // 保存 memfd
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

测试和验证
==========

内核自带测试
------------

Linux 内核源码中包含了完整的 LUO 测试套件::

    cd tools/testing/selftests/liveupdate
    make
    
    # 运行基本测试
    ./liveupdate
    
    # 运行 kexec 测试（需要 root 权限）
    sudo ./luo_kexec_simple

测试脚本
--------

使用内核自带的 kexec 测试脚本::

    cd tools/testing/selftests/liveupdate
    sudo ./do_kexec.sh

该脚本会：

1. 设置环境变量 ``KERNEL`` 和 ``INITRAMFS``（如果未设置则使用默认值）
2. 使用 kexec 加载新内核
3. 执行 kexec 重启

故障排查
========

常见问题
--------

**1. /dev/liveupdate 不存在**

检查内核配置是否启用 ``CONFIG_LIVEUPDATE=y`` 并重新编译内核。

**2. kexec 加载失败**

确保：

- 启用了 ``CONFIG_KEXEC_FILE=y``
- 内核命令行包含 ``kho=on``
- 有足够的内存用于 scratch 区域

**3. 会话检索失败 (ENOENT)**

确保：

- 在旧内核中成功创建了会话
- 会话名称完全匹配
- kexec 成功传递了 KHO 数据

**4. 文件描述符保存失败**

确保：

- FD 类型受支持（如 memfd）
- 相关驱动已加载并支持 LUO
- 没有内存不足

调试方法
--------

**启用调试输出**::

    echo 8 > /proc/sys/kernel/printk
    dmesg -w

**检查 KHO 状态**:

如果启用了 ``CONFIG_KEXEC_HANDOVER_DEBUGFS``::

    mount -t debugfs none /sys/kernel/debug
    cat /sys/kernel/debug/kho/status

**验证内核参数**::

    cat /proc/cmdline | grep -E "kho|liveupdate"

参考资料
========

* Documentation/core-api/liveupdate.rst - LUO 核心 API 文档
* Documentation/userspace-api/liveupdate.rst - 用户态 API 文档
* Documentation/core-api/kho/concepts.rst - KHO 概念说明
* tools/testing/selftests/liveupdate/ - 测试代码示例
* include/uapi/linux/liveupdate.h - UAPI 头文件

相关系统调用
============

LUO 主要通过 ioctl 接口工作，涉及以下系统调用：

* ``open()`` - 打开 ``/dev/liveupdate`` 设备
* ``ioctl()`` - 执行各种 LUO 操作
* ``close()`` - 关闭文件描述符
* ``kexec_file_load()`` - 加载新内核（由 kexec 工具调用）
* ``reboot()`` - 执行 kexec 重启（由 kexec 工具调用）

总结
====

LUO 提供了一个强大的机制来实现内核的热升级，主要步骤如下：

1. **配置内核**: 启用 ``CONFIG_LIVEUPDATE`` 和相关选项
2. **设置命令行**: 添加 ``kho=on liveupdate=on`` 参数
3. **准备升级**: 通过 ``/dev/liveupdate`` 创建会话并保存状态
4. **加载新内核**: 使用 ``kexec -l`` 加载新内核到 ``/boot/vmlinuz`` 等位置
5. **执行切换**: 使用 ``kexec -e`` 切换到新内核
6. **恢复状态**: 在新内核中检索会话并恢复保存的状态

通过这种方式，可以在不中断关键服务的情况下完成内核更新，特别适用于云环境中的
虚拟化主机和其他需要高可用性的场景。
