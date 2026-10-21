/// Spike feature flags. All OFF by default: old Dart paths stay authoritative
/// until the spike is promoted.
class CoreFlags {
  CoreFlags._();

  static bool coreWrites = false;
  static bool download = false;
}
