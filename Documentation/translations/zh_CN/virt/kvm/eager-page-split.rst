.. SPDX-License-Identifier: GPL-2.0

.. include:: ../../../../disclaimer-zh_CN.rst

:Original: Documentation/virt/kvm/eager-page-split.rst

:Translator: Copilot SWE Agent

===============================================
KVM 急切页面拆分用于虚拟机热迁移
===============================================

回答问题：内核有这样一个功能吗？虚拟机的大页内存1G，在热迁移前可以提前拆成4k的小页
========================================================================

**答案：是的，内核已经有这个功能！**

Linux内核的KVM子系统支持 **急切页面拆分(Eager Page Splitting)** 功能，可以在虚拟机
热迁移之前，提前将大页内存（包括1GB大页）拆分成4KB的小页。此功能默认启用。

概述
====

急切页面拆分功能可以提高虚拟机热迁移过程中脏页日志记录的性能。它允许在启用脏页日志
记录时，主动将1GB和2MB大页拆分为4KB小页，而不是在第一次写入时才惰性拆分。

工作原理
========

当为虚拟机热迁移启用脏页日志记录时，需要以4KB粒度跟踪大页（2MB和1GB）。如果没有急切
页面拆分功能，这些大页会在第一次写入错误时惰性拆分，这会导致：

- 虚拟CPU执行中断
- 写保护错误
- MMU锁争用
- 迁移期间虚拟机性能下降

启用急切页面拆分功能（默认启用）后，KVM会在启用脏页日志记录时主动拆分内存槽中的所有
大页，从而消除惰性拆分的运行时开销。

页面拆分过程
============

拆分过程是递归的，可以处理多个级别：

1. **1GB大页** → 拆分为 512 × 2MB 页面
2. **2MB页面** → 拆分为 512 × 4KB 页面

对于1GB大页，完整处理过程为：

1. 首先将 1GB 拆分为 512 × 2MB 页面
2. 然后将每个 2MB 页面拆分为 512 × 4KB 页面
3. 结果：1GB大页变成 262,144 × 4KB 页面

架构支持
========

急切页面拆分支持以下架构：

- **x86-64**：完全支持2MB和1GB页面
- **ARM64**：支持可配置的块大小

配置方法
========

x86-64 配置
-----------

此功能由 ``kvm.eager_page_split`` 内核参数控制。

**检查当前设置（默认应该是Y）**::

    cat /sys/module/kvm/parameters/eager_page_split

**启用（默认已启用）**::

    echo Y > /sys/module/kvm/parameters/eager_page_split

或在内核启动参数中添加::

    kvm.eager_page_split=Y

**禁用（通常不需要）**::

    echo N > /sys/module/kvm/parameters/eager_page_split

要求
----

对于x86-64架构，急切页面拆分需要：

- 启用TDP MMU（``kvm.tdp_mmu=Y``，默认启用）
- 在内存槽上启用脏页日志记录

快速验证
========

使用提供的示例脚本
------------------

查看当前配置::

    # 以root身份运行
    sudo bash Documentation/virt/kvm/eager-page-split-example.sh status

这将显示：

- 急切页面拆分是否启用
- TDP MMU是否启用
- CPU是否支持1GB大页
- 当前可用的大页大小

行为模式
========

行为取决于 ``KVM_DIRTY_LOG_INITIALLY_SET`` 标志：

**模式1：不使用 KVM_DIRTY_LOG_INITIALLY_SET（默认）**

启用脏页日志记录时，内存槽中的所有大页（包括1GB和2MB）都会被急切拆分为4KB页面。

**模式2：使用 KVM_DIRTY_LOG_INITIALLY_SET**

急切页面拆分在 ``KVM_CLEAR_DIRTY`` ioctl期间执行，并且仅针对正在清除的页面。

使用场景
========

何时启用（默认）
----------------

适用于以下场景（默认已启用）：

- **虚拟机热迁移工作负载**（主要场景）
- 频繁写入大部分内存的虚拟机
- 需要一致低延迟的场景

何时禁用
--------

考虑在以下场景禁用：

- 很少执行写入操作的虚拟机
- 仅写入小部分内存区域的虚拟机
- 大页读取性能至关重要的工作负载
- 不需要进行虚拟机热迁移的场景

测试和验证
==========

内核自带测试程序
----------------

Linux内核包含一个完整的测试程序来验证此功能::

    tools/testing/selftests/kvm/x86/dirty_log_page_splitting_test.c

构建和运行测试::

    cd tools/testing/selftests/kvm
    make
    sudo ./x86/dirty_log_page_splitting_test

使用1GB大页测试::

    sudo ./x86/dirty_log_page_splitting_test -s anonymous_hugetlb_1gb

测试会验证：

1. 在脏页日志记录期间正确拆分所有大页
2. 1GB页面正确拆分为4KB页面
3. 禁用脏页日志记录后恢复大页
4. 页面拆分到4KB粒度

监控页面统计信息
================

检查虚拟机当前使用的页面大小::

    # 查看KVM统计信息
    cat /sys/kernel/debug/kvm/<vm_id>/stats

查找以下指标：

- ``pages_4k``: 4KB页面数量
- ``pages_2m``: 2MB页面数量  
- ``pages_1g``: 1GB页面数量

在启用脏页日志记录后，您应该看到 ``pages_1g`` 和 ``pages_2m`` 变为0，
``pages_4k`` 增加。

手动配置1GB大页
===============

如果要为虚拟机配置1GB大页::

    # 1. 检查CPU是否支持1GB大页
    grep pdpe1gb /proc/cpuinfo
    
    # 2. 分配1GB大页
    echo 10 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
    
    # 3. 挂载hugetlbfs
    mkdir -p /mnt/hugepages_1GB
    mount -t hugetlbfs -o pagesize=1G none /mnt/hugepages_1GB
    
    # 4. 启动QEMU/KVM虚拟机时使用大页
    qemu-system-x86_64 \
        -m 4G \
        -mem-path /mnt/hugepages_1GB \
        -mem-prealloc \
        ...

性能考虑
========

优点
----

- **减少迁移期间vCPU中断**：避免在写入时触发页面拆分
- **降低MMU锁争用**：提前完成拆分，减少运行时锁竞争
- **更一致的虚拟机性能**：消除惰性拆分带来的性能抖动
- **更快的整体迁移完成时间**：减少迁移过程中的延迟

权衡
----

- 启用脏页日志记录时初始拆分需要时间（一次性开销）
- 页表的内存消耗略有增加
- 迁移期间读取操作失去大页优势（但写入优化更重要）

实现细节
========

代码位置
--------

关键实现文件：

**核心MMU代码**::

    arch/x86/kvm/mmu/mmu.c
        - kvm_mmu_slot_try_split_huge_pages()
        - kvm_mmu_try_split_huge_pages()

**TDP MMU代码**::

    arch/x86/kvm/mmu/tdp_mmu.c
        - kvm_tdp_mmu_try_split_huge_pages()
        - tdp_mmu_split_huge_pages_root()

**主要KVM代码**::

    arch/x86/kvm/x86.c
        - eager_page_split 模块参数（第186-187行）
        - 脏页日志记录集成（第13572-13573行）

算法
----

拆分算法使用页表的先序遍历：

1. 遍历TDP MMU页表
2. 找到所有大页（>= 目标级别 + 1）
3. 对于每个大页：

   - 分配新的页表
   - 初始化子条目
   - 将大页拆分为较小的页
   - 原子性地替换大页条目

4. 递归继续直到达到目标级别（4KB）

对于1GB页面，这个过程会：

- 第一轮：将1GB页面拆分为512个2MB页面
- 第二轮：将每个2MB页面拆分为512个4KB页面
- 总计：1个1GB页面变成262,144个4KB页面

常见问题
========

Q1: 这个功能是默认启用的吗？
-----------------------------

A: **是的**，在x86-64上默认启用（``kvm.eager_page_split=Y``）。这对大多数虚拟机热迁移
场景是最佳设置。您无需额外配置即可使用。

Q2: 是否支持1GB大页拆分？
--------------------------

A: **是的，完全支持**。拆分过程会递归处理1GB页面：

- 步骤1：1GB → 512 × 2MB
- 步骤2：每个2MB → 512 × 4KB
- 结果：1GB → 262,144 × 4KB

Q3: 如何验证功能是否正常工作？
------------------------------

A: 有多种方式验证：

**方式1：检查参数**::

    cat /sys/module/kvm/parameters/eager_page_split
    # 应该输出: Y

**方式2：运行测试程序**::

    cd tools/testing/selftests/kvm
    make
    sudo ./x86/dirty_log_page_splitting_test -s anonymous_hugetlb_1gb

**方式3：使用示例脚本**::

    sudo bash Documentation/virt/kvm/eager-page-split-example.sh status

Q4: 这个功能何时生效？
-----------------------

A: 急切页面拆分在以下时机生效：

- 当为内存槽启用脏页日志记录时（用于虚拟机热迁移）
- 在调用 ``KVM_CLEAR_DIRTY`` ioctl时（如果使用了KVM_DIRTY_LOG_INITIALLY_SET）

不需要任何额外的手动操作，虚拟化管理软件（如libvirt/QEMU）会自动使用。

Q5: 对性能有什么影响？
----------------------

A: 总体上提高了热迁移性能：

**优点**：

- 迁移期间更低的延迟和更一致的性能
- 减少vCPU中断和停顿
- 更快的整体迁移时间

**开销**：

- 启用脏页日志时有一次性拆分开销
- 稍微增加内存消耗（页表结构）

对于热迁移场景，优点远大于开销。

Q6: 什么时候应该禁用此功能？
----------------------------

A: 大多数情况下不需要禁用。只在以下特殊场景考虑禁用：

- 虚拟机从不进行热迁移
- 工作负载主要是读取操作，很少写入
- 大页读取性能至关重要（如高性能计算）

Q7: 如何在QEMU中使用1GB大页？
------------------------------

A: 启动QEMU时使用以下参数::

    qemu-system-x86_64 \
        -m 8G \
        -object memory-backend-file,id=mem,size=8G,mem-path=/mnt/hugepages_1GB,share=on,prealloc=on \
        -numa node,memdev=mem \
        ...

确保已经分配并挂载了1GB大页。

总结
====

**Linux内核已经具备了您所询问的功能！**

KVM的急切页面拆分功能可以：

- ✓ 支持1GB大页
- ✓ 在热迁移前提前拆分为4KB小页
- ✓ 默认启用，无需额外配置
- ✓ 提高热迁移性能
- ✓ 包含完整的测试套件

您只需确保：

1. 使用的内核版本支持此功能（较新的内核版本）
2. ``kvm.eager_page_split=Y``（默认值）
3. ``kvm.tdp_mmu=Y``（默认值）

参考资料
========

- ``Documentation/virt/kvm/api.rst`` - KVM API文档
- ``Documentation/admin-guide/kernel-parameters.txt`` - 内核参数说明
- ``Documentation/admin-guide/mm/hugetlbpage.rst`` - 大页配置
- ``tools/testing/selftests/kvm/x86/dirty_log_page_splitting_test.c`` - 测试代码

相关命令参考
============

查看配置::

    # 检查急切页面拆分状态
    cat /sys/module/kvm/parameters/eager_page_split
    
    # 检查TDP MMU状态
    cat /sys/module/kvm/parameters/tdp_mmu
    
    # 检查CPU是否支持1GB大页
    grep pdpe1gb /proc/cpuinfo
    
    # 查看可用大页大小
    ls /sys/kernel/mm/hugepages/

管理1GB大页::

    # 分配1GB大页（分配10个）
    echo 10 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
    
    # 查看已分配的1GB大页数量
    cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
    
    # 查看空闲的1GB大页数量
    cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages

使用示例脚本::

    # 查看完整状态报告
    sudo bash Documentation/virt/kvm/eager-page-split-example.sh status
    
    # 启用急切页面拆分
    sudo bash Documentation/virt/kvm/eager-page-split-example.sh enable
    
    # 禁用急切页面拆分
    sudo bash Documentation/virt/kvm/eager-page-split-example.sh disable
    
    # 运行测试
    sudo bash Documentation/virt/kvm/eager-page-split-example.sh test
