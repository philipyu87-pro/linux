.. SPDX-License-Identifier: GPL-2.0

.. include:: ../disclaimer-zh_CN.rst

:Original: Documentation/admin-guide/liveupdate-quickstart.rst

:翻译:

 司延腾 Yanteng Si <siyanteng@loongson.cn>

:校译:


==========================================
内核实时更新（Live Update）快速入门
==========================================

:作者: Pasha Tatashin <pasha.tatashin@soleen.com>

这是 Live Update Orchestrator (LUO) 的快速参考指南。
详细信息请参阅 :doc:`liveupdate-usage`。

前提条件
========

1. 编译内核时启用::

    CONFIG_KEXEC_HANDOVER=y
    CONFIG_LIVEUPDATE=y
    CONFIG_KEXEC_FILE=y

2. 内核命令行包含::

    kho=on liveupdate=on

3. 安装发行版的 kexec-tools 软件包

快速工作流程
============

阶段 1：重启前（当前内核）
--------------------------

**1. 编写保存代码**::

    int luo_fd = open("/dev/liveupdate", O_RDWR);
    
    // 创建会话
    struct liveupdate_ioctl_create_session create_args = {
        .size = sizeof(create_args),
    };
    strncpy((char *)create_args.name, "my-session", sizeof(create_args.name) - 1);
    ioctl(luo_fd, LIVEUPDATE_IOCTL_CREATE_SESSION, &create_args);
    int session_fd = create_args.fd;
    
    // 保存文件描述符
    struct liveupdate_session_preserve_fd preserve_args = {
        .size = sizeof(preserve_args),
        .fd = your_memfd,
        .token = 0x1234,
    };
    ioctl(session_fd, LIVEUPDATE_SESSION_PRESERVE_FD, &preserve_args);
    
    close(session_fd);
    close(luo_fd);

**2. 加载新内核**::

    sudo kexec -l -s --reuse-cmdline /boot/vmlinuz

**3. 触发重启**::

    sudo kexec -e

阶段 2：重启后（新内核）
------------------------

**1. 编写恢复代码**::

    int luo_fd = open("/dev/liveupdate", O_RDWR);
    
    // 检索会话
    struct liveupdate_ioctl_retrieve_session retrieve_args = {
        .size = sizeof(retrieve_args),
    };
    strncpy((char *)retrieve_args.name, "my-session", sizeof(retrieve_args.name) - 1);
    ioctl(luo_fd, LIVEUPDATE_IOCTL_RETRIEVE_SESSION, &retrieve_args);
    int session_fd = retrieve_args.fd;
    
    // 恢复文件描述符
    struct liveupdate_session_retrieve_fd restore_args = {
        .size = sizeof(restore_args),
        .token = 0x1234,
    };
    ioctl(session_fd, LIVEUPDATE_SESSION_RETRIEVE_FD, &restore_args);
    int restored_fd = restore_args.fd;
    
    // 使用恢复的文件描述符
    // ...
    
    // 完成会话
    struct liveupdate_session_finish finish_args = {
        .size = sizeof(finish_args),
    };
    ioctl(session_fd, LIVEUPDATE_SESSION_FINISH, &finish_args);
    
    close(session_fd);
    close(luo_fd);

命令行参考
==========

**启动时启用 LUO**::

    kho=on liveupdate=on

**可选：设置 scratch 大小**::

    kho_scratch=1G

**加载新内核**::

    kexec -l -s --reuse-cmdline /boot/vmlinuz [--initrd=/boot/initramfs]

**执行 kexec**::

    kexec -e

**检查 LUO 是否启用**::

    cat /proc/cmdline | grep liveupdate
    ls -l /dev/liveupdate

IOCTL 快速参考
==============

主设备 (/dev/liveupdate)
-------------------------

* ``LIVEUPDATE_IOCTL_CREATE_SESSION`` - 创建新会话
* ``LIVEUPDATE_IOCTL_RETRIEVE_SESSION`` - 检索保存的会话

会话文件描述符
--------------

* ``LIVEUPDATE_SESSION_PRESERVE_FD`` - 保存文件描述符
* ``LIVEUPDATE_SESSION_RETRIEVE_FD`` - 恢复文件描述符
* ``LIVEUPDATE_SESSION_FINISH`` - 完成会话恢复

需要包含的头文件
================

::

    #include <linux/liveupdate.h>
    #include <sys/ioctl.h>
    #include <fcntl.h>

测试
====

**运行内核自测**::

    cd tools/testing/selftests/liveupdate
    make
    sudo ./liveupdate
    sudo ./luo_kexec_simple

**使用测试脚本**::

    cd tools/testing/selftests/liveupdate
    sudo ./do_kexec.sh

常见错误
========

1. **在 kexec 前忘记关闭 session_fd** - 不是关键问题但建议关闭
2. **使用不同的会话名称** - 名称必须完全匹配
3. **不调用 FINISH** - 会话资源不会被释放
4. **对不同 FD 使用相同 token** - 每个会话中 token 必须唯一

故障排查
========

**问题**: /dev/liveupdate 不存在

**解决**: 检查 CONFIG_LIVEUPDATE=y 并重新编译内核

----

**问题**: kexec 加载失败

**解决**: 确保 cmdline 中有 kho=on 且 CONFIG_KEXEC_FILE=y

----

**问题**: 内核签名验证失败 (-129)

**解决**: 对内核镜像签名或禁用 CONFIG_KEXEC_SIG_FORCE 重新编译

----

**问题**: 找不到会话 (ENOENT)

**解决**: 验证会话已创建且 kexec 成功完成

----

**问题**: 启用内核调试输出

**解决**::

    echo 8 > /proc/sys/kernel/printk
    dmesg -w

另见
====

* :doc:`liveupdate-usage` - 完整的 LUO 使用指南
* Documentation/core-api/liveupdate.rst - 核心 API 文档
* Documentation/userspace-api/liveupdate.rst - 用户态 API 参考
* Documentation/core-api/kho/concepts.rst - KHO 概念
