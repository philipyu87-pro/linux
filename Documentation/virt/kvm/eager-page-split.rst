.. SPDX-License-Identifier: GPL-2.0

===============================================
KVM Eager Page Splitting for Live Migration
===============================================

Overview / 概述
===============

The Linux kernel KVM subsystem supports **Eager Page Splitting**, which allows
splitting of large huge pages (including 1GB pages) down to 4KB pages in advance
before live migration. This feature improves the performance of dirty logging
during VM live migration.

Linux内核的KVM子系统支持**急切页面拆分(Eager Page Splitting)**功能，可以在虚拟机热
迁移之前，提前将大页内存（包括1GB大页）拆分成4KB的小页。此功能可以提高虚拟机热迁移
过程中脏页日志记录的性能。

How It Works / 工作原理
========================

When dirty logging is enabled for live migration, huge pages (2MB and 1GB) need
to be tracked at 4KB granularity. Without eager page splitting, these huge pages
are split lazily on the first write fault, which:

- Causes interruptions to vCPU execution
- Introduces write-protection faults
- Creates MMU lock contention
- Impacts VM performance during migration

在虚拟机热迁移时启用脏页日志记录后，需要以4KB粒度跟踪大页（2MB和1GB）。如果没有急切
页面拆分功能，这些大页会在第一次写入错误时惰性拆分，这会导致：

- 虚拟CPU执行中断
- 写保护错误
- MMU锁争用
- 迁移期间虚拟机性能下降

With eager page splitting enabled (default), KVM proactively splits all huge
pages in the memory slot when dirty logging is enabled, eliminating the runtime
overhead of lazy splitting.

启用急切页面拆分功能（默认启用）后，KVM会在启用脏页日志记录时主动拆分内存槽中的所有
大页，从而消除惰性拆分的运行时开销。

Page Splitting Process / 页面拆分过程
=====================================

The splitting process is recursive and handles multiple levels:

1. **1GB pages** → Split into 512 x 2MB pages
2. **2MB pages** → Split into 512 x 4KB pages

For a 1GB page, the process will:
1. First split 1GB → 512 x 2MB pages
2. Then split each 2MB page → 512 x 4KB pages
3. Result: 1GB page becomes 262,144 x 4KB pages

拆分过程是递归的，可以处理多个级别：

1. **1GB大页** → 拆分为 512 × 2MB 页面
2. **2MB页面** → 拆分为 512 × 4KB 页面

对于1GB大页，处理过程为：
1. 首先将 1GB 拆分为 512 × 2MB 页面
2. 然后将每个 2MB 页面拆分为 512 × 4KB 页面
3. 结果：1GB大页变成 262,144 × 4KB 页面

Architecture Support / 架构支持
===============================

Eager page splitting is supported on:

- **x86-64**: Full support for 2MB and 1GB pages
- **ARM64**: Support with configurable chunk size

急切页面拆分支持以下架构：

- **x86-64**：完全支持2MB和1GB页面
- **ARM64**：支持可配置的块大小

Configuration / 配置
=====================

x86-64 Configuration / x86-64 配置
-----------------------------------

The feature is controlled by the ``kvm.eager_page_split`` kernel parameter.

此功能由 ``kvm.eager_page_split`` 内核参数控制。

**Enable (default) / 启用（默认）**::

    kvm.eager_page_split=Y

**Disable / 禁用**::

    kvm.eager_page_split=N

**Check current setting / 检查当前设置**::

    cat /sys/module/kvm/parameters/eager_page_split

**Enable at runtime / 运行时启用**::

    echo Y > /sys/module/kvm/parameters/eager_page_split

**Disable at runtime / 运行时禁用**::

    echo N > /sys/module/kvm/parameters/eager_page_split

Requirements / 要求
-------------------

For x86-64, eager page splitting requires:

- TDP MMU enabled (``kvm.tdp_mmu=Y``, which is the default)
- Dirty logging enabled on the memory slot

对于x86-64架构，急切页面拆分需要：

- 启用TDP MMU（``kvm.tdp_mmu=Y``，默认启用）
- 在内存槽上启用脏页日志记录

Behavior Modes / 行为模式
==========================

The behavior depends on the ``KVM_DIRTY_LOG_INITIALLY_SET`` flag:

**Mode 1: Without KVM_DIRTY_LOG_INITIALLY_SET**

All huge pages in a memslot are eagerly split when dirty logging is enabled.

**模式1：不使用 KVM_DIRTY_LOG_INITIALLY_SET**

启用脏页日志记录时，内存槽中的所有大页都会被急切拆分。

**Mode 2: With KVM_DIRTY_LOG_INITIALLY_SET**

Eager page splitting is performed during the ``KVM_CLEAR_DIRTY`` ioctl, and only
for the pages being cleared.

**模式2：使用 KVM_DIRTY_LOG_INITIALLY_SET**

急切页面拆分在 ``KVM_CLEAR_DIRTY`` ioctl期间执行，并且仅针对正在清除的页面。

Use Cases / 使用场景
====================

When to Enable (Default) / 何时启用（默认）
--------------------------------------------

Enable eager page splitting (default) for:

- Live migration workloads
- VMs that frequently write to most of their memory
- Scenarios where consistent low-latency is important

适用于以下场景（默认启用）：

- 虚拟机热迁移工作负载
- 频繁写入大部分内存的虚拟机
- 需要一致低延迟的场景

When to Disable / 何时禁用
--------------------------

Consider disabling eager page splitting for:

- VMs that rarely perform writes
- VMs that write only to a small region of memory
- Workloads where read performance from huge pages is critical

考虑在以下场景禁用：

- 很少执行写入操作的虚拟机
- 仅写入小部分内存区域的虚拟机
- 大页读取性能至关重要的工作负载

Testing and Verification / 测试和验证
=====================================

Test Program Location / 测试程序位置
------------------------------------

A comprehensive test program is included::

    tools/testing/selftests/kvm/x86/dirty_log_page_splitting_test.c

包含一个全面的测试程序::

    tools/testing/selftests/kvm/x86/dirty_log_page_splitting_test.c

Building the Test / 构建测试
-----------------------------

To build the test program::

    cd tools/testing/selftests/kvm
    make

构建测试程序::

    cd tools/testing/selftests/kvm
    make

Running the Test / 运行测试
---------------------------

Basic test run::

    ./x86/dirty_log_page_splitting_test

Test with 1GB huge pages::

    ./x86/dirty_log_page_splitting_test -s anonymous_hugetlb_1gb

Test with custom memory size per vCPU::

    ./x86/dirty_log_page_splitting_test -b 2G

基本测试运行::

    ./x86/dirty_log_page_splitting_test

使用1GB大页测试::

    ./x86/dirty_log_page_splitting_test -s anonymous_hugetlb_1gb

使用自定义每个vCPU内存大小测试::

    ./x86/dirty_log_page_splitting_test -b 2G

Verification / 验证
-------------------

The test verifies:

1. All huge pages are properly split during dirty logging
2. Pages are split to 4KB granularity
3. Huge pages are restored after dirty logging is disabled
4. 1GB pages are correctly handled

测试验证：

1. 在脏页日志记录期间正确拆分所有大页
2. 页面拆分到4KB粒度
3. 禁用脏页日志记录后恢复大页
4. 正确处理1GB大页

Monitoring Page Statistics / 监控页面统计信息
==============================================

To check current page sizes in use by a VM::

    # View KVM statistics
    cat /sys/kernel/debug/kvm/<vm_id>/stats

    # Check for:
    # - pages_4k: Number of 4KB pages
    # - pages_2m: Number of 2MB pages
    # - pages_1g: Number of 1GB pages

检查虚拟机当前使用的页面大小::

    # 查看KVM统计信息
    cat /sys/kernel/debug/kvm/<vm_id>/stats

    # 检查：
    # - pages_4k: 4KB页面数量
    # - pages_2m: 2MB页面数量
    # - pages_1g: 1GB页面数量

Performance Considerations / 性能考虑
=====================================

**Benefits / 优点:**

- Reduced vCPU interruptions during migration
- Lower MMU lock contention
- More consistent VM performance
- Faster overall migration completion

**优点:**

- 减少迁移期间vCPU中断
- 降低MMU锁争用
- 更一致的虚拟机性能
- 更快的整体迁移完成时间

**Trade-offs / 权衡:**

- Initial split takes time when enabling dirty logging
- Increased memory consumption for page tables
- Loss of huge page benefits for read operations during migration

**权衡:**

- 启用脏页日志记录时初始拆分需要时间
- 页表的内存消耗增加
- 迁移期间读取操作失去大页优势

Implementation Details / 实现细节
=================================

Code Locations / 代码位置
--------------------------

Key implementation files:

实现的关键文件：

**Core MMU code / 核心MMU代码**::

    arch/x86/kvm/mmu/mmu.c
        - kvm_mmu_slot_try_split_huge_pages()
        - kvm_mmu_try_split_huge_pages()

**TDP MMU code / TDP MMU代码**::

    arch/x86/kvm/mmu/tdp_mmu.c
        - kvm_tdp_mmu_try_split_huge_pages()
        - tdp_mmu_split_huge_pages_root()

**Main KVM code / 主要KVM代码**::

    arch/x86/kvm/x86.c
        - eager_page_split module parameter
        - Dirty logging integration

**ARM64 code / ARM64代码**::

    arch/arm64/kvm/mmu.c
        - ARM64-specific implementation

Algorithm / 算法
----------------

The splitting algorithm uses pre-order traversal of the page table:

1. Traverse the TDP MMU page table
2. Find all large pages (>= target level + 1)
3. For each large page:

   - Allocate a new page table
   - Initialize child entries
   - Split the large page into smaller pages
   - Atomically replace the large page entry

4. Continue recursively until target level (4KB) is reached

拆分算法使用页表的先序遍历：

1. 遍历TDP MMU页表
2. 找到所有大页（>= 目标级别 + 1）
3. 对于每个大页：

   - 分配新的页表
   - 初始化子条目
   - 将大页拆分为较小的页
   - 原子性地替换大页条目

4. 递归继续直到达到目标级别（4KB）

Related Documentation / 相关文档
================================

- :ref:`Documentation/virt/kvm/api.rst <KVM_CAP_MANUAL_DIRTY_LOG_PROTECT2>`
- :ref:`Documentation/admin-guide/kernel-parameters.txt <kvm.eager_page_split>`
- :ref:`Documentation/admin-guide/mm/transhuge.rst <transhuge>`
- :ref:`Documentation/admin-guide/mm/hugetlbpage.rst <hugetlbpage>`

References / 参考
==================

- KVM dirty logging API
- TDP (Two-Dimensional Paging) MMU
- Transparent Huge Pages (THP)
- HugeTLB pages
- Live VM migration

See Also / 另见
================

- ``tools/testing/selftests/kvm/x86/dirty_log_page_splitting_test.c``
- ``tools/testing/selftests/kvm/dirty_log_perf_test.c``
- ``Documentation/virt/kvm/locking.rst``
