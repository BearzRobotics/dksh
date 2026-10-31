//! Garbage-collected allocator.
//!
//! SPEC 5.3 describes reference counting. dksh uses a conservative
//! mark-and-sweep collector instead, behind the ordinary `std.mem.Allocator`
//! interface, so the rest of the code never retains or releases anything. It
//! reclaims reference cycles too, which the spec lists as post-v1.
//!
//! Design:
//! - One large `mmap` reservation carved into 64 KiB pages.
//! - Small objects (<= 32 KiB) live in pages of one size class each; larger
//!   objects take whole page runs.
//! - Roots are the machine stack, callee-saved registers and the writable
//!   data segments. Any aligned word that points into a live object keeps it
//!   alive (interior pointers count).
//! - Every allocation gets one spare byte, so a one-past-the-end pointer left
//!   in a register by the optimizer still points inside its object.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Alignment = std.mem.Alignment;

const page_shift = 16;
const page_size: usize = 1 << page_shift;
const max_small: usize = 32768;
const bits_words = page_size / 16 / 64; // one bit per 16-byte slot

const class_sizes = [_]u32{
    16,   32,   48,   64,   80,   96,   112,  128,   160,   192,   224,   256,   320,   384,
    448,  512,  640,  768,  896,  1024, 1280, 1536,  1792,  2048,  2560,  3072,  4096,  5120,
    6144, 8192, 10240, 12288, 16384, 32768,
};

const Kind = enum(u8) { free, small, large_head, large_cont };

// ---- heap state (all of it lives in .bss, which is itself scanned harmlessly)
var inited = false;
var heap_base: usize = 0;
var heap_pages: usize = 0;
var next_page: usize = 0; // high-water mark in pages
var kinds: [*]Kind = undefined;
var classes: [*]u8 = undefined;
var run_len: [*]u32 = undefined; // large_head: pages; large_cont: distance back to head
var alloc_bits: [*][bits_words]u64 = undefined;
var mark_bits: [*][bits_words]u64 = undefined;
var free_heads: [class_sizes.len]usize = @splat(0);
var free_hint: usize = 0;

var bytes_since_gc: usize = 0;
var threshold: usize = 48 * 1024 * 1024;
var live_bytes: usize = 0;
var collecting = false;

/// Address just above the main thread's frame; set by `init`.
var stack_top: usize = 0;

/// Collect every `stress` allocations (0 = normal). For testing the roots.
pub var stress: usize = 0;
var stress_count: usize = 0;

pub var collections: usize = 0;

// ---- mark stack (separate mmap region, not managed by the collector)
var mstack: [*]usize = undefined;
var mstack_cap: usize = 0;
var mstack_len: usize = 0;

fn mmapRaw(len: usize) ?[*]u8 {
    const rc = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @ptrFromInt(rc);
}

/// Record the stack origin. Call once at the top of `main`.
pub fn init(top_of_stack: usize) void {
    stack_top = top_of_stack;
}

fn setup() void {
    var reserve: usize = 16 << 30;
    while (reserve >= (256 << 20)) : (reserve /= 2) {
        if (mmapRaw(reserve)) |p| {
            // Align the base to a page boundary.
            const addr = @intFromPtr(p);
            heap_base = std.mem.alignForward(usize, addr, page_size);
            heap_pages = (reserve - (heap_base - addr)) / page_size;
            break;
        }
    }
    if (heap_pages == 0) @panic("out of memory: cannot reserve heap");
    kinds = @ptrCast(mmapRaw(heap_pages) orelse @panic("out of memory"));
    classes = @ptrCast(mmapRaw(heap_pages) orelse @panic("out of memory"));
    run_len = @ptrCast(@alignCast(mmapRaw(heap_pages * 4) orelse @panic("out of memory")));
    alloc_bits = @ptrCast(@alignCast(mmapRaw(heap_pages * @sizeOf([bits_words]u64)) orelse @panic("out of memory")));
    mark_bits = @ptrCast(@alignCast(mmapRaw(heap_pages * @sizeOf([bits_words]u64)) orelse @panic("out of memory")));
    mstack_cap = 1 << 16;
    mstack = @ptrCast(@alignCast(mmapRaw(mstack_cap * @sizeOf(usize)) orelse @panic("out of memory")));
    inited = true;
}

fn classFor(size: usize) usize {
    for (class_sizes, 0..) |c, i| if (size <= c) return i;
    unreachable;
}

fn pageAddr(page: usize) usize {
    return heap_base + (page << page_shift);
}

fn bitGet(bits: *const [bits_words]u64, i: usize) bool {
    return (bits[i >> 6] >> @intCast(i & 63)) & 1 != 0;
}

fn bitSet(bits: *[bits_words]u64, i: usize) void {
    bits[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
}

fn bitClear(bits: *[bits_words]u64, i: usize) void {
    bits[i >> 6] &= ~(@as(u64, 1) << @intCast(i & 63));
}

fn findPages(n: usize) ?usize {
    // First fit among freed pages, then bump. `free_hint` skips the prefix
    // already known to hold no free page, so repeated single-page requests
    // stay cheap.
    var run: usize = 0;
    var p = free_hint;
    while (p < next_page) : (p += 1) {
        if (kinds[p] == .free) {
            run += 1;
            if (run == n) {
                if (n == 1) free_hint = p + 1;
                return p + 1 - n;
            }
        } else run = 0;
    }
    if (n == 1) free_hint = next_page;
    // Trailing free pages can be extended into the bump region.
    var start = next_page;
    while (start > 0 and kinds[start - 1] == .free) start -= 1;
    if (start + n > heap_pages) return null;
    return start;
}

fn takePages(n: usize) ?usize {
    const start = findPages(n) orelse return null;
    if (start + n > next_page) next_page = start + n;
    return start;
}

fn newSmallPage(cls: usize) bool {
    const page = takePages(1) orelse return false;
    kinds[page] = .small;
    classes[page] = @intCast(cls);
    alloc_bits[page] = @splat(0);
    const size = class_sizes[cls];
    const n = page_size / size;
    // Thread the new objects onto the class free list, lowest address first.
    var i = n;
    while (i > 0) {
        i -= 1;
        const addr = pageAddr(page) + i * size;
        @as(*usize, @ptrFromInt(addr)).* = free_heads[cls];
        free_heads[cls] = addr;
    }
    return true;
}

fn maybeCollect() void {
    if (collecting) return;
    if (stress != 0) {
        stress_count += 1;
        if (stress_count >= stress) {
            stress_count = 0;
            collect();
        }
        return;
    }
    if (bytes_since_gc >= threshold) collect();
}

fn allocImpl(len: usize, alignment: Alignment) ?[*]u8 {
    if (!inited) setup();
    var size = len + 1; // spare byte: see the module comment
    const align_bytes = alignment.toByteUnits();
    if (align_bytes > 16) size = @max(size, align_bytes);
    maybeCollect();
    if (size <= max_small) {
        if (align_bytes > 16) size = std.math.ceilPowerOfTwo(usize, size) catch return null;
        const cls = classFor(size);
        if (free_heads[cls] == 0 and !newSmallPage(cls)) {
            collect();
            if (free_heads[cls] == 0 and !newSmallPage(cls)) return null;
        }
        const addr = free_heads[cls];
        free_heads[cls] = @as(*usize, @ptrFromInt(addr)).*;
        const csize = class_sizes[cls];
        const page = (addr - heap_base) >> page_shift;
        const slot = (addr - pageAddr(page)) / csize;
        bitSet(&alloc_bits[page], slot);
        @memset(@as([*]u8, @ptrFromInt(addr))[0..csize], 0);
        bytes_since_gc += csize;
        return @ptrFromInt(addr);
    }
    const n = (size + page_size - 1) >> page_shift;
    var start = takePages(n);
    if (start == null) {
        collect();
        start = takePages(n);
    }
    const s = start orelse return null;
    kinds[s] = .large_head;
    run_len[s] = @intCast(n);
    alloc_bits[s][0] = 1;
    var k: usize = 1;
    while (k < n) : (k += 1) {
        kinds[s + k] = .large_cont;
        run_len[s + k] = @intCast(k);
    }
    @memset(@as([*]u8, @ptrFromInt(pageAddr(s)))[0 .. n << page_shift], 0);
    bytes_since_gc += n << page_shift;
    return @ptrFromInt(pageAddr(s));
}

/// Capacity of the block at `addr`, or 0 if it is not a live object start.
fn blockCapacity(addr: usize) usize {
    if (addr < heap_base) return 0;
    const page = (addr - heap_base) >> page_shift;
    if (page >= next_page) return 0;
    return switch (kinds[page]) {
        .small => class_sizes[classes[page]] - 1,
        .large_head => (@as(usize, run_len[page]) << page_shift) - 1,
        else => 0,
    };
}

fn vAlloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    return allocImpl(len, alignment);
}

fn vResize(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
    return new_len <= blockCapacity(@intFromPtr(memory.ptr));
}

fn vRemap(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) ?[*]u8 {
    if (new_len <= blockCapacity(@intFromPtr(memory.ptr))) return memory.ptr;
    return null;
}

fn vFree(_: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
    // Memory is reclaimed by collection; explicit frees only recycle small objects early.
    if (memory.len == 0 or !inited) return;
    const addr = @intFromPtr(memory.ptr);
    if (addr < heap_base) return;
    const page = (addr - heap_base) >> page_shift;
    if (page >= next_page or kinds[page] != .small) return;
    const cls = classes[page];
    const csize = class_sizes[cls];
    const off = addr - pageAddr(page);
    if (off % csize != 0) return;
    const slot = off / csize;
    if (!bitGet(&alloc_bits[page], slot)) return;
    bitClear(&alloc_bits[page], slot);
    @as(*usize, @ptrFromInt(addr)).* = free_heads[cls];
    free_heads[cls] = addr;
}

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{ .alloc = vAlloc, .resize = vResize, .remap = vRemap, .free = vFree },
};

// ============================================================== collection

fn pushMark(addr: usize, len: usize) void {
    if (mstack_len + 2 > mstack_cap) {
        const new_cap = mstack_cap * 2;
        const p = mmapRaw(new_cap * @sizeOf(usize)) orelse @panic("out of memory during collection");
        const np: [*]usize = @ptrCast(@alignCast(p));
        @memcpy(np[0..mstack_len], mstack[0..mstack_len]);
        _ = linux.munmap(@ptrCast(mstack), mstack_cap * @sizeOf(usize));
        mstack = np;
        mstack_cap = new_cap;
    }
    mstack[mstack_len] = addr;
    mstack[mstack_len + 1] = len;
    mstack_len += 2;
}

fn markWord(w: usize) void {
    if (w < heap_base) return;
    const off = w - heap_base;
    const page = off >> page_shift;
    if (page >= next_page) return;
    switch (kinds[page]) {
        .free => {},
        .small => {
            const size = class_sizes[classes[page]];
            const in_page = off & (page_size - 1);
            const slot = in_page / size;
            if (slot >= page_size / size) return;
            if (!bitGet(&alloc_bits[page], slot)) return;
            if (bitGet(&mark_bits[page], slot)) return;
            bitSet(&mark_bits[page], slot);
            pushMark(pageAddr(page) + slot * size, size);
        },
        .large_head, .large_cont => {
            const head = if (kinds[page] == .large_head) page else page - run_len[page];
            if (alloc_bits[head][0] & 1 == 0) return;
            if (mark_bits[head][0] & 1 != 0) return;
            mark_bits[head][0] |= 1;
            pushMark(pageAddr(head), @as(usize, run_len[head]) << page_shift);
        },
    }
}

fn scanRange(start: usize, end: usize) void {
    var p = std.mem.alignForward(usize, start, @sizeOf(usize));
    while (p + @sizeOf(usize) <= end) : (p += @sizeOf(usize)) {
        markWord(@as(*const usize, @ptrFromInt(p)).*);
    }
}

fn drainMarks() void {
    while (mstack_len > 0) {
        mstack_len -= 2;
        const addr = mstack[mstack_len];
        const len = mstack[mstack_len + 1];
        scanRange(addr, addr + len);
    }
}

/// Scan the writable PT_LOAD segments (.data and .bss) of the executable.
fn scanDataSegments() void {
    const phdr_addr = linux.getauxval(std.elf.AT.PHDR);
    const phnum = linux.getauxval(std.elf.AT.PHNUM);
    const phent = linux.getauxval(std.elf.AT.PHENT);
    if (phdr_addr == 0 or phnum == 0) return;
    const Phdr = std.elf.Elf64.Phdr;
    // Load bias: where the program headers really are versus where they claim to be.
    var bias: usize = 0;
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const ph: *const Phdr = @ptrFromInt(phdr_addr + i * phent);
        if (ph.type == .PHDR) bias = phdr_addr - @as(usize, @intCast(ph.vaddr));
    }
    i = 0;
    while (i < phnum) : (i += 1) {
        const ph: *const Phdr = @ptrFromInt(phdr_addr + i * phent);
        if (ph.type != .LOAD or !ph.flags.W) continue;
        const start = bias + @as(usize, @intCast(ph.vaddr));
        scanRange(start, start + @as(usize, @intCast(ph.memsz)));
    }
}

/// Capture callee-saved registers so values held only there are scanned with the stack.
inline fn spillRegisters(regs: *[16]usize) void {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            regs[0] = asm volatile ("" : [r] "={rbx}" (-> usize));
            regs[2] = asm volatile ("" : [r] "={r12}" (-> usize));
            regs[3] = asm volatile ("" : [r] "={r13}" (-> usize));
            regs[4] = asm volatile ("" : [r] "={r14}" (-> usize));
            regs[5] = asm volatile ("" : [r] "={r15}" (-> usize));
        },
        .aarch64 => {
            regs[0] = asm volatile ("" : [r] "={x19}" (-> usize));
            regs[1] = asm volatile ("" : [r] "={x20}" (-> usize));
            regs[2] = asm volatile ("" : [r] "={x21}" (-> usize));
            regs[3] = asm volatile ("" : [r] "={x22}" (-> usize));
            regs[4] = asm volatile ("" : [r] "={x23}" (-> usize));
            regs[5] = asm volatile ("" : [r] "={x24}" (-> usize));
            regs[6] = asm volatile ("" : [r] "={x25}" (-> usize));
            regs[7] = asm volatile ("" : [r] "={x26}" (-> usize));
            regs[8] = asm volatile ("" : [r] "={x27}" (-> usize));
            regs[9] = asm volatile ("" : [r] "={x28}" (-> usize));
        },
        else => @compileError("gc: unsupported architecture"),
    }
}

noinline fn markRoots() void {
    var regs: [16]usize = @splat(0);
    spillRegisters(&regs);
    const sp = @intFromPtr(&regs);
    if (stack_top > sp) scanRange(sp, stack_top);
    scanDataSegments();
    drainMarks();
}

fn sweep() void {
    for (&free_heads) |*h| h.* = 0;
    live_bytes = 0;
    var page: usize = 0;
    var top: usize = 0; // new high-water mark
    while (page < next_page) {
        switch (kinds[page]) {
            .free => page += 1,
            .small => {
                const cls: usize = classes[page];
                const size = class_sizes[cls];
                const n = page_size / size;
                var live: usize = 0;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    if (bitGet(&alloc_bits[page], i)) {
                        if (bitGet(&mark_bits[page], i)) {
                            live += 1;
                        } else bitClear(&alloc_bits[page], i);
                    }
                }
                if (live == 0) {
                    kinds[page] = .free;
                } else {
                    live_bytes += live * size;
                    top = page + 1;
                    // Free slots go back on the list, lowest address first.
                    var j = n;
                    while (j > 0) {
                        j -= 1;
                        if (!bitGet(&alloc_bits[page], j)) {
                            const addr = pageAddr(page) + j * size;
                            @as(*usize, @ptrFromInt(addr)).* = free_heads[cls];
                            free_heads[cls] = addr;
                        }
                    }
                }
                mark_bits[page] = @splat(0);
                page += 1;
            },
            .large_head => {
                const n: usize = run_len[page];
                if (mark_bits[page][0] & 1 != 0) {
                    live_bytes += n << page_shift;
                    mark_bits[page][0] = 0;
                    top = page + n;
                } else {
                    alloc_bits[page][0] = 0;
                    var k: usize = 0;
                    while (k < n) : (k += 1) kinds[page + k] = .free;
                    // Give big dead runs back to the kernel.
                    if (n >= 4) _ = linux.madvise(@ptrFromInt(pageAddr(page)), n << page_shift, 4); // MADV_DONTNEED
                }
                page += n;
            },
            .large_cont => page += 1,
        }
    }
    next_page = top;
    free_hint = 0;
}

/// Run a full collection.
pub fn collect() void {
    if (!inited or collecting) return;
    collecting = true;
    defer collecting = false;
    mstack_len = 0;
    markRoots();
    sweep();
    collections += 1;
    bytes_since_gc = 0;
    threshold = @max(48 * 1024 * 1024, live_bytes);
}

/// Bytes currently held by live objects as of the last collection.
pub fn liveBytes() usize {
    return live_bytes;
}

test "collector keeps reachable data and reuses garbage" {
    init(@frameAddress());
    var keep: std.ArrayList([]u8) = .empty;
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        const s = try allocator.alloc(u8, 64);
        @memset(s, @intCast(i % 251));
        if (i % 100 == 0) try keep.append(allocator, s);
    }
    collect();
    try std.testing.expect(collections > 0);
    for (keep.items, 0..) |s, k| try std.testing.expectEqual(@as(u8, @intCast((k * 100) % 251)), s[63]);
    try std.testing.expect(liveBytes() < 4 * 1024 * 1024);
}
