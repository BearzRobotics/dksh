const std = @import("std");

pub fn build(b: *std.Build) void {
    // No libc, ever (SPEC 4.2): the default target is freestanding of any C runtime.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .none },
    });
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        // The collector scans the stack by frame; rbp/x29 must never hold a heap pointer.
        .omit_frame_pointer = false,
    });

    // Unicode tables for the regex engine are generated from data/ucd at build time.
    const sys_mod = b.createModule(.{ .root_source_file = b.path("src/sys.zig"), .target = b.graph.host });
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("build/gen_unicode.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    gen_mod.addImport("sys", sys_mod);
    const gen = b.addExecutable(.{ .name = "gen_unicode", .root_module = gen_mod });
    const gen_run = b.addRunArtifact(gen);
    gen_run.addDirectoryArg(b.path("data/ucd"));
    const tables = gen_run.addOutputFileArg("unicode_tables.zig");
    mod.addImport("unicode_tables", b.createModule(.{ .root_source_file = tables }));

    const exe = b.addExecutable(.{ .name = "dksh", .root_module = mod });
    b.installArtifact(exe);
    // Default startup files and the manual page (SPEC S10). A distribution
    // copies profile.dksh to /etc/dksh/ and adds /usr/bin/dksh to /etc/shells.
    b.installFile("data/profile.dksh", "share/dksh/profile.dksh");
    b.installFile("data/dkshrc.dksh", "share/dksh/dkshrc.dksh");
    b.installFile("docs/dksh.1", "share/man/man1/dksh.1");

    const run = b.addRunArtifact(exe);
    b.step("run", "Build and run dksh").dependOn(&run.step);

    // Golden tests (tests/spec) against the installed binary.
    const spec = b.addSystemCommand(&.{"tests/run_spec.sh"});
    spec.addArtifactArg(exe);
    spec.step.dependOn(b.getInstallStep());
    b.step("spec", "Run the golden tests").dependOn(&spec.step);
    const cli = b.addSystemCommand(&.{"tests/cli_options.sh"});
    cli.addArtifactArg(exe);
    cli.step.dependOn(b.getInstallStep());
    b.step("cli", "Run the command-line option tests").dependOn(&cli.step);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
