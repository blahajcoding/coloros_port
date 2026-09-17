# Android 11 vendor SELinux compatibility mapping

These files are consumed by the Android 17 `postdata_compat` stage for devices
whose vendor policy ABI is 30.0 (for example, SM8250 / Android 11 vendor).

The directory is partition-oriented:

- `system/30.0.cil` and `system/30.0.compat.cil` are required by first-stage
  SELinux policy assembly.
- `system_ext/30.0.cil` and `product/30.0.cil` preserve the public types
  exported by those partitions when the old vendor policy references them.

Do not rename an Android 17 `31.0.cil` to `30.0.cil`. If these mappings need to
change for a different vendor ABI, add a separate source directory and select
it with `PORT_SELINUX_MAP_SOURCE`.
